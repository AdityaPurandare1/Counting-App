// supabase/functions/kount-order-mail/rules.ts
//
// The pure rules of the morning mail pull: which emails and attachments are
// taken, what "9 o'clock in Los Angeles" is, and small byte helpers. Tested in
// rules.test.ts (deno test).

/** h.wood's own mail is never a vendor document (forwards and replies are copies). */
export const OWN_DOMAINS = ['hwoodgroup.com'];

export function domainOf(email: string | null | undefined): string {
  const m = /@([^@\s>]+)\s*>?$/.exec(String(email ?? '').trim().toLowerCase());
  return m ? m[1] : '';
}

/** A domain on the list, or a sub-domain of one ("mail.eemercantile.co" for "eemercantile.co"). */
export function onList(domain: string, list: readonly string[]): boolean {
  const d = domain.toLowerCase();
  return !!d && list.some(x => d === x || d.endsWith('.' + x));
}

/** A message of an order's e-mail thread, as Graph lists it (0147). */
export interface ThreadMessage {
  id?: string; sentDateTime?: string; receivedDateTime?: string; isDraft?: boolean;
  from?: { emailAddress?: { address?: string } };
  toRecipients?: Array<{ emailAddress?: { address?: string } }>;
  ccRecipients?: Array<{ emailAddress?: { address?: string } }>;
}

/** An e-mail FROM h.wood TO a listed vendor (To or Cc) — not a forward to AP, a note between colleagues or a draft. */
export function isToVendor(m: ThreadMessage, vendorDomains: readonly string[]): boolean {
  if (m.isDraft || !onList(domainOf(m.from?.emailAddress?.address), OWN_DOMAINS)) return false;
  return [...(m.toRecipients ?? []), ...(m.ccRecipients ?? [])].some(r => onList(domainOf(r.emailAddress?.address), vendorDomains));
}

const EXCHANGE_GAP_MS = 21 * 86_400_000;

/** When the order went to the vendor, from one of its e-mail threads. Start at the e-mail that brought the
 *  order's first document (a quote / invoice / confirmation: `docMessageIds`, else the first document's day),
 *  walk back through the thread while its messages are no more than 3 weeks apart, and take the first e-mail
 *  h.wood sent the vendor in that exchange. So a thread reused for months starts at this order's request, not at
 *  the first one in April; and nothing after the order's first document (asking for the invoices, a payment
 *  note) is ever the day it was sent. Null when the exchange holds no e-mail to the vendor. */
export function sentToVendor(messages: readonly ThreadMessage[], vendorDomains: readonly string[],
                             docMessageIds: ReadonlySet<string>, firstDocDay: string | null): string | null {
  const at = (m: ThreadMessage) => Date.parse(m.sentDateTime ?? m.receivedDateTime ?? '');
  const live = messages.filter(m => !m.isDraft && Number.isFinite(at(m))).sort((a, b) => at(a) - at(b));
  // the first document's day, in Los Angeles, ends at 08:00 UTC the next day at the latest (PST)
  const dayLimit = firstDocDay ? Date.parse(firstDocDay + 'T00:00:00Z') + 32 * 3_600_000 : Infinity;
  const docTimes = live.filter(m => m.id && docMessageIds.has(m.id)).map(at);
  const anchor = Math.min(docTimes.length ? Math.min(...docTimes) : Infinity, dayLimit);
  if (!Number.isFinite(anchor)) return null;
  let end = -1;
  live.forEach((m, i) => { if (at(m) <= anchor) end = i; });
  // the exchange has to reach the document: an April thread is not the request for an order invoiced in August
  if (end < 0 || anchor - at(live[end]) > EXCHANGE_GAP_MS) return null;
  let start = end;
  while (start > 0 && at(live[start]) - at(live[start - 1]) <= EXCHANGE_GAP_MS) start--;
  const first = live.slice(start, end + 1).find(m => isToVendor(m, vendorDomains));
  return first ? (first.sentDateTime ?? first.receivedDateTime ?? null) : null;
}

/** Whether the e-mail's day replaces the order's sent day: only an earlier one (the sheet's Order Date or the PO
 *  date say it was ordered by then; a later e-mail is a follow-up in another exchange), and only within 60 days
 *  of the order's first document (a thread busy since spring cannot say which request this order was). */
export function takeEmailSentDay(emailDay: string | null, current: string | null, firstDocDay: string | null): boolean {
  if (!emailDay) return false;
  if (current && emailDay >= current) return false;
  if (firstDocDay && (Date.parse(firstDocDay) - Date.parse(emailDay)) / 86_400_000 > 60) return false;
  return true;
}

export interface GraphAttachment { '@odata.type'?: string; id: string; name?: string; contentType?: string; size?: number; isInline?: boolean }

export const MAX_PDF_BYTES = 10 * 1024 * 1024;
// PDFs vendors send that are never a quote / invoice / confirmation / shipping notice
const NOT_A_PURCHASE_DOC = /(w-?9|\bcoi\b|certificate|insurance|label|mock-?up|proof|artwork|render|logo|brochure|catalog|lookbook|menu|spec ?sheet)/i;

/** A real (not inline) PDF file attachment, small enough to read, not obviously something else. */
export function isPdfAttachment(a: GraphAttachment): boolean {
  if (a['@odata.type'] && a['@odata.type'] !== '#microsoft.graph.fileAttachment') return false;
  if (a.isInline) return false;
  if (!/pdf/i.test(a.contentType ?? '') && !/\.pdf$/i.test(a.name ?? '')) return false;
  if ((a.size ?? 0) > MAX_PDF_BYTES) return false;
  return !NOT_A_PURCHASE_DOC.test(a.name ?? '');
}

const PURCHASE_HINT = /(invoice|\binv\b|inv[-_ #]?\d|quote|quotation|estimate|proposal|pro-?forma|sales ?order|order ?confirm|acknowledg|packing|credit ?memo)/i;

/** Used only to SUGGEST a sender domain to add (nothing from an unlisted sender is read). */
export function looksLikePurchaseDoc(subject: string | null | undefined, fileName: string | null | undefined): boolean {
  return PURCHASE_HINT.test(fileName ?? '') || PURCHASE_HINT.test(subject ?? '');
}

/* ── which document types the pull takes (kount_ot_mail_account.doc_kinds, 0136) ── */

export const ALL_DOC_KINDS = ['quote', 'confirmation', 'invoice', 'shipping'] as const;
const KIND_HINT: Record<string, RegExp> = {
  invoice: /(invoice|\binv\b|inv[-_ #]?\d|credit ?memo)/i,
  quote: /(quote|quotation|estimate|proposal|pro-?forma)/i,
  confirmation: /(confirm|acknowledg|sales ?order)/i,
  shipping: /(packing|ship(ping|ment)? (notice|confirmation)|tracking|bill of lading|\bbol\b|delivery note)/i,
};

/** With every type on, any PDF from a listed vendor is opened. With a subset, only attachments
 *  whose file name or email subject looks like one of those types — fewer paid reads, and quotes
 *  are not stored when only invoices are wanted. */
export function wantsAttachment(kinds: readonly string[], subject: string | null | undefined, fileName: string | null | undefined): boolean {
  if (ALL_DOC_KINDS.every(k => kinds.includes(k))) return true;
  return kinds.some(k => KIND_HINT[k]?.test(fileName ?? '') || KIND_HINT[k]?.test(subject ?? ''));
}

/** After reading: is this a type the pull takes? A credit memo counts as an invoice. */
export function kindAllowed(kinds: readonly string[], doc: { doc_kind: string; is_credit?: boolean }): boolean {
  if (doc.is_credit) return kinds.includes('invoice');
  if (doc.doc_kind === 'other') return true;          // decided later: not a purchasing document -> skipped
  return kinds.includes(doc.doc_kind);
}

/** The hour (0-23) and date (YYYY-MM-DD) in Los Angeles — the pull runs in the 9 o'clock hour, PDT or PST. */
export function laParts(d: Date = new Date()): { hour: number; isoDate: string } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Los_Angeles', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23',
  }).formatToParts(d);
  const get = (t: string) => parts.find(p => p.type === t)?.value ?? '';
  return { hour: Number(get('hour')), isoDate: `${get('year')}-${get('month')}-${get('day')}` };
}

/** The signed-in mailbox from the id token Microsoft returned with the sign-in (straight from its
 *  token endpoint over TLS, so the claims are read, not re-verified). '' when it carries none. */
export function idTokenMailbox(idToken: string | null | undefined): string {
  const part = String(idToken ?? '').split('.')[1];
  if (!part) return '';
  try {
    const json = JSON.parse(new TextDecoder().decode(fromBase64(part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '='))));
    const v = json.preferred_username || json.email || json.upn || '';
    return /@/.test(String(v)) ? String(v).toLowerCase() : '';
  } catch {
    return '';
  }
}

/* ── paid, from R365 (AP payments matched to AP invoices) ──────────────── */

/** An R365 AP invoice or AP payment, one per transaction (kount_ot_r365_ap, 0138). */
export interface R365Tx { type: 'AP Invoice' | 'AP Payment'; number: string; date: string; venue: string | null; vendor: string; amount: number }

const DAY_MS = 86_400_000;
const cents = (x: number) => Math.round(Number(x) * 100);

/** Which payment paid which invoice. R365's payment rows do not name the invoices they pay, so a
 *  payment is matched by vendor + company (venue) + amount: first one invoice for exactly the
 *  amount (oldest first), else the ONE combination of 2–8 open invoices that adds up to the cent.
 *  Two possible combinations = not sure = not matched (the invoice simply stays Invoiced). */
export function matchR365Payments(txs: R365Tx[], opts: { windowDays?: number; maxSubset?: number; maxCandidates?: number } = {}): Map<string, R365Tx> {
  const windowDays = opts.windowDays ?? 120, maxSubset = opts.maxSubset ?? 8, maxCandidates = opts.maxCandidates ?? 18;
  const paidBy = new Map<string, R365Tx>();
  const key = (t: R365Tx) => `${t.vendor.toLowerCase()}|${t.venue ?? ''}`;
  const groups = new Map<string, { inv: R365Tx[]; pay: R365Tx[] }>();
  for (const t of txs) {
    const g = groups.get(key(t)) ?? { inv: [], pay: [] };
    (t.type === 'AP Invoice' ? g.inv : g.pay).push(t);
    groups.set(key(t), g);
  }
  for (const { inv, pay } of groups.values()) {
    inv.sort((a, b) => a.date.localeCompare(b.date));
    pay.sort((a, b) => a.date.localeCompare(b.date));
    const used = new Set<string>();
    for (const p of pay) {
      const pd = Date.parse(p.date), target = cents(p.amount);
      if (!(target > 0)) continue;
      const open = inv.filter(i => !used.has(i.number) && Date.parse(i.date) <= pd + 3 * DAY_MS && Date.parse(i.date) >= pd - windowDays * DAY_MS && cents(i.amount) > 0);
      const exact = open.find(i => cents(i.amount) === target);
      if (exact) { used.add(exact.number); paidBy.set(exact.number, p); continue; }
      // the newest open invoices before the payment, small enough to fit in it
      const cands = open.filter(i => cents(i.amount) < target).slice(-maxCandidates);
      const found: R365Tx[][] = [];
      const pick: R365Tx[] = [];
      const walk = (start: number, left: number) => {
        if (found.length > 1) return;
        if (left === 0 && pick.length >= 2) { found.push([...pick]); return; }
        if (left <= 0 || pick.length >= maxSubset) return;
        for (let i = start; i < cands.length && found.length < 2; i++) {
          pick.push(cands[i]); walk(i + 1, left - cents(cands[i].amount)); pick.pop();
        }
      };
      walk(0, target);
      if (found.length === 1) for (const i of found[0]) { used.add(i.number); paidBy.set(i.number, p); }
    }
  }
  return paidBy;
}

/** "INV-2026-857309" out of "INV-2026-857309 Delilah LA", "INV-2026-857309-1", "inv-2026-857309/2" (upper case). */
export function invoiceToken(n: string | null | undefined): string {
  const m = /INV-\d{4}-\d{5,7}/i.exec(String(n ?? ''));
  return m ? m[0].toUpperCase() : String(n ?? '').trim().toUpperCase();
}

/** Tracked invoice token -> the R365 payments that paid it, only when EVERY R365 part of it is paid
 *  (R365 splits some E&E invoices per venue). Voided / voiding entries are not parts. */
export function paidInvoices(tokens: string[], txs: R365Tx[]): Map<string, R365Tx[]> {
  const live = txs.filter(t => !/void/i.test(t.number));
  const paidBy = matchR365Payments(live);
  const parts = new Map<string, R365Tx[]>();
  for (const t of live) if (t.type === 'AP Invoice') {
    const k = invoiceToken(t.number);
    parts.set(k, [...(parts.get(k) ?? []), t]);
  }
  const out = new Map<string, R365Tx[]>();
  for (const tok of new Set(tokens.map(invoiceToken))) {
    const ps = parts.get(tok);
    if (!ps?.length || !ps.every(p => paidBy.has(p.number))) continue;
    out.set(tok, [...new Set(ps.map(p => paidBy.get(p.number)!))]);
  }
  return out;
}

/* ── check stubs (h.wood's "attached paystub for INV-…" emails) ────────── */

export const STUB_TYPES = ['application/pdf', 'image/png', 'image/jpeg'] as const;

/** A stub file: a PDF or photo, not a signature logo (inline images under 60 KB are logos). */
export function isStubAttachment(a: GraphAttachment): string | null {
  if (a['@odata.type'] && a['@odata.type'] !== '#microsoft.graph.fileAttachment') return null;
  const name = (a.name ?? '').toLowerCase();
  const type = /pdf/i.test(a.contentType ?? '') || name.endsWith('.pdf') ? 'application/pdf'
    : /png/i.test(a.contentType ?? '') || name.endsWith('.png') ? 'image/png'
    : /jpe?g/i.test(a.contentType ?? '') || /\.jpe?g$/.test(name) ? 'image/jpeg' : null;
  if (!type || (a.size ?? 0) > MAX_PDF_BYTES) return null;
  if (a.isInline && (type !== 'application/pdf') && (a.size ?? 0) < 60_000) return null;
  return type;
}

/** The invoice numbers a stub email is for — only what THAT email says (uniqueBody), not the quoted thread. */
export function stubInvoices(text: string | null | undefined): string[] {
  return [...new Set([...String(text ?? '').matchAll(/INV-\d{4}-\d{5,7}/gi)].map(m => m[0].toUpperCase()))];
}

/** Constant-time string compare (the cron secret). */
export function safeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function fromBase64(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64.replace(/\s+/g, ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...h].map(b => b.toString(16).padStart(2, '0')).join('');
}
