const { test, expect, startAuditAs } = require('../fixtures');

/* v2.26: a venue in FULL_CATALOG_LIST_VENUES (Poppy 'v5' and, from v2.27, Little Luck 'v11')
   lists the whole catalog on the List tab, every row, instead of the first
   REFERENCE_RENDER_CAP carried items. Other venues keep the carried list.
   The mock venue is 'v-delilah', so the specs add it to the set. */
test.describe('Full-catalog List tab (v2.26)', () => {
  test('a full-list venue shows every catalog item, not only carried ones, with no cap', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => { FULL_CATALOG_LIST_VENUES.add(appState.audit.venueId); });
    await page.getByRole('button', { name: 'List', exact: true }).click();

    await expect(page.locator('#guidedContent .list-header h3')).toHaveText('All items');
    const expected = await page.evaluate(() => getFullCatalogItems().length);
    await expect(page.locator('#guidedContent .full-list .c-item')).toHaveCount(expected);
    await expect(page.locator('#guidedContent .list-header .total')).toHaveText(String(expected));
    // Don Julio 1942 is in the catalog but NOT carried: it only shows in the full list.
    await expect(page.locator('#guidedContent .c-item', { hasText: 'Don Julio 1942' })).toHaveCount(1);
    await expect(page.locator('#guidedContent .list-cap-note')).toHaveCount(0);

    // Rows still start a count.
    await page.locator('#guidedContent .c-item', { hasText: 'Don Julio 1942' }).first().locator('.c-name').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
  });

  test('a full-list venue renders past the 150-row cap', async ({ page, db }) => {
    for (let i = 0; i < 190; i++) {
      db.t.master_items.push({
        id: 'full0000-0000-4000-8000-' + String(i).padStart(12, '0'), organization_id: 'org-1',
        name: 'Fullcat Bottle ' + String(i).padStart(4, '0') + ' 750ml', category: 'Liquor Cost', subcategory: null,
        base_size: 750, base_unit: 'ml', is_active: true, created_at: '2026-01-01T00:00:00Z', product_id: null,
      });
    }
    await startAuditAs(page, 'manager');
    await page.evaluate(() => { FULL_CATALOG_LIST_VENUES.add(appState.audit.venueId); });
    await page.getByRole('button', { name: 'List', exact: true }).click();
    const n = await page.locator('#guidedContent .full-list .c-item').count();
    expect(n).toBe(await page.evaluate(() => getFullCatalogItems().length));
    expect(n).toBeGreaterThan(150);
    await expect(page.locator('#guidedContent .list-cap-note')).toHaveCount(0);
  });

  test('other venues keep the carried list', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.getByRole('button', { name: 'List', exact: true }).click();
    await expect(page.locator('#guidedContent .list-header h3')).toHaveText('Carried items');
    await expect(page.locator('#guidedContent .full-list')).toHaveCount(0);
    await expect(page.locator('#guidedContent .c-item', { hasText: 'Don Julio 1942' })).toHaveCount(0);
    expect(await page.evaluate(() => [...FULL_CATALOG_LIST_VENUES].sort())).toEqual(['v11', 'v5']);
  });
});
