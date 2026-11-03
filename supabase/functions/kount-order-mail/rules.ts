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
