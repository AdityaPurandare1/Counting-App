// supabase/functions/kount-read-purchase-doc/index.ts
//
// Edge Function: read a vendor QUOTE, ORDER CONFIRMATION, INVOICE or SHIPPING
// NOTICE (PDF) for the admin "Order tracker" tab (Counting-Admin v0.79) and
// return its header + lines as JSON. The admin shows the result for review;
// nothing is written to the database here -- the reviewed result is saved by
// the admin through the kount_ot_* tables (migration 0132).
//
// Claude reads the PDF natively (a document block) through the shared router
// (../_shared/ai-router.ts): OpenRouter first, Anthropic direct as fallback --
// KevaOS's counting gateway does not take documents, so it is skipped. Model:
// claude-opus-5-5 with structured output, so the reply always matches SCHEMA.
//
// AUTH: the caller's own JWT must resolve to an ACTIVE app_users row with role
// admin or corporate -- the same people the Purchasing section is open to.
// The anon key alone is refused (it ships in the client bundle).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';
import { AiRouterError, routeClaude } from '../_shared/ai-router.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') || '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

const ALLOWED_ROLES = new Set(['admin', 'corporate']);
// ~10 MB of PDF; base64 is 4/3 of the bytes.
const MAX_BASE64_CHARS = 14_000_000;

export const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    doc_kind: {
      type: 'string',
      enum: ['quote', 'confirmation', 'invoice', 'shipping', 'other'],
      description: 'quote = quote / estimate / proposal; confirmation = order confirmation / acknowledgement / sales order; invoice = invoice / bill; shipping = packing slip / shipping or delivery notice / tracking; other = anything else.',
    },
    is_credit: { type: 'boolean', description: 'true for a credit memo / credit note / refund / overpayment credit (money coming BACK to the customer), whatever the signs of its amounts; false otherwise.' },
    vendor_name: { type: 'string', description: 'The vendor / supplier that issued the document. Empty string if not printed.' },
    doc_number: { type: 'string', description: "The document's OWN number (quote #, invoice #, confirmation #, packing slip #). Empty string if none." },
    doc_date: { type: 'string', description: 'Document date as YYYY-MM-DD, else empty string.' },
    order_number: { type: 'string', description: "The customer's purchase order / order number the document refers to (PO #, Customer PO, Your order #). Empty string if none is printed." },
    bill_to: { type: 'string', description: 'Customer / venue name in the Bill To block (name only, no address). Empty string if none.' },
    ship_to: { type: 'string', description: 'Name in the Ship To block (name only, e.g. a warehouse or venue). Empty string if none.' },
    expected_date: { type: 'string', description: 'Promised ship, delivery or ready date as YYYY-MM-DD if printed, else empty string.' },
    tracking_numbers: { type: 'array', items: { type: 'string' }, description: 'Carrier tracking numbers printed on the document; empty array if none.' },
    subtotal: { type: 'number', description: 'Subtotal before tax / freight exactly as printed; 0 if none printed.' },
    total: { type: 'number', description: 'Grand total exactly as printed; 0 if none printed.' },
    lines: {
      type: 'array',
      description: 'Every line on the document, in order. Merge a line that wraps over several rows into one.',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          line_kind: { type: 'string', enum: ['product', 'freight', 'tax', 'fee', 'discount'], description: 'product for goods; freight / shipping charges; tax; fee (setup, plate, art, deposit, handling); discount.' },
          description: { type: 'string', description: 'The line description as printed.' },
          sku: { type: 'string', description: "The vendor's item code / SKU / style # for the line; empty string if none." },
          qty: { type: 'number', description: 'Quantity as printed (0 if none).' },
          unit: { type: 'string', description: 'Unit the quantity is in, lowercase (case, each, box, roll, set...). Empty string if not printed.' },
          unit_price: { type: 'number', description: 'Price per unit exactly as printed (0 if none).' },
          line_total: { type: 'number', description: 'Extended amount exactly as printed (0 if none).' },
          pack_size: { type: 'number', description: 'Pieces per unit if the line states it (e.g. "250/cs" -> 250); 0 if not stated.' },
        },
        required: ['line_kind', 'description', 'sku', 'qty', 'unit', 'unit_price', 'line_total', 'pack_size'],
      },
    },
  },
  required: ['doc_kind', 'is_credit', 'vendor_name', 'doc_number', 'doc_date', 'order_number', 'bill_to', 'ship_to', 'expected_date', 'tracking_numbers', 'subtotal', 'total', 'lines'],
} as const;

const SYSTEM =
  'You read purchasing documents for a restaurant group: vendor quotes, order confirmations, invoices and shipping notices for ' +
  'custom-printed and operating supplies (to-go bags, napkins, glassware, uniforms). Extract the header and every line exactly as ' +
  'printed, per the response schema. Report numbers as printed even when they do not add up -- a person reviews the result and ' +
  'checks it against the PDF, so a silently corrected number is worse than a visible mismatch. Numbers are plain (no currency ' +
  'symbols, no thousands separators). Keep the document\'s own number (doc_number) separate from the customer purchase order ' +
  'number it references (order_number).';

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
}
const reject = (status: number, message: string) => jsonResponse(status, { error: message });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reject(405, 'Method not allowed');

  // --- 1. The caller's own JWT, not the anon key. ---
  const callerJwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!callerJwt) return reject(401, 'Missing Authorization header');
  const asCaller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: 'Bearer ' + callerJwt } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userResp, error: userErr } = await asCaller.auth.getUser();
  if (userErr || !userResp.user || !userResp.user.email) return reject(401, 'Invalid or expired JWT');

  // --- 2. Active admin / corporate only (service-role lookup, so an RLS gap can't open it). ---
  const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: profile, error: profileErr } = await service
    .from('app_users').select('role,is_active').eq('email', userResp.user.email.toLowerCase()).limit(1).maybeSingle();
  if (profileErr) {
    console.error('[kount-read-purchase-doc] profile lookup error:', profileErr);
    return reject(500, 'Failed to verify caller');
  }
  if (!profile || profile.is_active !== true || !ALLOWED_ROLES.has(String(profile.role))) {
    return reject(403, 'Reading purchase documents is limited to admin and corporate users');
  }

  // --- 3. The PDF. ---
  let body: { pdf?: unknown; file_name?: unknown };
  try { body = await req.json(); } catch { return reject(400, 'Body must be JSON'); }
  const raw = typeof body.pdf === 'string' ? body.pdf : '';
  const pdf = raw.replace(/^data:application\/pdf;base64,/, '').replace(/\s+/g, '');
  if (!pdf) return reject(400, 'pdf (base64) is required');
  if (pdf.length > MAX_BASE64_CHARS) return reject(413, 'PDF is larger than 10 MB');
  if (!pdf.startsWith('JVBER')) return reject(400, 'That file is not a PDF');
  const fileName = typeof body.file_name === 'string' && body.file_name.trim() ? body.file_name.trim().slice(0, 120) : 'document.pdf';

  // --- 4. Read it. ---
  try {
    const result = await routeClaude({
      flow: 'kount-read-purchase-doc',
      kevaosFlow: 'ask',
      model: 'claude-opus-5-5',
      maxTokens: 16000,
      system: [{ text: SYSTEM }],
      messages: [{
        role: 'user',
        content: [
          { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: pdf }, title: fileName },
          { type: 'text', text: 'Extract this document per the schema.' },
        ],
      }],
      jsonSchema: { name: 'purchase_document', schema: SCHEMA as unknown as Record<string, unknown> },
      actorId: userResp.user.id,
      metadata: { role: profile.role, file_name: fileName },
    });
    return jsonResponse(200, { document: result.json, model: result.model, route: result.route });
  } catch (e) {
    const status = e instanceof AiRouterError ? e.status : 0;
    if (status === 429) return reject(429, 'The AI is busy right now — try again in a moment');
    if (status === 500) return reject(500, (e as Error).message);
    return reject(502, 'The document could not be read — try again, or enter it by hand');
  }
});
