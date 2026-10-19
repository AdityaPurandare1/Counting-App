/* v2.18 — newly carried items reach a phone that is ALREADY open.

   Little Luck 2026-10-18: 143 wine/sake masters were added mid-count and only
   1 of them was ever counted. Counters already in the app never saw them.

   Cause: the 60s ticker refreshes carriedSet but deliberately skips itemMaster
   once loaded, and reconcileCarriedAgainstMaster only forced a reload when
   carried->catalog resolution fell UNDER 80%. 143 new items against ~5.6k
   carried is 97.5% resolution, so the reload never fired -- the gate detects a
   wholesale stale catalog, not new items, and could not trip on fewer than
   ~1,100 new items at once.

   This spec reproduces that at small scale: the mock carries 10 items, so ONE
   new carried item gives 10/11 = 90.9% resolution -- above the old 80% gate.
   FAIL-BEFORE: the new item never became searchable. */
const { test, expect } = require('../fixtures');

const NEW_ID = '99999999-9999-4999-8999-999999999991';
const FOOD_ID = '99999999-9999-4999-8999-999999999992';

const found = (page, q) =>
  page.evaluate((query) => window.searchItemMaster(query, 20).map((i) => i.name), q);

test.describe('v2.18 newly carried items reach an open phone', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.searchItemMaster)).toBe('function');
    await expect.poll(() => page.evaluate(() => window.searchItemMaster('belvedere', 5).length))
      .toBeGreaterThan(0);
  });

  test('an item carried AFTER the phone loaded becomes searchable without a reload', async ({ page, db }) => {
    // Not there yet.
    expect(await found(page, 'telmont')).toEqual([]);

    // Admin adds a wine mid-count (what 0082 did, 143 times over).
    db.t.master_items.push({
      id: NEW_ID, organization_id: 'org-1', name: 'Champagne, Telmont',
      category: 'Wine Cost', subcategory: null, base_size: null, base_unit: null,
      is_active: true, created_at: '2026-10-18T18:00:00Z', product_id: null,
    });
    db.t.kount_carried_items.push({ master_item_id: NEW_ID });

    // What the 60-second ticker runs. No app reload, no re-join.
    await page.evaluate(() => window.loadCarriedItemsFromSupabase());

    // THE REGRESSION: pre-v2.18 this stayed [] forever.
    await expect.poll(() => found(page, 'telmont'), { timeout: 8000 })
      .toEqual(['Champagne, Telmont']);
  });

  test('existing catalog items are untouched by the top-up', async ({ page, db }) => {
    const before = await found(page, 'belvedere');
    db.t.master_items.push({
      id: NEW_ID, organization_id: 'org-1', name: 'Champagne, Telmont',
      category: 'Wine Cost', subcategory: null, base_size: null, base_unit: null,
      is_active: true, created_at: '2026-10-18T18:00:00Z', product_id: null,
    });
    db.t.kount_carried_items.push({ master_item_id: NEW_ID });
    await page.evaluate(() => window.loadCarriedItemsFromSupabase());
    await expect.poll(() => found(page, 'telmont'), { timeout: 8000 }).toHaveLength(1);
    expect(await found(page, 'belvedere')).toEqual(before);
    // And no duplicate rows appear on a second pass.
    await page.evaluate(() => window.loadCarriedItemsFromSupabase());
    await page.waitForTimeout(500);
    expect(await found(page, 'telmont')).toHaveLength(1);
  });

  test('a carried item outside the phone scope is fetched once, not every minute', async ({ page, db }) => {
    // Food is carried globally but excluded from the phone by IN_SCOPE_FILTER,
    // so the scoped fetch never returns it. Without a memory of that it would
    // be re-requested on every 60s tick forever (4 such rows exist in prod).
    db.t.master_items.push({
      id: FOOD_ID, organization_id: 'org-1', name: 'Sushi Rice, Koshihikari',
      category: 'Grocery and Dry Goods Cost', subcategory: null, base_size: 40, base_unit: 'lb',
      is_active: true, created_at: '2026-10-18T18:00:00Z', product_id: null,
    });
    db.t.kount_carried_items.push({ master_item_id: FOOD_ID });

    // Count the real top-up requests that name this id. (_missingNotInScope is
    // a module-scoped let, so the test asserts behaviour, not the internal.)
    let hits = 0;
    page.on('request', (r) => {
      const u = r.url();
      if (u.includes('/master_items') && u.includes(FOOD_ID)) hits++;
    });

    await page.evaluate(() => window.loadCarriedItemsFromSupabase());
    await expect.poll(() => hits, { timeout: 8000 }).toBe(1);

    // Let that fetch fully settle before the next tick, so an in-flight guard
    // cannot be what suppresses the re-request -- only the memory can.
    await page.waitForTimeout(600);
    await page.evaluate(() => window.loadCarriedItemsFromSupabase());
    await page.waitForTimeout(600);
    await page.evaluate(() => window.loadCarriedItemsFromSupabase());
    await page.waitForTimeout(600);

    // FAIL-BEFORE (no memory): 3 requests, one per tick, forever.
    expect(hits).toBe(1);

    // It must never surface in the phone's search.
    expect(await found(page, 'koshihikari')).toEqual([]);
  });
});
