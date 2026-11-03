// supabase/functions/_shared/purchase-doc.ts
//
// Reading a vendor QUOTE, ORDER CONFIRMATION, INVOICE, SHIPPING NOTICE or
// CREDIT MEMO (PDF) into header + lines, shared by kount-read-purchase-doc
// (a PDF the admin uploads) and kount-order-mail (PDFs the morning mail pull
// finds). Claude reads the PDF natively (a document block) through the shared
// router: OpenRouter first, Anthropic direct as fallback -- KevaOS's counting
// gateway does not take documents, so it is skipped. Model: claude-opus-5-5
// with structured output, so the reply always matches SCHEMA.

import { routeClaude } from './ai-router.ts';

// ~10 MB of PDF; base64 is 4/3 of the bytes.
export const MAX_BASE64_CHARS = 14_000_000;

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
    refers_to: { type: 'array', items: { type: 'string' }, description: 'Numbers of OTHER invoices / quotes / orders this document says it belongs to, often in the notes near the bottom (e.g. "Shipping Fee - For Items Under INV-2026-368461", "Balance of INV-...", "Re: Quote Q-..."), exactly as printed. Never the document\'s own number or the PO number (order_number). Empty array if none.' },
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
  required: ['doc_kind', 'is_credit', 'vendor_name', 'doc_number', 'doc_date', 'order_number', 'bill_to', 'ship_to', 'expected_date', 'tracking_numbers', 'refers_to', 'subtotal', 'total', 'lines'],
} as const;

export const SYSTEM =
  'You read purchasing documents for a restaurant group: vendor quotes, order confirmations, invoices and shipping notices for ' +
  'custom-printed and operating supplies (to-go bags, napkins, glassware, uniforms). Extract the header and every line exactly as ' +
  'printed, per the response schema. Report numbers as printed even when they do not add up -- a person reviews the result and ' +
  'checks it against the PDF, so a silently corrected number is worse than a visible mismatch. Numbers are plain (no currency ' +
  'symbols, no thousands separators). Keep the document\'s own number (doc_number) separate from the customer purchase order ' +
  'number it references (order_number), and from other invoices it says it is for (refers_to).';

/** base64 of a PDF -> the document as SCHEMA describes it. Throws AiRouterError. */
export async function readPurchasePdf(a: { pdf: string; fileName: string; flow: string; actorId?: string; metadata?: Record<string, unknown> }) {
  const result = await routeClaude({
    flow: a.flow,
    kevaosFlow: 'ask',
    model: 'claude-opus-5-5',
    maxTokens: 16000,
    system: [{ text: SYSTEM }],
    messages: [{
      role: 'user',
      content: [
        { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: a.pdf }, title: a.fileName },
        { type: 'text', text: 'Extract this document per the schema.' },
      ],
    }],
    jsonSchema: { name: 'purchase_document', schema: SCHEMA as unknown as Record<string, unknown> },
    actorId: a.actorId,
    metadata: a.metadata,
  });
  return { document: result.json, model: result.model, route: result.route };
}
