// deno test supabase/functions/kount-price-check/rules.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bibleItems, itemNoKey, ourUnitPrice, overBudget, purchasesFor, readResearch, researchPrompt, verdict, type BibleRow, type PurchaseLine } from './rules.ts';

const HEAD = ['Image', 'Item', 'Manufacturer', 'Description/Color/Pattern', 'Manufacturer Item #', 'Size', 'Link', 'Delilah Dallas Opening Order', 'NOTES'];
const bible = (id: string, venue: string, title: string, sheets: Array<{ name: string; header: string[]; rows: string[][] }>): BibleRow =>
  ({ id, venue_id: venue, title, text_index: { sheets } });

Deno.test('manufacturer item numbers, normalized', () => {
  assertEquals(itemNoKey('SKU: 6HGMZ1119'), '6HGMZ1119');
  assertEquals(itemNoKey('#853817'), '853817');
  assertEquals(itemNoKey('0042.115672'), '0042115672');
  assertEquals(itemNoKey('B0C8S8SY5R'), 'B0C8S8SY5R');
  assertEquals(itemNoKey('SKU BOT-AT-100TAN'), 'BOTAT100TAN');
  assertEquals(itemNoKey(''), '');
  assertEquals(itemNoKey('Ordered'), '', 'no digit: not an item number');
  assertEquals(itemNoKey('12'), '', 'too short');
});

Deno.test('bible items: one per item #, across venues; header repeats, collateral and empty rows left out', () => {
  const la = bible('b1', 'v1', 'Delilah LA Bible 2026', [
    { name: 'Smallware', header: HEAD, rows: [
      ['', 'Oyster Fork', "Steelite INT'L USA", 'Monza, 18/10 Stainless Steel', 'SPLM40Z025', '5.75"', 'https://us.steelite.com/5340z025-monza-o', '500', ''],
      ['', '', '', '', '', '', '', '', ''],
      ['Photo', 'Glass', 'Manufactuer', 'Description', 'SKU', 'Size', 'Active count', 'Backstock', ''],
      ['', 'pasta bowl', "Steelite INT'L USA", 'PASTA BOWL 11 (21 OZ)', '', '11 in', '', '', ''],
    ] },
    { name: 'Collateral', header: ['', ''], rows: [['Pantones', 'Quantity']] },
  ]);
  const mia = bible('b2', 'v2', 'Delilah Miami OS&E Bible', [
    { name: 'Smallware', header: ['Image', 'Item', 'Manufacturer', 'Description/Color/Pattern', 'Manufacturer Item #', 'Size', 'Link', 'NOTES'], rows: [
      ['', 'Oyster Fork', "Steelite INT'L USA", 'Monza, 18/10 Stainless Steel', 'SPLM40Z025', '5.75"', 'https://us.steelite.com/5340z025-monza-o', ''],
    ] },
  ]);
  const keys = bibleItems([la, mia]);
  assertEquals(keys.length, 2);
  const fork = keys.find(i => i.item_key === 'SPLM40Z025')!;
  assertEquals(fork.sources.map(s => s.title), ['Delilah LA Bible 2026', 'Delilah Miami OS&E Bible']);
  assertEquals([fork.manufacturer, fork.item_name, fork.size, fork.checkable], ["Steelite INT'L USA", 'Oyster Fork', '5.75"', true]);
  assertEquals(fork.bible_link, 'https://us.steelite.com/5340z025-monza-o');
  assertEquals(fork.specs, {}, 'order quantities and notes are not specs');
  const bowl = keys.find(i => i.item_name === 'pasta bowl')!;
  assert(bowl.item_key.startsWith('noid:') && !bowl.checkable, 'no item #: listed, not checkable');
});

Deno.test('bible items: specs keep color / vendor columns; prices and links as printed', () => {
  const keys = bible('b3', 'v6', 'Keys Bible', [{ name: 'Barware',
    header: ['Image', 'Item', 'Manufacturer', 'Description/Color/Pattern', 'Manufacturer Item #', 'Size', 'Vendor', 'Vendor Item #', 'Price', 'Usage', 'Quantity', 'Link'],
    rows: [['', 'Carafe', 'American Metalcraft', 'American Metalcraft WB33 34 oz. Plastic', 'WB33', '34oz', 'Webstaurant', '124WB33', '$10.99', 'Bottle Service', '150', 'https://www.webstaurantstore.com/x']] }]);
  const [c] = bibleItems([keys]);
  assertEquals(c.item_key, 'WB33');
  assertEquals(c.specs, { Vendor: 'Webstaurant', 'Vendor Item #': '124WB33' });
  assertEquals([c.bible_price, c.bible_link], ['$10.99', 'https://www.webstaurantstore.com/x']);
});

const pl = (o: Partial<PurchaseLine>): PurchaseLine => ({ sku: null, description: '', unit_price: 68.84, unit: 'cs', qty: 6, status: 'INVOICED', vendor: 'EE Mercantile',
  ordered_on: '2026-10-20', order_number: 'OSE-0102', invoice_number: 'INV-2026-100001', ...o });

Deno.test('what we paid: lines carrying the item # as a whole token, newest first', () => {
  const lines = [
    pl({ sku: '9156', description: 'Libbey Contour Goblet 16 oz', ordered_on: '2026-09-01', unit_price: 60 }),
    pl({ description: 'Libbey 9156 Contour Goblet (case of 12)', ordered_on: '2026-10-20' }),
    pl({ description: 'Libbey 91567 something else' }),
    pl({ description: 'Libbey 9156', status: 'CANCELLED' }),
    pl({ description: 'Libbey 9156', unit_price: null }),
  ];
  const p = purchasesFor({ item_no: '9156', checkable: true }, lines);
  assertEquals(p.map(x => [x.date, x.unit_price]), [['2026-10-20', 68.84], ['2026-09-01', 60]]);
  assertEquals(purchasesFor({ item_no: null, checkable: false }, lines), []);
});

Deno.test('the question carries the spec, the bible link and what we paid', () => {
  const [item] = bibleItems([bible('b1', 'v1', 'LA', [{ name: 'S', header: HEAD, rows: [['', 'Oyster Fork', 'Steelite', 'Monza, 18/10', 'SPLM40Z025', '5.75"', 'https://us.steelite.com/x', '', '']] }])]);
  const q = researchPrompt(item, purchasesFor(item, [pl({ description: 'Steelite Monza oyster fork SPLM40Z025 (dozen)', unit_price: 98.4, unit: 'dz' })]));
  for (const t of ['Manufacturer item #: SPLM40Z025', 'Size: 5.75"', 'Link in the bible: https://us.steelite.com/x', '$98.40 per dz', 'quote_required']) assert(q.includes(t), t);
});

const answer = (o: unknown) => 'I searched three sites.' + String.fromCharCode(10) + '```json' + String.fromCharCode(10) + JSON.stringify(o) + String.fromCharCode(10) + '```';

Deno.test("the model's answer read back: price per piece worked out here; offers without a link or a price dropped", () => {
  const r = readResearch(answer({
    exact_offers: [
      { seller: 'WebstaurantStore', url: 'https://www.webstaurantstore.com/a', price: 59.99, price_for: 'case of 12', pack_qty: 12, in_stock: true, evidence: '5340Z025 Monza oyster fork 5 3/4"' },
      { seller: 'NoLink', url: '', price: 10, pack_qty: 1 },
      { seller: 'NoPrice', url: 'https://x.com/b', price: 0, pack_qty: 1 },
    ],
    quote_required: [{ seller: 'Steelite', url: 'https://us.steelite.com/x', note: 'Request a quote' }],
    rejected: [{ seller: 'Amazon', url: 'https://amazon.com/c', why: 'Monza table fork, not oyster fork' }],
    our_unit_price: 8.2, our_unit_note: '$98.40 per dozen / 12', notes: '',
  }))!;
  assertEquals(r.exact_offers.length, 1);
  assertEquals([r.exact_offers[0].unit_price, r.exact_offers[0].pack_qty], [4.9992, 12]);
  assertEquals(r.quote_required[0].note, 'Request a quote');
  assertEquals(r.our_unit_price, 8.2);
  assertEquals(readResearch('No sellers found, sorry.'), null);
  assertEquals(readResearch('{"exact_offers": [], "quote_required": []}')!.exact_offers, [], 'a bare object, no fence');
});

Deno.test('verdict: overpaying from 10% cheaper per piece; ok; market only; quote required; not found; no item #', () => {
  const offer = (price: number, pack = 1) => ({ seller: 's', url: 'https://s.com/' + price, price, pack_qty: pack, price_for: '', in_stock: null, evidence: '' });
  const r = (offers: unknown[], ours: number | null, quotes: unknown[] = []) => readResearch(answer({ exact_offers: offers, quote_required: quotes, rejected: [], our_unit_price: ours, our_unit_note: '', notes: '' }));
  const v1 = verdict({ checkable: true }, r([offer(59.99, 12), offer(70, 12)], 8.2), []);
  assertEquals([v1.status, v1.best?.unit_price, v1.savings_pct], ['overpaying', 4.9992, 39]);
  assertEquals(verdict({ checkable: true }, r([offer(7.5)], 8.2), []).status, 'ok', '8.5% cheaper is within 10%');
  assertEquals(verdict({ checkable: true }, r([offer(9)], 8.2), []).status, 'ok', 'we pay less');
  assertEquals(verdict({ checkable: true }, r([offer(9)], null), []).status, 'market_only');
  assertEquals(verdict({ checkable: true }, r([], 8.2, [{ seller: 'Steelite', url: 'https://us.steelite.com/x', note: 'quote' }]), []).status, 'quote_required');
  assertEquals(verdict({ checkable: true }, r([], 8.2), []).status, 'not_found');
  assertEquals(verdict({ checkable: false }, null, []).status, 'no_item_no');
  assertEquals(verdict({ checkable: true }, null, []).status, 'error');
  assertEquals(verdict({ checkable: true }, r([offer(7)], 8.2), [], 20).status, 'ok', 'the threshold is a setting');
});

Deno.test('our price per piece: the model, else a line bought by the piece', () => {
  const p = purchasesFor({ item_no: 'WB33', checkable: true }, [pl({ sku: 'WB33', unit: 'ea', unit_price: 11.5 })]);
  assertEquals(ourUnitPrice({ our_unit_price: null }, p), 11.5);
  assertEquals(ourUnitPrice({ our_unit_price: 10 }, p), 10);
  assertEquals(ourUnitPrice(null, purchasesFor({ item_no: 'WB33', checkable: true }, [pl({ sku: 'WB33', unit: 'cs' })])), null, 'a case: unknown pieces');
});

Deno.test('the weekly budget', () => {
  assert(overBudget(250.01, 250) && overBudget(250, 250));
  assert(!overBudget(249.99, 250) && !overBudget(1000, 0) && !overBudget(1000, null));
});
