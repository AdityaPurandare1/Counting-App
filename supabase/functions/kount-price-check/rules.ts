// supabase/functions/kount-price-check/rules.ts
//
// The weekly price check's pure logic (0176, admin v1.23): the bible items to check, what we paid for each, the
// question asked of the web-searching model, its answer read back, and the verdict. No I/O here (rules.test.ts).
//
// The user, 11/17: "a checker / sourcer ... that check for each BOH and FOH item if its being purchased right ...
// the correct price. the only requirement is that it has to be the exact same item mentioned in the bible. all specs
// have to match exactly. It should run weekly and scan the internet for those specific items. If there is a website
// which doesnt really have those labelled as such but need a quote tag them as quote required".

/** A bible as the admin stores it (kount_ot_bibles.text_index): each sheet's header row and its rows, as text. */
export interface BibleIndexSheet { name: string; header: string[]; rows: string[][] }
export interface BibleRow { id: string; venue_id: string; title: string; text_index: { sheets: BibleIndexSheet[] } | null }

/** One item to check: every bible row with the same manufacturer item #, as one. */
export interface PcItem {
  item_key: string;
  item_no: string | null;
  manufacturer: string | null;
  item_name: string | null;
  description: string | null;
  size: string | null;
  /** the row's other columns (color / pattern, vendor, vendor item #, notes ...) as header -> value */
  specs: Record<string, string>;
  sources: Array<{ venue_id: string; bible_id: string; title: string; sheet: string }>;
  bible_price: string | null;
  bible_link: string | null;
  /** an exact match can only be proven by the manufacturer's item # */
  checkable: boolean;
}

const COLS: Record<string, RegExp> = {
  item_no: /^(manufacturer|manufactuer|mfr|mfg)\.?\s*(item\s*)?(#|no\.?|number)$|^item\s*(#|no\.?|number)$|^sku$|^model\s*(#|no\.?)?$/i,
  manufacturer: /^(manufacturer|manufactuer|mfr|mfg|brand)$/i,
  item_name: /^item$|^item name$|^glass$|^product$/i,
  description: /^description/i,
  size: /^size$|^dimensions?$|^capacity$/i,
  price: /^price/i,
  link: /^link/i,
};
// columns that say how many / where / when we ordered, not what the item is
const NOT_A_SPEC = /(^|[^a-z])(image|photo|qty|quantity|par|status|received|deliver[a-z]*|notes?|review|usage|qpc|orders?|ordered|count|backstock|stock|location|venue|sheet|eta|tracking|link)([^a-z]|$)/i;

/** Normalized manufacturer item # ("SKU: 6HGMZ1119" -> "6HGMZ1119", "#853817" -> "853817", "0042.115672" ->
 *  "0042115672"); '' when it is no item number (no digit, too short). */
export function itemNoKey(raw: string | null | undefined): string {
  const s = String(raw ?? '').replace(/^\s*(sku|item|mfr|model)\s*(#|no\.?)?\s*:?\s*/i, '').trim();
  const k = s.toUpperCase().replace(/[^A-Z0-9]/g, '');
  return k.length >= 3 && /\d/.test(k) ? k : '';
}

// the replacement character an export leaves for a symbol it could not encode ("KORIKO? HAWTHORNE")
const REPLACEMENT_CHAR = new RegExp(String.fromCharCode(0xfffd), 'g');
const clean = (s: string | undefined) => {
  const t = String(s ?? '').replace(REPLACEMENT_CHAR, '').replace(/\s+/g, ' ').trim();
  return t || null;
};

/** The items in the current bibles, one per manufacturer item # (the same item in several venues' bibles is one
 *  check). A row with no item # is still listed, keyed by its words, and is not checkable. Header rows repeated in
 *  the middle of a sheet, empty rows and sheets with no recognizable header are left out. */
export function bibleItems(bibles: readonly BibleRow[]): PcItem[] {
  const out = new Map<string, PcItem>();
  for (const b of bibles) {
    for (const sh of b.text_index?.sheets ?? []) {
      const h = (sh.header ?? []).map(x => String(x ?? '').trim());
      const col: Record<string, number> = {};
      for (const [k, re] of Object.entries(COLS)) { const i = h.findIndex(x => re.test(x)); if (i >= 0) col[k] = i; }
      if (col.item_name === undefined && col.description === undefined) continue;   // not an item list (collateral, notes)
      for (const r of sh.rows ?? []) {
        const g = (k: string) => (col[k] !== undefined ? clean(r[col[k]]) : null);
        const name = g('item_name'), desc = g('description');
        if (!name && !desc) continue;
        // a header repeated inside the sheet ("Photo | Glass | Manufactuer | Description | SKU")
        if (r.filter(c => Object.values(COLS).some(re => re.test(String(c ?? '').trim())) || /^(photo|image)$/i.test(String(c ?? '').trim())).length >= 3) continue;
        const rawNo = g('item_no');
        const key = itemNoKey(rawNo);
        const specs: Record<string, string> = {};
        h.forEach((head, i) => {
          if (!head || Object.values(col).includes(i) || NOT_A_SPEC.test(head)) return;
          const v = clean(r[i]);
          if (v) specs[head] = v;
        });
        const item_key = key || `noid:${[g('manufacturer'), name, desc, g('size')].filter(Boolean).join('|').toLowerCase().slice(0, 200)}`;
        const src = { venue_id: b.venue_id, bible_id: b.id, title: b.title, sheet: sh.name };
        const have = out.get(item_key);
        if (have) {
          if (!have.sources.some(s => s.bible_id === src.bible_id && s.sheet === src.sheet)) have.sources.push(src);
          // fill what the first row left empty
          have.manufacturer ??= g('manufacturer'); have.description ??= desc; have.size ??= g('size');
          have.bible_price ??= g('price'); have.bible_link ??= (g('link')?.startsWith('http') ? g('link') : null);
          for (const [k, v] of Object.entries(specs)) if (!(k in have.specs)) have.specs[k] = v;
          continue;
        }
        const link = g('link');
        out.set(item_key, {
          item_key, item_no: key ? rawNo : null, manufacturer: g('manufacturer'), item_name: name, description: desc, size: g('size'),
          specs, sources: [src], bible_price: g('price'), bible_link: link && /^https?:\/\//i.test(link) ? link : null, checkable: !!key,
        });
      }
    }
  }
  return [...out.values()];
}

/** An order-tracker line as the check reads it (with its order's vendor and day). */
export interface PurchaseLine { sku: string | null; description: string; unit_price: number | null; unit: string | null; qty: number | null;
  status: string; vendor: string; ordered_on: string | null; order_number: string | null; invoice_number: string | null }
export interface Purchase { vendor: string; order_number: string | null; invoice_number: string | null; date: string | null;
  unit_price: number; unit: string | null; qty: number | null; description: string }

/** What we paid for an item: the order-tracker lines whose SKU or description carries its manufacturer item # as a
 *  whole token (normalized as the bible's), newest first, at most `max`. Cancelled and unpriced lines are not prices. */
export function purchasesFor(item: Pick<PcItem, 'item_no' | 'checkable'>, lines: readonly PurchaseLine[], max = 3): Purchase[] {
  const key = itemNoKey(item.item_no);
  if (!item.checkable || !key) return [];
  const hits = lines.filter(l => l.status !== 'CANCELLED' && Number(l.unit_price) > 0 && (
    itemNoKey(l.sku) === key || String(`${l.sku ?? ''} ${l.description ?? ''}`).split(/[\s,;/()|]+/).some(t => itemNoKey(t) === key)));
  return hits
    .sort((a, b) => String(b.ordered_on ?? '').localeCompare(String(a.ordered_on ?? '')))
    .slice(0, max)
    .map(l => ({ vendor: l.vendor, order_number: l.order_number, invoice_number: l.invoice_number, date: l.ordered_on,
      unit_price: Number(l.unit_price), unit: l.unit, qty: l.qty, description: l.description }));
}

export const RESEARCH_SYSTEM = [
  'You check whether a restaurant group buys an item at the right price. You search the web for sellers of ONE exact item',
  'and report what each charges. Exact means the same manufacturer and the same manufacturer item number, and every spec',
  'given (size, capacity, dimensions, color, pattern, finish, material) the same. A different item number, size, color,',
  'pattern, series or a "similar" / "compatible" / "alternative" product is NOT the item: list it under rejected with why.',
  'Open the product pages (web fetch) to read the item number, specs, price and how many pieces the price is for (each,',
  'a dozen, a case of 24 ...). Never guess a price or a pack size; leave what a page does not show out. A seller that',
  'lists the exact item but shows no price (request a quote, call for price, log in for pricing, contact us, trade',
  'pricing) goes under quote_required. Prefer restaurant / hospitality suppliers, the manufacturer, and large retailers;',
  'check the link the bible gives first. Prices in US dollars for delivery in the USA. Your training data ends well before',
  "today's date; prices and listings change, so search for them rather than recalling.",
].join(' ');

/** The question for one item: the bible's spec, its link, and what we paid. */
export function researchPrompt(item: PcItem, purchases: readonly Purchase[]): string {
  const spec = [
    `Manufacturer: ${item.manufacturer ?? '(not given)'}`,
    `Manufacturer item #: ${item.item_no ?? '(not given)'}`,
    item.item_name ? `Item: ${item.item_name}` : '',
    item.description ? `Description: ${item.description}` : '',
    item.size ? `Size: ${item.size}` : '',
    ...Object.entries(item.specs).map(([k, v]) => `${k}: ${v}`),
    item.bible_link ? `Link in the bible: ${item.bible_link}` : '',
    item.bible_price ? `Price in the bible: ${item.bible_price}` : '',
  ].filter(Boolean).join('\n');
  const paid = purchases.length
    ? purchases.map(p => `- ${p.date ?? '?'} ${p.vendor}${p.order_number ? ` ${p.order_number}` : ''}: $${p.unit_price.toFixed(2)} per ${p.unit || 'unit'}`
      + `${p.qty ? ` (qty ${p.qty})` : ''} - "${p.description.slice(0, 160)}"`).join('\n')
    : '- (no purchase on record)';
  return [
    'THE ITEM (from the venue bible):', spec, '',
    'WHAT WE PAID (our order tracker; the unit may be a case - work out the price per piece from the description when it says how many):', paid, '',
    'Find the sellers of this exact item and their current prices. Then answer with ONLY one JSON object, in a ```json block:',
    '{"exact_offers":[{"seller":"","url":"","price":0,"price_for":"each | dozen | case of 24 ...","pack_qty":1,"in_stock":true,"evidence":"the item # / specs the page shows"}],',
    ' "quote_required":[{"seller":"","url":"","note":"what the page says instead of a price"}],',
    ' "rejected":[{"seller":"","url":"","why":"which spec differs"}],',
    ' "our_unit_price":null, "our_unit_note":"how our price per piece was worked out, or why it could not be",',
    ' "notes":"anything a buyer should know (discontinued, backorder, minimum order, shipping)"}',
    'pack_qty = how many pieces the price buys. in_stock null when the page does not say. Empty arrays when none.',
  ].join('\n');
}

export interface Offer { seller: string; url: string; price: number; price_for: string; pack_qty: number; unit_price: number; in_stock: boolean | null; evidence: string }
export interface QuoteSeller { seller: string; url: string; note: string }
export interface Rejected { seller: string; url: string; why: string }
export interface Research { exact_offers: Offer[]; quote_required: QuoteSeller[]; rejected: Rejected[]; our_unit_price: number | null; our_unit_note: string; notes: string }

const str = (x: unknown, n = 400) => String(x ?? '').trim().slice(0, n);
const url = (x: unknown) => { const s = str(x, 600); return /^https?:\/\/\S+$/i.test(s) ? s : ''; };
const num = (x: unknown) => { const n = typeof x === 'number' ? x : Number(String(x ?? '').replace(/[$,\s]/g, '')); return Number.isFinite(n) && n > 0 ? n : null; };

/** The model's answer -> the research, checked: the last JSON block (or the last {...}); offers without a link or a
 *  price are dropped; the price per piece is worked out here (price / pack_qty), not taken from the model. Null when
 *  there is no JSON at all. */
export function readResearch(text: string): Research | null {
  const fences = [...String(text ?? '').matchAll(/```(?:json)?\s*([\s\S]*?)```/gi)].map(m => m[1]);
  const candidates = fences.length ? fences.reverse() : [];
  const s = String(text ?? '');
  const a = s.indexOf('{'), z = s.lastIndexOf('}');
  if (a >= 0 && z > a) candidates.push(s.slice(a, z + 1));
  let raw: Record<string, unknown> | null = null;
  for (const c of candidates) { try { const v = JSON.parse(c); if (v && typeof v === 'object' && !Array.isArray(v)) { raw = v; break; } } catch { /* next */ } }
  if (!raw) return null;
  const arr = (k: string) => (Array.isArray(raw![k]) ? raw![k] as Record<string, unknown>[] : []).filter(x => x && typeof x === 'object');
  const offers: Offer[] = [];
  for (const o of arr('exact_offers')) {
    const price = num(o.price), u = url(o.url);
    if (!price || !u) continue;
    const pack = Math.max(1, Math.round(num(o.pack_qty) ?? 1));
    offers.push({ seller: str(o.seller, 120) || new URL(u).hostname, url: u, price, price_for: str(o.price_for, 80), pack_qty: pack,
      unit_price: Math.round((price / pack) * 10000) / 10000, in_stock: typeof o.in_stock === 'boolean' ? o.in_stock : null, evidence: str(o.evidence) });
  }
  return {
    exact_offers: offers,
    quote_required: arr('quote_required').map(q => ({ seller: str(q.seller, 120), url: url(q.url), note: str(q.note) })).filter(q => q.seller || q.url),
    rejected: arr('rejected').map(r => ({ seller: str(r.seller, 120), url: url(r.url), why: str(r.why) })).filter(r => r.seller || r.url).slice(0, 12),
    our_unit_price: num(raw.our_unit_price),
    our_unit_note: str(raw.our_unit_note),
    notes: str(raw.notes, 1000),
  };
}

export type PcStatus = 'overpaying' | 'ok' | 'market_only' | 'quote_required' | 'not_found' | 'no_item_no' | 'error';
export interface Verdict { status: PcStatus; best: Offer | null; our_unit_price: number | null; savings_pct: number | null }

/** Our price per piece when the model could not work it out: a line bought by the piece is its price. */
export function ourUnitPrice(research: Pick<Research, 'our_unit_price'> | null, purchases: readonly Purchase[]): number | null {
  if (research?.our_unit_price) return research.our_unit_price;
  const p = purchases[0];
  return p && /^(ea|each|pc|pcs|piece|unit)s?$/i.test(String(p.unit ?? '').trim()) ? p.unit_price : null;
}

/** The verdict: the cheapest exact offer per piece against ours. Overpaying = someone sells the exact item at least
 *  `overpayPct` % cheaper per piece; ok = we pay no more than that; market_only = offers, but nothing of ours to
 *  compare; quote_required = the item is listed only behind "request a quote"; not_found = nobody lists it. */
export function verdict(item: Pick<PcItem, 'checkable'>, research: Research | null, purchases: readonly Purchase[], overpayPct = 10): Verdict {
  if (!item.checkable) return { status: 'no_item_no', best: null, our_unit_price: null, savings_pct: null };
  if (!research) return { status: 'error', best: null, our_unit_price: null, savings_pct: null };
  const ours = ourUnitPrice(research, purchases);
  const best = [...research.exact_offers].sort((a, b) => a.unit_price - b.unit_price)[0] ?? null;
  if (!best) return { status: research.quote_required.length ? 'quote_required' : 'not_found', best: null, our_unit_price: ours, savings_pct: null };
  if (!ours) return { status: 'market_only', best, our_unit_price: null, savings_pct: null };
  const savings = Math.round(((ours - best.unit_price) / ours) * 1000) / 10;
  return { status: savings >= overpayPct ? 'overpaying' : 'ok', best, our_unit_price: ours, savings_pct: savings };
}

/** The run's spend has reached its budget: no more items are started this week. */
export function overBudget(spentUsd: number, budgetUsd: number | null | undefined): boolean {
  return Number(budgetUsd) > 0 && Number(spentUsd) >= Number(budgetUsd);
}
