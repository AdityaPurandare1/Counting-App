/* ───────────────────────────────────────────────────────────────────────
   Order tracker (v0.79) — pure logic for the admin Purchasing > Order tracker
   tab. Tables: kount_ot_* (migration 0132). No Supabase calls in here, so
   every rule below is unit-tested (tests/orderTracker.test.ts).

   LIFECYCLE (per order LINE — h.wood's own cycle with E&E and the custom
   vendors, prepaid: the vendor invoices and is paid BEFORE it ships):
     REQUESTED → ORDERED → QUOTED → INVOICED → PAID → SHIPPED → DELIVERED
     → RECEIVED          CANCELLED ends a line early.
   Delivered = the carrier / vendor says it arrived; received = we counted it
   in (the warehouse Receive, or by hand). An order is only as far along as
   its least-advanced line (the bottleneck), and done when every line is
   received.

   WAREHOUSE STOCK (per item, in the item's unit — usually cases):
     receipt +qty (a delivered line received into the warehouse)
     release −qty (sent to a venue)
     count   =qty (on hand as counted; later moves apply on top)
   ─────────────────────────────────────────────────────────────────────── */

export const STATUSES = ['REQUESTED', 'ORDERED', 'QUOTED', 'INVOICED', 'PAID', 'SHIPPED', 'DELIVERED', 'RECEIVED'] as const;
export type LineStatus = typeof STATUSES[number] | 'CANCELLED';
export const ALL_STATUSES: readonly LineStatus[] = [...STATUSES, 'CANCELLED'];

export const STATUS_LABEL: Record<LineStatus, string> = {
  REQUESTED: 'Requested', ORDERED: 'Ordered', QUOTED: 'Quoted', INVOICED: 'Invoiced', PAID: 'Paid',
  SHIPPED: 'Shipped', DELIVERED: 'Delivered', RECEIVED: 'Received', CANCELLED: 'Cancelled',
};

/** Position in the cycle; CANCELLED sorts after PAID (it is terminal). */
export function statusRank(s: LineStatus): number {
  return s === 'CANCELLED' ? STATUSES.length : STATUSES.indexOf(s);
}

export interface OtItem {
  id: string;
  name: string;
  sku: string | null;
  vendor_name: string | null;
  category: string | null;
  unit: string;
  pack_size: number | null;
  lead_time_days: number | null;
  reorder_point: number | null;
  track_stock: boolean;
  notes: string | null;
  is_active: boolean;
}

export interface OtOrder {
  id: string;
  order_number: string | null;
  vendor_name: string;
  venue_id: string | null;
  deliver_to: 'warehouse' | 'venue';
  ordered_on: string | null;
  expected_on: string | null;
  notes: string | null;
  completed_at: string | null;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface OtLine {
  id: string;
  order_id: string;
  item_id: string | null;
  description: string;
  sku: string | null;
  qty: number;
  unit: string | null;
  unit_price: number | null;
  status: LineStatus;
  status_at: string;
  quote_number: string | null;
  invoice_number: string | null;
  invoice_date: string | null;
  tracking_number: string | null;
  expected_on: string | null;
  sort: number;
  updated_at?: string;
  /** this line's venue when the order serves several (0140); null = the order's venue */
  venue_id?: string | null;
  /** an E&E storage line: its stock draw recorded, or marked not one (0141) */
  stock_draw?: StockDraw | null;
}

export interface OtMove {
  id: string;
  item_id: string;
  moved_on: string;           // YYYY-MM-DD
  kind: 'receipt' | 'release' | 'count';
  qty: number;
  venue_id: string | null;
  line_id: string | null;
  note: string | null;
  created_at: string;
  created_by?: string | null;
}

export interface OtDocument {
  id: string;
  order_id: string | null;
  /** 'payment' = a check stub (0139) */
  kind: DocKind | 'payment';
  doc_number: string | null;
  doc_date: string | null;
  vendor_name: string | null;
  total: number | null;
  file_name: string | null;
  storage_path: string | null;
  created_at: string;
  uploaded_by?: string | null;
  source_conversation_id?: string | null;
}

export type DocKind = 'quote' | 'confirmation' | 'invoice' | 'shipping' | 'other';

/** Venues an order can be FOR that Kount does not count (orders only). Their ids carry an 'x:' prefix. */
export const ORDER_ONLY_VENUES: Array<{ id: string; name: string }> = [
  { id: 'x:Delilah Dallas', name: 'Delilah Dallas' },
  { id: 'x:h.wood Corporate', name: 'h.wood Corporate' },
];
/** An order whose lines serve several venues (0140). */
export const MULTIPLE_VENUES = 'x:Multiple venues';
export const orderVenues = (counting: Array<{ id: string; name: string }>) => [...counting, ...ORDER_ONLY_VENUES.filter(x => !counting.some(v => v.name === x.name))];
export function orderVenueName(id: string | null, counting: Array<{ id: string; name: string }>): string {
  if (!id) return 'Warehouse';
  return orderVenues(counting).find(v => v.id === id)?.name ?? (id.startsWith('x:') ? id.slice(2) : id);
}

/** A tracking number on an order (kount_ot_tracking, 0137) — from a vendor email, a shipping notice or by hand. */
export interface OtTracking {
  id: string;
  order_id: string;
  tracking_number: string;
  carrier: string | null;
  source: 'email' | 'document' | 'manual';
  note: string | null;
  created_at: string;
  created_by?: string | null;
}

/* ── numbers / dates ──────────────────────────────────────────────────── */

const n = (x: unknown): number => { const v = Number(x); return Number.isFinite(v) ? v : 0; };

export function lineTotal(l: Pick<OtLine, 'qty' | 'unit_price'>): number {
  return n(l.qty) * n(l.unit_price);
}

/** Local YYYY-MM-DD. */
export function isoDay(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function addDays(day: string, days: number): string {
  const [y, m, d] = day.split('-').map(Number);
  return isoDay(new Date(y, m - 1, d + Math.round(days)));
}

function daysBetween(a: string, b: string): number {
  const [y1, m1, d1] = a.split('-').map(Number);
  const [y2, m2, d2] = b.split('-').map(Number);
  return Math.round((new Date(y2, m2 - 1, d2).getTime() - new Date(y1, m1 - 1, d1).getTime()) / 86_400_000);
}

/* ── orders ───────────────────────────────────────────────────────────── */

/** The order's status: its least-advanced live line. All cancelled → CANCELLED; no lines → null. */
export function headlineStatus(lines: Pick<OtLine, 'status'>[]): LineStatus | null {
  if (!lines.length) return null;
  const live = lines.filter(l => l.status !== 'CANCELLED');
  if (!live.length) return 'CANCELLED';
  return live.reduce((m, l) => (statusRank(l.status) < statusRank(m) ? l.status : m), live[0].status);
}

export type OrderState = 'open' | 'completed' | 'archived';

/** Archived (never a real order) > completed (finished by hand, or every live line received) > open. */
export function orderState(o: Pick<OtOrder, 'completed_at' | 'archived_at'>, lines: Pick<OtLine, 'status'>[]): OrderState {
  if (o.archived_at) return 'archived';
  if (o.completed_at) return 'completed';
  const h = headlineStatus(lines);
  if (h === 'RECEIVED' || h === 'CANCELLED') return 'completed';
  return 'open';
}

/* ── the Orders list: venue filter + sorting ─────────────────────────── */

/** The venues an order serves: its own, or each line's when it serves several. */
export function orderVenueIds(o: Pick<OtOrder, 'venue_id'>, lines: Array<Pick<OtLine, 'venue_id'>>): string[] {
  const ids = new Set<string>();
  for (const l of lines) { const v = l.venue_id ?? o.venue_id; if (v && v !== MULTIPLE_VENUES) ids.add(v); }
  if (!ids.size && o.venue_id && o.venue_id !== MULTIPLE_VENUES) ids.add(o.venue_id);
  return [...ids];
}

export type OrderSort = 'newest' | 'oldest' | 'total-desc' | 'total-asc' | 'expected' | 'updated' | 'status' | 'number' | 'vendor' | 'venue';
export const ORDER_SORTS: Array<[OrderSort, string]> = [
  ['newest', 'Newest first'], ['oldest', 'Oldest first'], ['total-desc', 'Total: high to low'], ['total-asc', 'Total: low to high'],
  ['expected', 'Expected soonest'], ['updated', 'Last status change'], ['status', 'Status (earliest stage first)'],
  ['number', 'Order #'], ['vendor', 'Vendor A–Z'], ['venue', 'Venue A–Z'],
];

export interface OrderRow { o: OtOrder; ls: OtLine[] }
const orderDay = (r: OrderRow) => r.o.ordered_on ?? r.o.created_at.slice(0, 10);
const orderTotal = (r: OrderRow) => r.ls.filter(l => l.status !== 'CANCELLED').reduce((s, l) => s + lineTotal(l), 0);
const orderExpected = (r: OrderRow) => [r.o.expected_on, ...r.ls.filter(l => l.status !== 'CANCELLED' && statusRank(l.status) < statusRank('DELIVERED')).map(l => l.expected_on)]
  .filter((x): x is string => !!x).sort()[0] ?? null;
const orderUpdated = (r: OrderRow) => r.ls.map(l => l.status_at).sort().slice(-1)[0] ?? r.o.created_at;

/** Rows for one venue (an order matches when it, or any of its lines, is for that venue). */
export function filterByVenue<T extends OrderRow>(rows: T[], venue: string): T[] {
  return venue ? rows.filter(r => orderVenueIds(r.o, r.ls).includes(venue)) : rows;
}

/** A copy of the rows in the chosen order; ties fall back to newest first. Empty values sort last. */
export function sortOrders<T extends OrderRow>(rows: T[], sort: OrderSort, venueName: (id: string | null) => string): T[] {
  const newest = (a: T, b: T) => orderDay(b).localeCompare(orderDay(a));
  const lastIfEmpty = (x: string | null, y: string | null) => (x === y ? 0 : x === null ? 1 : y === null ? -1 : x.localeCompare(y));
  const by: Record<OrderSort, (a: T, b: T) => number> = {
    newest, oldest: (a, b) => -newest(a, b),
    'total-desc': (a, b) => orderTotal(b) - orderTotal(a), 'total-asc': (a, b) => orderTotal(a) - orderTotal(b),
    expected: (a, b) => lastIfEmpty(orderExpected(a), orderExpected(b)),
    updated: (a, b) => orderUpdated(b).localeCompare(orderUpdated(a)),
    status: (a, b) => statusRank(headlineStatus(a.ls) ?? 'REQUESTED') - statusRank(headlineStatus(b.ls) ?? 'REQUESTED'),
    number: (a, b) => (a.o.order_number ?? '~').localeCompare(b.o.order_number ?? '~', undefined, { numeric: true }),
    vendor: (a, b) => a.o.vendor_name.localeCompare(b.o.vendor_name),
    venue: (a, b) => lastIfEmpty(orderVenueIds(a.o, a.ls).map(v => venueName(v)).sort()[0] ?? null, orderVenueIds(b.o, b.ls).map(v => venueName(v)).sort()[0] ?? null),
  };
  return [...rows].sort((a, b) => by[sort](a, b) || newest(a, b));
}

/** Count of lines per status, in cycle order (the order card's bar). */
export function statusMix(lines: Pick<OtLine, 'status'>[]): Array<{ status: LineStatus; count: number }> {
  return ALL_STATUSES.map(s => ({ status: s, count: lines.filter(l => l.status === s).length })).filter(x => x.count > 0);
}

/** A live line whose expected date has passed and that is not delivered yet.
 *  `received` (warehouse receipts against the line): a fully received line is
 *  not late even when nobody moved its status on. */
export function isLate(l: Pick<OtLine, 'status' | 'expected_on' | 'qty'>, order: Pick<OtOrder, 'expected_on'>, today: string, received = 0): boolean {
  if (l.status === 'CANCELLED' || statusRank(l.status) >= statusRank('DELIVERED')) return false;
  if (n(l.qty) > 0 && received >= n(l.qty)) return false;
  const due = l.expected_on || order.expected_on;
  return !!due && due < today;
}

/* ── documents → line updates ─────────────────────────────────────────── */

// an order confirmation is the vendor confirming the ORDER (before its quote / invoice)
const DOC_STATUS: Record<DocKind, LineStatus | null> = {
  quote: 'QUOTED', confirmation: 'ORDERED', invoice: 'INVOICED', shipping: 'SHIPPED', other: null,
};

/** The status a document moves a line to. Documents only move lines FORWARD:
 *  an invoice arriving for a line already PAID, or a quote for a line
 *  already invoiced, leaves the status alone (it still records the numbers). */
export function statusAfterDocument(current: LineStatus | null, kind: DocKind): LineStatus | null {
  const target = DOC_STATUS[kind];
  if (!target) return current;
  if (current === null) return target;
  if (current === 'CANCELLED') return current;
  return statusRank(target) > statusRank(current) ? target : current;
}

/** Normalised text for matching ("Delilah To-Go Bag, 250/cs" ≈ "DELILAH TOGO BAG 250CS"). */
export function normText(s: string | null | undefined): string {
  return String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function words(s: string): Set<string> { return new Set(normText(s).split(' ').filter(w => w.length > 1)); }

/** Word-overlap similarity 0..1 (Jaccard). */
export function similarity(a: string, b: string): number {
  const A = words(a), B = words(b);
  if (!A.size || !B.size) return 0;
  let inter = 0;
  A.forEach(w => { if (B.has(w)) inter++; });
  return inter / (A.size + B.size - inter);
}

export interface DocLine {
  line_kind: 'product' | 'freight' | 'tax' | 'fee' | 'discount';
  description: string;
  sku: string;
  qty: number;
  unit: string;
  unit_price: number;
  line_total: number;
  pack_size: number;
}

/** The existing order line a document line most likely is: same SKU first,
 *  then the closest description (≥ 0.5 word overlap). Each existing line is
 *  matched at most once — two document lines never land on one order line. */
export function matchDocLines(docLines: DocLine[], existing: OtLine[]): Array<OtLine | null> {
  const used = new Set<string>();
  return docLines.map(dl => {
    const sku = normText(dl.sku);
    if (sku) {
      const bySku = existing.find(l => !used.has(l.id) && normText(l.sku) === sku);
      if (bySku) { used.add(bySku.id); return bySku; }
    }
    let best: OtLine | null = null, bestScore = 0;
    for (const l of existing) {
      if (used.has(l.id)) continue;
      const s = similarity(dl.description, l.description);
      if (s > bestScore) { bestScore = s; best = l; }
    }
    if (best && bestScore >= 0.5) { used.add(best.id); return best; }
    return null;
  });
}

/** The catalog item a description / SKU belongs to: exact SKU, else exact name, else ≥ 0.6 overlap. */
export function matchItem(items: OtItem[], description: string, sku: string | null): OtItem | null {
  const s = normText(sku);
  if (s) {
    const bySku = items.find(i => i.is_active && normText(i.sku) === s);
    if (bySku) return bySku;
  }
  const d = normText(description);
  const byName = items.find(i => i.is_active && normText(i.name) === d);
  if (byName) return byName;
  let best: OtItem | null = null, bestScore = 0;
  for (const i of items) {
    if (!i.is_active) continue;
    const sc = similarity(description, i.name);
    if (sc > bestScore) { bestScore = sc; best = i; }
  }
  return best && bestScore >= 0.6 ? best : null;
}

/** Two vendor names for the same company ("Uline" ≈ "ULINE Inc."). A blank name never blocks a match. */
export function sameVendor(a: string | null | undefined, b: string | null | undefined): boolean {
  const x = normText(a), y = normText(b);
  if (!x || !y) return true;
  return x === y || x.includes(y) || y.includes(x) || similarity(x, y) >= 0.5;
}

/** The order a document belongs to: the order whose number equals the
 *  document's order number, else one holding a line with that quote number
 *  (or, for an invoice, that invoice number), else null (the reviewer picks,
 *  or a new order is created). Only orders from the document's vendor count:
 *  PO numbers like "1001" repeat across vendors. */
export function matchOrder(orders: OtOrder[], lines: OtLine[], doc: { order_number: string; doc_number: string; kind: DocKind; vendor_name?: string }): OtOrder | null {
  const fits = (o: OtOrder | undefined): o is OtOrder => !!o && !o.archived_at && sameVendor(o.vendor_name, doc.vendor_name);
  const byId = new Map(orders.map(o => [o.id, o]));
  const on = normText(doc.order_number);
  if (on) {
    const o = orders.find(x => normText(x.order_number) === on && fits(x));
    if (o) return o;
  }
  const dn = normText(doc.doc_number);
  if (dn) {
    const withQuote = lines.find(l => normText(l.quote_number) === dn && fits(byId.get(l.order_id)));
    if (withQuote) return byId.get(withQuote.order_id)!;
    if (doc.kind === 'invoice') {
      const withInvoice = lines.find(l => normText(l.invoice_number) === dn && fits(byId.get(l.order_id)));
      if (withInvoice) return byId.get(withInvoice.order_id)!;
    }
  }
  return null;
}

/* ── a reviewed document → one save ───────────────────────────────────── */

export const DOC_KIND_LABEL: Record<DocKind, string> = { quote: 'Quote', confirmation: 'Order confirmation', invoice: 'Invoice', shipping: 'Shipping notice', other: 'Other' };

/** One document line in the review: save it or not, onto which order line
 *  ('new' = add it), and which catalog item it is. */
export interface DocRowPlan {
  doc: DocLine;
  include: boolean;
  target: string;
  itemId: string;        // '' = none
  addItem: boolean;      // create a catalog item from this line
}

const negative = (dl: DocLine) => dl.line_total < 0 || dl.unit_price < 0 || dl.qty < 0;

/** The first plan for a document's lines. Ticked by default: products, and on
 *  an invoice the non-tax charges (freight, fees). Never a negative line, and
 *  nothing on a credit memo — a credit saved as order lines would count as new
 *  spend (vendors print credits with positive amounts too). */
export function planDocRows(docLines: DocLine[], orderLines: OtLine[], items: OtItem[], kind: DocKind, isCredit = false): DocRowPlan[] {
  const matched = matchDocLines(docLines, orderLines);
  return docLines.map((dl, i) => {
    const existing = matched[i];
    const item = existing?.item_id ? items.find(it => it.id === existing.item_id) ?? null : matchItem(items, dl.description, dl.sku || null);
    return {
      doc: dl,
      include: !isCredit && !negative(dl) && (dl.line_kind === 'product' || (dl.line_kind !== 'tax' && kind === 'invoice' && Math.abs(dl.line_total) > 0)),
      target: existing?.id ?? 'new',
      itemId: item?.id ?? '',
      addItem: false,
    };
  });
}

/** Everything a reviewed document changes, applied in ONE transaction by
 *  kount_ot_apply_document (0132). `item_key` ties a line to one of
 *  `new_items`; an update changes only the keys it carries. */
export interface ApplyDocument {
  note: string;
  /** A PDF from the morning mail pull (kount_ot_inbox, 0135): closed in the same transaction. */
  inbox_id?: string;
  decision?: string;
  order_id?: string;
  order_patch?: { order_number?: string; expected_on?: string; venue_id?: string };
  new_order?: { vendor_name: string; order_number: string | null; venue_id: string | null; deliver_to: 'warehouse' | 'venue'; ordered_on: string | null; expected_on: string | null };
  new_items: Array<{ key: string; name: string; sku: string | null; vendor_name: string; unit: string; pack_size: number | null }>;
  updates: Array<{ id: string; item_id?: string; item_key?: string } & Partial<Pick<OtLine, 'status' | 'unit_price' | 'quote_number' | 'invoice_number' | 'invoice_date' | 'tracking_number' | 'expected_on'>>>;
  new_lines: Array<{
    item_id: string | null; item_key?: string; description: string; sku: string | null; qty: number; unit: string | null; unit_price: number | null;
    status: LineStatus; quote_number: string | null; invoice_number: string | null; invoice_date: string | null; tracking_number: string | null; expected_on: string | null;
    venue_id?: string | null;
  }>;
  document: {
    id: string; kind: DocKind; doc_number: string | null; doc_date: string | null; vendor_name: string; total: number | null; file_name: string; storage_path: string; parsed: unknown;
    /** the email it came from: a later document in the same thread finds this order */
    source_message_id?: string | null; source_conversation_id?: string | null;
  };
}

export interface DocReview {
  docId: string; kind: DocKind; vendor: string; docNumber: string; docDate: string; orderNumber: string; expected: string; tracking: string;
  /** null = a new order */
  order: OtOrder | null; orderLines: OtLine[];
  deliverTo: 'warehouse' | 'venue'; venueId: string;
  rows: DocRowPlan[]; today: string; fileName: string; storagePath: string; total: number | null; parsed: unknown;
}

/** A line that already carries a DIFFERENT invoice number keeps it, and its
 *  price: that number and price are the other invoice's price point. */
const otherInvoice = (cur: OtLine, kind: DocKind, docNumber: string) =>
  kind === 'invoice' && !!cur.invoice_number && !!docNumber.trim() && normText(cur.invoice_number) !== normText(docNumber);

export function planDocumentSave(r: DocReview): ApplyDocument {
  const vendor = r.vendor.trim(), docNumber = r.docNumber.trim();
  const out: ApplyDocument = {
    note: `${DOC_KIND_LABEL[r.kind]}${docNumber ? ' ' + docNumber : ''}`,
    new_items: [], updates: [], new_lines: [],
    document: { id: r.docId, kind: r.kind, doc_number: docNumber || null, doc_date: r.docDate || null, vendor_name: vendor,
                total: r.total || null, file_name: r.fileName, storage_path: r.storagePath, parsed: r.parsed },
  };
  if (r.order) {
    out.order_id = r.order.id;
    const patch: ApplyDocument['order_patch'] = {};
    if (!r.order.order_number && r.orderNumber.trim()) patch.order_number = r.orderNumber.trim();
    if (r.expected && (r.kind === 'confirmation' || !r.order.expected_on)) patch.expected_on = r.expected;
    if (Object.keys(patch).length) out.order_patch = patch;
  } else {
    out.new_order = {
      vendor_name: vendor, order_number: r.orderNumber.trim() || null, venue_id: r.venueId || null, deliver_to: r.deliverTo,
      ordered_on: r.kind === 'quote' ? null : (r.docDate || r.today), expected_on: r.expected || null,
    };
  }
  r.rows.forEach((row, i) => {
    if (!row.include) return;
    const dl = row.doc;
    let ref: { item_id: string } | { item_key: string } | null = null;
    if (row.itemId) ref = { item_id: row.itemId };
    else if (row.addItem) {
      const key = 'n' + i;
      out.new_items.push({ key, name: dl.description.trim(), sku: dl.sku.trim() || null, vendor_name: vendor,
                           unit: dl.unit.trim() || 'case', pack_size: dl.pack_size > 0 ? dl.pack_size : null });
      ref = { item_key: key };
    }
    const price = dl.unit_price > 0 ? dl.unit_price : null;
    const cur = row.target !== 'new' ? r.orderLines.find(l => l.id === row.target) : undefined;
    if (cur) {
      const u: ApplyDocument['updates'][number] = { id: cur.id };
      const next = statusAfterDocument(cur.status, r.kind);
      if (next && next !== cur.status) u.status = next;
      const keepInvoice = otherInvoice(cur, r.kind, docNumber);
      // the invoice sets the price; a quote only while nothing is invoiced yet (a late quote never overwrites it)
      const quoteMayPrice = r.kind === 'quote' && !cur.invoice_number && statusRank(cur.status) < statusRank('INVOICED');
      if (price != null && !keepInvoice && (r.kind === 'invoice' || quoteMayPrice || cur.unit_price == null)) u.unit_price = price;
      if (r.kind === 'quote' && docNumber) u.quote_number = docNumber;
      if (r.kind === 'invoice' && docNumber && !keepInvoice) { u.invoice_number = docNumber; u.invoice_date = r.docDate || r.today; }
      if (r.kind === 'shipping' && r.tracking) u.tracking_number = r.tracking;
      if (r.expected && (r.kind === 'confirmation' || r.kind === 'shipping')) u.expected_on = r.expected;
      if (ref && !cur.item_id) Object.assign(u, ref);
      if (Object.keys(u).length > 1) out.updates.push(u);
    } else {
      out.new_lines.push({
        item_id: ref && 'item_id' in ref ? ref.item_id : null, ...(ref && 'item_key' in ref ? { item_key: ref.item_key } : {}),
        description: dl.description.trim() || dl.line_kind, sku: dl.sku.trim() || null, qty: dl.qty > 0 ? dl.qty : 1,
        unit: dl.unit.trim() || null, unit_price: price ?? (dl.line_total > 0 && dl.qty <= 0 ? dl.line_total : null),
        status: statusAfterDocument(null, r.kind) ?? 'ORDERED',
        quote_number: r.kind === 'quote' ? docNumber || null : null,
        invoice_number: r.kind === 'invoice' ? docNumber || null : null,
        invoice_date: r.kind === 'invoice' ? r.docDate || r.today : null,
        tracking_number: r.kind === 'shipping' ? r.tracking || null : null,
        expected_on: r.expected || null,
      });
    }
  });
  return out;
}

/** What a person should see before saving a document. */
export function documentChecks(r: Pick<DocReview, 'kind' | 'vendor' | 'docNumber' | 'order' | 'orderLines' | 'rows'>,
                               printed: { subtotal: number; total: number; lines: DocLine[]; is_credit?: boolean },
                               known: { documents: OtDocument[]; lines: OtLine[]; orders: OtOrder[] }, fmt: (x: number) => string): string[] {
  const out: string[] = [];
  const docNumber = r.docNumber.trim();
  const sum = printed.lines.reduce((s, l) => s + (Number(l.line_total) || 0), 0);
  const productSum = printed.lines.filter(l => l.line_kind === 'product').reduce((s, l) => s + (Number(l.line_total) || 0), 0);
  // vendors print the subtotal over products only, products + freight / fees, or everything
  const preTax = printed.lines.filter(l => l.line_kind !== 'tax').reduce((s, l) => s + (Number(l.line_total) || 0), 0);
  if (printed.subtotal > 0 && [productSum, preTax, sum].every(x => Math.abs(x - printed.subtotal) > 0.05)) {
    out.push(`Lines add up to ${fmt(productSum)} but the printed subtotal is ${fmt(printed.subtotal)} — a line may be misread or missing.`);
  }
  printed.lines.forEach(l => {
    if (l.qty > 0 && l.unit_price > 0 && l.line_total > 0 && Math.abs(l.qty * l.unit_price - l.line_total) > Math.max(0.05, l.line_total * 0.01)) {
      out.push(`"${l.description}": ${l.qty} × ${fmt(l.unit_price)} ≠ ${fmt(l.line_total)}.`);
    }
  });
  if (printed.is_credit) {
    out.push('This is a credit memo. Nothing on it is ticked: saved as order lines it would count as new spend.');
  } else if (printed.total < 0 || printed.lines.some(negative)) {
    out.push('This looks like a credit memo (negative amounts). Negative lines are left unticked: saved as order lines they would count as new spend.');
  }
  if (docNumber) {
    const label = DOC_KIND_LABEL[r.kind].toLowerCase();
    const dup = known.documents.find(d => d.kind === r.kind && normText(d.doc_number) === normText(docNumber) && sameVendor(d.vendor_name, r.vendor));
    if (dup) out.push(`This ${label} (${docNumber}) from ${dup.vendor_name || r.vendor} was already added on ${dup.created_at.slice(0, 10)}. Saving it again counts it twice.`);
    if (r.kind === 'invoice' && !dup) {
      const orderById = new Map(known.orders.map(o => [o.id, o]));
      // lines of the order it is being saved to don't count: saving updates those same lines
      const onLines = known.lines.filter(l => normText(l.invoice_number) === normText(docNumber) && l.order_id !== r.order?.id
        && sameVendor(orderById.get(l.order_id)?.vendor_name, r.vendor));
      if (onLines.length) out.push(`Invoice ${docNumber} is already on ${onLines.length} line${onLines.length === 1 ? '' : 's'} of ${r.vendor || 'this vendor'}'s orders. Check it is not being entered twice.`);
    }
  }
  if (r.order && !sameVendor(r.order.vendor_name, r.vendor)) {
    out.push(`The chosen order is from ${r.order.vendor_name}, but the document says ${r.vendor}. Check it is the right order.`);
  }
  for (const row of r.rows) {
    if (!row.include || row.target === 'new') continue;
    const cur = r.orderLines.find(l => l.id === row.target);
    if (!cur) continue;
    if (otherInvoice(cur, r.kind, docNumber)) {
      out.push(`"${cur.description}" is already on invoice ${cur.invoice_number}; it keeps that number and price. Choose "Add as a new line" if this is a separate invoice.`);
    }
    if (row.doc.line_kind === 'product' && row.doc.qty > 0 && Math.abs(row.doc.qty - cur.qty) > 1e-9) {
      out.push(`"${cur.description}": the document says ${row.doc.qty}, the order line says ${cur.qty}. The line keeps ${cur.qty}; change it on the order if the quantity really changed.`);
    }
  }
  return out;
}

/* ── the morning mail pull: apply it, or let a person look ────────────── */

/** A document as the reader returns it (kount-read-purchase-doc / _shared/purchase-doc.ts). */
export interface ReadDoc {
  doc_kind: DocKind;
  is_credit?: boolean;
  vendor_name: string;
  bill_to?: string;
  ship_to?: string;
  doc_number: string;
  doc_date: string;
  order_number: string;
  expected_date: string;
  tracking_numbers: string[];
  subtotal: number;
  total: number;
  lines: DocLine[];
}

/** The email a PDF came in (kount_ot_inbox). */
export interface MailSource { id: string; message_id: string; conversation_id: string | null; file_name: string | null; storage_path: string }

export type MailDecision =
  | { state: 'applied'; payload: ApplyDocument; reason: string }
  | { state: 'pending'; reason: string; orderId: string | null }
  | { state: 'ignored'; reason: string };

const isoDate = (s: string | null | undefined) => (/^\d{4}-\d{2}-\d{2}$/.test(String(s ?? '')) ? String(s) : '');

/** The venue a document is for, from its Ship to / Bill to name ("Delilah LA", "The Nice Guy"). null when unsure. */
export function venueForDoc(doc: Pick<ReadDoc, 'bill_to' | 'ship_to'>, venues: Array<{ id: string; name: string }>): { id: string; name: string } | null {
  let best: { id: string; name: string } | null = null, bestScore = 0;
  for (const label of [doc.ship_to, doc.bill_to]) {
    const l = normText(label);
    if (!l) continue;
    for (const v of venues) {
      const n = normText(v.name);
      if (!n) continue;
      const score = l === n ? 1 : (` ${l} `.includes(` ${n} `) || ` ${n} `.includes(` ${l} `)) ? 0.9 : similarity(l, n);
      if (score > bestScore) { bestScore = score; best = v; }
    }
    if (bestScore >= 0.9) break;          // the Ship to settles it
  }
  return best && bestScore >= 0.6 ? best : null;
}

export interface MailDecideOptions {
  /** create a new order from a quote / invoice / confirmation that matches none (0138) */
  autoCreate?: boolean;
  venues?: Array<{ id: string; name: string }>;
}

/** What the morning pull does with one read PDF. It saves on its own ONLY
 *  when the document clearly belongs to one existing order (an earlier
 *  document in the same email thread, else the PO / quote / invoice number
 *  from the same vendor), every product on it is already on that order, and
 *  none of the review checks fire. Everything else waits for a person. */
export function decideMailDocument(doc: ReadDoc, src: MailSource,
                                   data: { orders: OtOrder[]; lines: OtLine[]; items: OtItem[]; documents: OtDocument[] },
                                   today: string, fmt: (x: number) => string, opts: MailDecideOptions = {}): MailDecision {
  if (!doc || !Array.isArray(doc.lines)) return { state: 'pending', reason: 'The reader returned nothing usable — open the PDF.', orderId: null };
  const docNumber = String(doc.doc_number ?? '').trim();
  if (docNumber && doc.doc_kind !== 'other') {
    const saved = data.documents.find(d => d.kind === doc.doc_kind && normText(d.doc_number) === normText(docNumber) && sameVendor(d.vendor_name, doc.vendor_name));
    if (saved) return { state: 'ignored', reason: `Already saved on ${saved.created_at.slice(0, 10)} (${DOC_KIND_LABEL[doc.doc_kind].toLowerCase()} ${docNumber}).` };
  }
  if (doc.is_credit) return { state: 'pending', reason: 'A credit memo — check it against the order by hand.', orderId: null };
  if (doc.doc_kind === 'other') return { state: 'ignored', reason: 'Not a quote, order confirmation, invoice or shipping notice.' };

  const live = (id: string | null | undefined) => data.orders.find(o => o.id === id && !o.archived_at);
  let order: OtOrder | null = null, how = '';
  if (src.conversation_id) {
    const sameThread = data.documents.filter(d => d.source_conversation_id === src.conversation_id && d.order_id)
      .map(d => live(d.order_id)).filter((o): o is OtOrder => !!o && sameVendor(o.vendor_name, doc.vendor_name));
    const ids = new Set(sameThread.map(o => o.id));
    if (ids.size === 1) { order = sameThread[0]; how = 'same email thread'; }
  }
  if (!order) {
    order = matchOrder(data.orders, data.lines, { order_number: doc.order_number, doc_number: docNumber, kind: doc.doc_kind, vendor_name: doc.vendor_name });
    if (order) how = doc.order_number && normText(order.order_number) === normText(doc.order_number) ? 'PO #' : 'document #';
  }
  if (!order) {
    if (opts.autoCreate && doc.doc_kind !== 'shipping') return newOrderFrom(doc, src, data, today, fmt, opts.venues ?? []);
    return { state: 'pending', reason: 'No matching order yet — create one from it.', orderId: null };
  }

  // One request = one order, even across venues (the user, 11/2): E&E answers a request in ONE thread and
  // invoices each venue separately. So a document of the thread's order always goes onto it; its lines are
  // matched only against that order's lines for the SAME venue, and anything new is added as new lines.
  const docVenue = venueForDoc(doc, opts.venues ?? [])?.id ?? null;
  const allLines = data.lines.filter(l => l.order_id === order!.id).sort((a, b) => a.sort - b.sort);
  const venueOf = (l: OtLine) => l.venue_id ?? order!.venue_id;
  const orderLines = docVenue ? allLines.filter(l => !venueOf(l) || venueOf(l) === docVenue) : allLines;
  const appendToThread = how === 'same email thread' && !!opts.autoCreate;
  const rows = planDocRows(doc.lines, orderLines, data.items, doc.doc_kind, false);
  if (appendToThread) {
    // a second invoice of the request for an item already invoiced is another charge: its own line
    for (const r of rows) {
      const cur = r.target === 'new' ? undefined : orderLines.find(l => l.id === r.target);
      if (cur && otherInvoice(cur, doc.doc_kind, docNumber)) r.target = 'new';
    }
  }
  const included = rows.filter(r => r.include);
  const label = order.order_number || `the ${order.vendor_name} order`;
  if (!included.length) return { state: 'pending', reason: `Nothing on it to record automatically on ${label}.`, orderId: order.id };
  const newProducts = included.filter(r => r.doc.line_kind === 'product' && r.target === 'new');
  if (newProducts.length && !appendToThread) {
    return { state: 'pending', reason: `${newProducts.length} item${newProducts.length === 1 ? ' is' : 's are'} not on ${label} yet — check before adding.`, orderId: order.id };
  }
  const review = { kind: doc.doc_kind, vendor: doc.vendor_name, docNumber, order, orderLines, rows };
  const checks = documentChecks(review, doc, data, fmt);
  if (checks.length) return { state: 'pending', reason: checks.join(' '), orderId: order.id };

  const payload = planDocumentSave({
    ...review, docId: src.id, docDate: isoDate(doc.doc_date), orderNumber: doc.order_number || '', expected: isoDate(doc.expected_date),
    tracking: (doc.tracking_numbers || []).join(', '), deliverTo: order.deliver_to, venueId: order.venue_id ?? '', today,
    fileName: src.file_name || 'document.pdf', storagePath: src.storage_path, total: doc.total, parsed: doc,
  });
  if (!payload.updates.length && !payload.new_lines.length) return { state: 'pending', reason: `Nothing changes on ${label}.`, orderId: order.id };
  // lines for another venue of the request: they carry their venue, and the order now serves several
  if (docVenue && order.venue_id !== docVenue && payload.new_lines.length) {
    if (!order.venue_id) payload.order_patch = { ...(payload.order_patch ?? {}), venue_id: docVenue };
    else {
      for (const l of payload.new_lines) l.venue_id = docVenue;
      if (order.venue_id !== MULTIPLE_VENUES) payload.order_patch = { ...(payload.order_patch ?? {}), venue_id: MULTIPLE_VENUES };
    }
  }
  const reason = newProducts.length ? `Added to ${label} (${how}).` : `Applied to ${label} (${how}).`;
  payload.note += ' — from email, applied automatically';
  payload.inbox_id = src.id;
  payload.decision = reason;
  payload.document.source_message_id = src.message_id;
  payload.document.source_conversation_id = src.conversation_id;
  return { state: 'applied', payload, reason };
}

/** A new order from a quote / invoice / confirmation nothing matched — the same save a person makes
 *  with "A new order", only when none of the review checks fire. */
function newOrderFrom(doc: ReadDoc, src: MailSource, data: { orders: OtOrder[]; lines: OtLine[]; items: OtItem[]; documents: OtDocument[] },
                      today: string, fmt: (x: number) => string, venues: Array<{ id: string; name: string }>): MailDecision {
  const docNumber = String(doc.doc_number ?? '').trim();
  const rows = planDocRows(doc.lines, [], data.items, doc.doc_kind, false);
  // a fee-only invoice (shipping fee, warehousing and delivery) is spend too: freight / fee lines start the order
  if (!rows.some(r => r.include)) {
    return { state: 'pending', reason: 'Nothing on it to start an order from — check the PDF.', orderId: null };
  }
  const review = { kind: doc.doc_kind, vendor: doc.vendor_name, docNumber, order: null, orderLines: [] as OtLine[], rows };
  const checks = documentChecks(review, doc, data, fmt);
  if (checks.length) return { state: 'pending', reason: `Not created automatically: ${checks.join(' ')}`, orderId: null };
  const venue = venueForDoc(doc, venues);
  const payload = planDocumentSave({
    ...review, docId: src.id, docDate: isoDate(doc.doc_date), orderNumber: doc.order_number || '', expected: isoDate(doc.expected_date),
    tracking: (doc.tracking_numbers || []).join(', '), deliverTo: venue ? 'venue' : 'warehouse', venueId: venue?.id ?? '', today,
    fileName: src.file_name || 'document.pdf', storagePath: src.storage_path, total: doc.total, parsed: doc,
  });
  const reason = `New order created from this ${DOC_KIND_LABEL[doc.doc_kind].toLowerCase()}${venue ? ` (for ${venue.name})` : ''}.`;
  payload.note += ' — from email, order created automatically';
  payload.inbox_id = src.id;
  payload.decision = reason;
  payload.document.source_message_id = src.message_id;
  payload.document.source_conversation_id = src.conversation_id;
  return { state: 'applied', payload, reason };
}

/* ── tracking numbers in vendor emails ────────────────────────────────── */

export type Carrier = 'UPS' | 'FedEx' | 'USPS' | 'DHL';
export interface TrackingHit { number: string; carrier: Carrier }

// digits only count as a tracking number when they sit right after one of these
const TRACK_WORD = /(track(ing)?|fedex|fed ex|\bups\b|usps|\bdhl\b|waybill|\bawb\b|shipped|shipment)/gi;

/** Tracking numbers written in an email ("here's the tracking Fedex with tracking# 879337642791
 *  and 879337641177"). A UPS 1Z number counts anywhere; plain digits only within 160 characters
 *  after a tracking / carrier word, and only in carrier lengths — so phone numbers, invoice
 *  numbers and dates are not taken. */
export function extractTracking(text: string | null | undefined): TrackingHit[] {
  const t = String(text ?? '');
  const out = new Map<string, TrackingHit>();
  for (const m of t.matchAll(/\b1Z[0-9A-Z]{16}\b/gi)) out.set(m[0].toUpperCase(), { number: m[0].toUpperCase(), carrier: 'UPS' });
  for (const w of t.matchAll(TRACK_WORD)) {
    const win = t.slice(w.index ?? 0, (w.index ?? 0) + 160);
    const usps = /usps/i.test(win), dhl = /\bdhl\b/i.test(win);
    // never digits glued to letters or other digits: the tail of a UPS 1Z number is not a FedEx number
    for (const m of win.matchAll(/(?<![0-9A-Za-z\-./])(\d[\d ]{8,30}\d)(?![0-9A-Za-z\-./])/g)) {
      // "1234 5678 9012" is one FedEx number; "879337642791 879337641177" is two
      for (const cand of [m[1].replace(/ /g, ''), ...m[1].split(' ')]) {
        let carrier: Carrier | null = null;
        if (/^9[2-5]\d{18,20}$/.test(cand) || (usps && /^\d{20,22}$/.test(cand))) carrier = 'USPS';
        else if (/^(\d{12}|\d{15}|\d{20}|\d{22})$/.test(cand)) carrier = 'FedEx';
        else if (dhl && /^\d{10}$/.test(cand)) carrier = 'DHL';
        if (carrier && !out.has(cand)) out.set(cand, { number: cand, carrier });
      }
    }
  }
  return [...out.values()];
}

export function trackingUrl(h: { number: string; carrier: string | null }): string {
  const n = encodeURIComponent(h.number);
  switch (h.carrier) {
    case 'UPS': return `https://www.ups.com/track?tracknum=${n}`;
    case 'FedEx': return `https://www.fedex.com/fedextrack/?trknbr=${n}`;
    case 'USPS': return `https://tools.usps.com/go/TrackConfirmAction?tLabels=${n}`;
    case 'DHL': return `https://www.dhl.com/us-en/home/tracking.html?tracking-id=${n}`;
    default: return `https://www.google.com/search?q=${n}`;
  }
}

/** The order a vendor email is about: an earlier saved document of the same email thread, else
 *  an invoice / quote number written in it that is on exactly one order. null when unsure. */
export function orderForEmail(conversationId: string | null, text: string,
                              data: { orders: OtOrder[]; lines: OtLine[]; documents: OtDocument[] }): OtOrder | null {
  const live = (id: string | null | undefined) => data.orders.find(o => o.id === id && !o.archived_at);
  const one = (ids: Array<string | null | undefined>) => {
    const found = [...new Set(ids.filter(Boolean))].map(live).filter((o): o is OtOrder => !!o);
    return found.length === 1 ? found[0] : null;
  };
  if (conversationId) {
    const o = one(data.documents.filter(d => d.source_conversation_id === conversationId).map(d => d.order_id));
    if (o) return o;
  }
  const refs = new Set([...String(text).matchAll(/\b(INV-\d{4}-\d{5,7}|Q-\d{4}-\d{4}-\d{4})\b/gi)].map(m => normText(m[1])));
  if (!refs.size) return null;
  return one([
    ...data.lines.filter(l => refs.has(normText(l.invoice_number)) || refs.has(normText(l.quote_number))).map(l => l.order_id),
    ...data.documents.filter(d => refs.has(normText(d.doc_number))).map(d => d.order_id),
  ]);
}

/* ── warehouse stock ──────────────────────────────────────────────────── */

/** On hand after every move up to and including `asOf` (all moves when omitted).
 *  Moves apply in date order, same-day in creation order; a count resets. */
export function onHand(moves: OtMove[], asOf?: string): number {
  const sorted = moves.filter(m => !asOf || m.moved_on <= asOf)
    .sort((a, b) => (a.moved_on === b.moved_on ? a.created_at.localeCompare(b.created_at) : a.moved_on < b.moved_on ? -1 : 1));
  let q = 0;
  for (const m of sorted) {
    if (m.kind === 'count') q = n(m.qty);
    else if (m.kind === 'receipt') q += n(m.qty);
    else q -= n(m.qty);
  }
  return q;
}

/** Units received into the warehouse against one order line. */
export function receivedForLine(moves: OtMove[], lineId: string): number {
  return moves.filter(m => m.kind === 'receipt' && m.line_id === lineId).reduce((s, m) => s + n(m.qty), 0);
}

export interface StockRow {
  item: OtItem;
  onHand: number;
  /** Everything still to come into the warehouse: the unreceived qty of every
   *  line from ORDERED on (not a mere request, not cancelled, not marked
   *  received) on an OPEN warehouse order — counted until its units are
   *  received into stock, so a line that says shipped or delivered stays in. */
  incoming: number;
  /** The part of `incoming` whose line already says delivered: it is at the
   *  warehouse, waiting for someone to receive it. */
  awaitingReceipt: number;
  /** Average released per month over the last 90 days (or since the first release). */
  monthlyUse: number;
  monthsCover: number | null;
  reorderPoint: number | null;
  /** The day on-hand + incoming falls to the reorder point at the current rate. */
  reorderBy: string | null;
  stockOutBy: string | null;
  lastCount: OtMove | null;
  lastReceipt: OtMove | null;
  state: 'reorder now' | 'reorder soon' | 'ok' | 'no usage yet';
}

const USE_WINDOW_DAYS = 90;
const SAFETY = 1.25;   // reorder point = lead-time demand + 25%
const SOON_DAYS = 30;

export function stockRows(items: OtItem[], moves: OtMove[], lines: OtLine[], orders: OtOrder[], today: string): StockRow[] {
  const linesByOrder = new Map<string, OtLine[]>();
  for (const l of lines) (linesByOrder.get(l.order_id) ?? linesByOrder.set(l.order_id, []).get(l.order_id)!).push(l);
  // open warehouse orders: completed (by hand, or every line paid) and archived ones bring nothing more
  const openWarehouse = new Set(orders.filter(o => o.deliver_to !== 'venue' && orderState(o, linesByOrder.get(o.id) ?? []) === 'open').map(o => o.id));
  return items.filter(i => i.is_active && i.track_stock).map(item => {
    const mv = moves.filter(m => m.item_id === item.id);
    const releases = mv.filter(m => m.kind === 'release');
    const since = addDays(today, -USE_WINDOW_DAYS);
    const firstRelease = releases.reduce<string | null>((f, m) => (f === null || m.moved_on < f ? m.moved_on : f), null);
    // Days the rate is measured over: 90, or less when releases started more recently (min 30 so
    // one early release does not read as a huge monthly rate).
    const spanDays = firstRelease && firstRelease > since ? Math.max(30, daysBetween(firstRelease, today)) : USE_WINDOW_DAYS;
    const released = releases.filter(m => m.moved_on > since).reduce((s, m) => s + n(m.qty), 0);
    const dailyUse = released / spanDays;
    const monthlyUse = dailyUse * 30;

    const itemLines = lines.filter(l => l.item_id === item.id && l.status !== 'CANCELLED' && l.status !== 'REQUESTED' && l.status !== 'RECEIVED'
      && openWarehouse.has(l.order_id));
    const unreceived = (l: OtLine) => Math.max(0, n(l.qty) - receivedForLine(mv, l.id));
    const incoming = itemLines.reduce((s, l) => s + unreceived(l), 0);
    const awaitingReceipt = itemLines.filter(l => statusRank(l.status) >= statusRank('DELIVERED')).reduce((s, l) => s + unreceived(l), 0);

    const qty = onHand(mv);
    const rp = item.reorder_point ?? (dailyUse > 0 && item.lead_time_days != null ? dailyUse * item.lead_time_days * SAFETY : null);
    let reorderBy: string | null = null, stockOutBy: string | null = null;
    let state: StockRow['state'] = 'no usage yet';
    if (dailyUse > 0) {
      stockOutBy = addDays(today, Math.max(0, qty) / dailyUse);
      if (rp != null) {
        const headroom = qty + incoming - rp;
        reorderBy = addDays(today, Math.max(0, headroom) / dailyUse);
        state = headroom <= 0 ? 'reorder now' : daysBetween(today, reorderBy) <= SOON_DAYS ? 'reorder soon' : 'ok';
      } else {
        state = 'ok';
      }
    } else if (item.reorder_point != null && qty + incoming <= item.reorder_point) {
      state = 'reorder now';
    }
    const latest = (k: OtMove['kind']) => mv.filter(m => m.kind === k)
      .sort((a, b) => (a.moved_on === b.moved_on ? b.created_at.localeCompare(a.created_at) : a.moved_on < b.moved_on ? 1 : -1))[0] ?? null;
    return {
      item, onHand: qty, incoming, awaitingReceipt, monthlyUse,
      monthsCover: monthlyUse > 0 ? qty / monthlyUse : null,
      reorderPoint: rp, reorderBy, stockOutBy,
      lastCount: latest('count'), lastReceipt: latest('receipt'), state,
    };
  });
}

/** Released per venue over the last `days` days (an item's draw-down by venue). */
export function releasesByVenue(moves: OtMove[], itemId: string, today: string, days = 90): Array<{ venueId: string | null; qty: number }> {
  const since = addDays(today, -days);
  const m = new Map<string | null, number>();
  for (const x of moves) if (x.item_id === itemId && x.kind === 'release' && x.moved_on > since) m.set(x.venue_id, (m.get(x.venue_id) ?? 0) + n(x.qty));
  return [...m.entries()].map(([venueId, qty]) => ({ venueId, qty })).sort((a, b) => b.qty - a.qty);
}

/* ── E&E storage deliveries → stock draws ─────────────────────────────── */

// E&E bills each trip out of its warehouse as a fee line on a "WAREHOUSING AND DELIVERY" invoice —
// no quote, no product invoice, no tracking: "TNG delivery - 10/12/2026 - 3 CASES TNG-EURO / 2 CASES
// TNG-PIZZAB", "BSC delivery - 10/22/2026 - 2cs taco wrap". Stock coming in is "Receiving and
// Warehousing - TNG napkins - 1pallet"; a venue sending stock back is "Delilah Miami UPS returns CS 1".
const STORAGE_HEAD = /\b(?:delivery|deliveries|returns?|receiving and warehousing)\b/i;

/** What became of a storage line (kount_ot_lines.stock_draw, 0141); null = not done yet. */
export type StockDraw = 'recorded' | 'none';

/** Short names E&E writes for venues. */
const VENUE_SHORT: Record<string, string[]> = {
  'The Nice Guy': ['tng', 'nice guy'],
  'The Birdstreet Club': ['bsc', 'bird streets', 'bird street', 'birdstreets'],
  'Little Luck': ['ll'],
  'Lady Delilah': ['delilah nyc', 'delilah ny'],
};
const venueAliases = (v: { name: string }) => [normText(v.name), ...(VENUE_SHORT[v.name] ?? [])].filter(Boolean);

export const isEeVendor = (vendor: string | null | undefined) => /^e\s*&?\s*e(\s|$)/i.test(String(vendor ?? '').trim());

/** A line that is E&E moving our stock in or out of its warehouse (not a product we bought). */
export function isStorageLine(l: Pick<OtLine, 'description' | 'item_id'>, vendor: string): boolean {
  return !l.item_id && isEeVendor(vendor) && STORAGE_HEAD.test(l.description);
}

// an item's category is its brand ("Delilah", "Bird Streets"); the brand serves the venues named for it
const brandKey = (s: string | null | undefined) => normText(s).replace(/\b(the|club)\b/g, ' ').replace(/\s+/g, '').replace(/s$/, '');
const GENERAL_BRAND = 'hwood';     // h.wood stock any venue can draw
function brandServes(category: string | null, venueName: string): boolean {
  const b = brandKey(category);
  return b.length > 2 && b !== GENERAL_BRAND && brandKey(venueName).includes(b);
}
const stem = (w: string) => (w.length > 4 && /(ches|shes|xes)$/.test(w) ? w.slice(0, -2) : w.length > 3 && w.endsWith('s') && !w.endsWith('ss') ? w.slice(0, -1) : w);
const PART_STOP = new Set('of shipped ship via ups fedex uber pick picked pickup up delivery delivered cs case cases ctn ctns carton cartons pallet pallets pc pcs the and to for by from'.split(' '));
const wordsOf = (s: string, drop: Set<string>) => normText(s).split(' ').filter(w => w.length > 1 && !/^\d+$/.test(w) && !drop.has(w)).map(stem);
const wordHit = (w: string, iw: string) => w === iw || (w.length >= 4 && iw.length >= 4 && (iw.startsWith(w) || w.startsWith(iw)));
const compactSku = (s: string | null | undefined) => String(s ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');

export interface StoragePlan {
  kind: 'release' | 'receipt';
  /** the day written on the line; null = use the invoice date */
  day: string | null;
  venueId: string | null;
  draws: Array<{ itemId: string; name: string; qty: number }>;
  /** why it cannot be recorded by itself — someone picks the item / qty; null = record it */
  problem: string | null;
}

/** Read one storage line into stock moves: the venue (written on it, else the line's / order's),
 *  the day, and per "N CASES <item>" part the item and the cases. An item is matched by its SKU,
 *  else by its words among the venue's brand (then h.wood stock); when two items fit equally, the
 *  one we hold stock of is it. Anything unsure becomes a problem, never a guess. */
export function planStorageLine(l: Pick<OtLine, 'description' | 'venue_id'>, order: Pick<OtOrder, 'venue_id'>,
                                items: OtItem[], moves: OtMove[], venues: Array<{ id: string; name: string }>): StoragePlan {
  const text = l.description;
  const kind: StoragePlan['kind'] = /\b(receiving|returns?)\b/i.test(text) ? 'receipt' : 'release';
  const dm = text.match(/\b(\d{1,2})\/(\d{1,2})\/(\d{4}|\d{2})\b/);
  const day = dm && +dm[1] >= 1 && +dm[1] <= 12 && +dm[2] >= 1 && +dm[2] <= 31
    ? `${dm[3].length === 2 ? '20' + dm[3] : dm[3]}-${dm[1].padStart(2, '0')}-${dm[2].padStart(2, '0')}` : null;
  const plan: StoragePlan = { kind, day, venueId: null, draws: [], problem: null };
  const problems: string[] = [];

  const t = ` ${normText(text)} `;
  const named = venues.filter(v => venueAliases(v).some(a => t.includes(` ${a} `)));
  const fallback = l.venue_id ?? order.venue_id;
  if (named.length > 1) problems.push(`names more than one venue (${named.map(v => v.name).join(', ')})`);
  else plan.venueId = named[0]?.id ?? (fallback && fallback !== MULTIPLE_VENUES ? fallback : null);
  const venue = venues.find(v => v.id === plan.venueId) ?? null;
  if (kind === 'release' && !plan.venueId && !named.length) problems.push('which venue it went to');

  const drop = new Set([...PART_STOP, ...venues.flatMap(v => venueAliases(v).flatMap(a => a.split(' ')))]);
  const stock = items.filter(i => i.is_active && i.track_stock);
  const held = (i: OtItem) => moves.some(m => m.item_id === i.id && (m.kind === 'receipt' || (m.kind === 'count' && n(m.qty) > 0)));
  const body = dm ? text.replace(dm[0], ' ') : text;
  const head = body.search(STORAGE_HEAD);
  const rest = head < 0 ? body : body.slice(head).replace(STORAGE_HEAD, ' ');
  for (const raw of rest.split(/[\/;,+]| & /)) {
    const part = raw.replace(/\s+-\s+|\s+-$|^-\s+/g, ' ').trim();
    const qm = part.match(/(\d+(?:\.\d+)?)\s*(?:cases?|cs|ctns?|cartons?)\b/i) ?? part.match(/\b(?:cases?|cs)\s*(\d+(?:\.\d+)?)\b/i);
    const pallet = /\d+\s*pallets?\b/i.test(part);
    const ws = wordsOf(qm ? part.replace(qm[0], ' ') : part, drop);
    if (!qm && !ws.length && !pallet) continue;              // "UBER PICK UP", "via UPS"
    // the item: its SKU written on the line, else the best word match
    const skus = new Set([...part.matchAll(/[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+|\b[A-Za-z]{2,}\d[A-Za-z0-9]*\b/g)].map(m => compactSku(m[0])));
    let found: OtItem | null = stock.find(i => i.sku && skus.has(compactSku(i.sku))) ?? null;
    let why = '';
    if (!found && ws.length) {
      const score = (i: OtItem) => { const iw = wordsOf(`${i.name} ${i.sku ?? ''}`, drop); return ws.filter(w => iw.some(x => wordHit(w, x))).length / ws.length; };
      // the venue's own brand first, then stock any venue can draw (h.wood, no brand)
      const general = (i: OtItem) => !brandKey(i.category) || brandKey(i.category) === GENERAL_BRAND;
      for (const pool of venue ? [stock.filter(i => brandServes(i.category, venue.name)), stock.filter(general)] : [stock]) {
        const scored = pool.map(i => ({ i, s: score(i) })).filter(x => x.s >= 0.5);
        if (!scored.length) continue;
        const best = Math.max(...scored.map(x => x.s));
        let tops = scored.filter(x => x.s === best).map(x => x.i);
        if (tops.length > 1 && tops.some(held)) tops = tops.filter(held);
        if (tops.length === 1) found = tops[0];
        else why = `could be ${tops.slice(0, 3).map(i => i.name).join(' or ')}`;
        break;
      }
      if (!found && !why) why = `no stock item matches "${part}"`;
    }
    if (!found) { problems.push(why || `which item the ${qm ? `${qm[1]} cases are` : 'line is'}`); continue; }
    if (!qm) { problems.push(pallet ? `how many cases of ${found.name} the pallet held` : `how many cases of ${found.name}`); continue; }
    plan.draws.push({ itemId: found.id, name: found.name, qty: Number(qm[1]) });
  }
  if (!plan.draws.length && !problems.length) problems.push('no item or quantity on it');
  plan.problem = problems.length ? `Can't tell ${problems.join('; ')}.` : null;
  return plan;
}

/** The stock moves a storage plan records — dated the delivery day, at noon, so a count of that
 *  day keeps the last word (E&E bills the trip days after it happened). */
export function storageMoveRows(plan: StoragePlan, l: Pick<OtLine, 'id' | 'description'>, fallbackDay: string) {
  const day = plan.day ?? fallbackDay;
  return plan.draws.map(d => ({
    item_id: d.itemId, moved_on: day, kind: plan.kind, qty: d.qty,
    venue_id: plan.kind === 'release' ? plan.venueId : null, line_id: l.id,
    note: `E&E: ${l.description}`.slice(0, 500), created_at: `${day}T19:00:00Z`,
  }));
}

/* ── validation ───────────────────────────────────────────────────────── */

export interface DraftLine { key: number; itemId: string | null; description: string; sku: string; qty: string; unit: string; unitPrice: string }

export function validateNewOrder(vendor: string, lines: DraftLine[]): string | null {
  if (!vendor.trim()) return 'Enter the vendor.';
  const used = lines.filter(l => l.description.trim() || l.qty.trim() || l.itemId);
  if (!used.length) return 'Add at least one line.';
  for (const l of used) {
    if (!l.description.trim()) return 'Every line needs an item or a description.';
    const q = Number(l.qty);
    if (!Number.isFinite(q) || q <= 0) return `Enter a quantity above 0 for ${l.description.trim()}.`;
    if (l.unitPrice.trim() && (!Number.isFinite(Number(l.unitPrice)) || Number(l.unitPrice) < 0)) return `The price for ${l.description.trim()} is not a number.`;
  }
  return null;
}
