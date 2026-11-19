// The release engine's reader (0179): its answer kept as the engine uses it.  deno test kount-order-mail/release.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { RELEASE_SCHEMA, releaseContext, toReleaseRead } from './release.ts';

Deno.test('0179 the reader\'s answer: empty strings and 0 become null, lines with nothing named are dropped', () => {
  assertEquals(toReleaseRead({ is_release: true, venue: 'Delilah LA', lines: [
    { sku: 'DEL-MEDBAG', item: 'medium tote bags', qty: 5, unit: 'cases' },
    { sku: '', item: 'taco wrap', qty: 0, unit: '' },
    { sku: '', item: '  ', qty: 3, unit: 'cases' },
  ] }), { is_release: true, venue: 'Delilah LA', lines: [
    { sku: 'DEL-MEDBAG', item: 'medium tote bags', qty: 5, unit: 'cases' },
    { sku: null, item: 'taco wrap', qty: null, unit: null },
  ] });
  assertEquals(toReleaseRead({ is_release: false, venue: '', lines: [] }), { is_release: false, venue: null, lines: [] });
  assertEquals(toReleaseRead(null), { is_release: false, venue: null, lines: [] }, 'no answer = not a release');
  assertEquals(toReleaseRead({ is_release: 'yes' }).is_release, false, 'only true is true');
});

Deno.test('0179 what the reader picks from: the stock list and the venues', () => {
  const t = releaseContext([{ sku: 'BS-EUROTTE', name: 'BS Eurotote Bag', category: 'Bird Streets' }, { sku: null, name: 'Poppy Meal Boxes', category: 'Poppy' }],
    [{ name: 'The Birdstreet Club' }, { name: 'Delilah Dallas' }]);
  assert(t.includes('BS-EUROTTE | BS Eurotote Bag | Bird Streets') && t.includes('(no SKU) | Poppy Meal Boxes | Poppy'));
  assert(t.endsWith('Venues: The Birdstreet Club, Delilah Dallas'));
});

Deno.test('0179 the schema: every field required, no nulls (the structured-output rule)', () => {
  assertEquals([...RELEASE_SCHEMA.required], ['is_release', 'venue', 'lines']);
  assertEquals([...RELEASE_SCHEMA.properties.lines.items.required], ['sku', 'item', 'qty', 'unit']);
  assert(!JSON.stringify(RELEASE_SCHEMA).includes('null'));
});
