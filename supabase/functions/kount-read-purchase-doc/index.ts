// supabase/functions/kount-read-purchase-doc/index.ts
//
// Edge Function: read a vendor QUOTE, ORDER CONFIRMATION, INVOICE or SHIPPING
// NOTICE (PDF) for the admin "Order tracker" tab (Counting-Admin v0.79) and
// return its header + lines as JSON. The admin shows the result for review;
// nothing is written to the database here -- the reviewed result is saved by
// the admin through the kount_ot_* tables (migration 0132).
//
// The reading itself (schema, prompt, model) is ../_shared/purchase-doc.ts,
// shared with the morning mail pull (kount-order-mail).
//
// AUTH: the caller's own JWT must resolve to an ACTIVE app_users row with role
// admin or corporate -- the same people the Purchasing section is open to.
// The anon key alone is refused (it ships in the client bundle).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';
import { AiRouterError } from '../_shared/ai-router.ts';
import { MAX_BASE64_CHARS, readPurchasePdf } from '../_shared/purchase-doc.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') || '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

const ALLOWED_ROLES = new Set(['admin', 'corporate']);
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
    const result = await readPurchasePdf({ pdf, fileName, flow: 'kount-read-purchase-doc', actorId: userResp.user.id, metadata: { role: profile.role, file_name: fileName } });
    return jsonResponse(200, result);
  } catch (e) {
    const status = e instanceof AiRouterError ? e.status : 0;
    if (status === 429) return reject(429, 'The AI is busy right now — try again in a moment');
    if (status === 500) return reject(500, (e as Error).message);
    return reject(502, 'The document could not be read — try again, or enter it by hand');
  }
});
