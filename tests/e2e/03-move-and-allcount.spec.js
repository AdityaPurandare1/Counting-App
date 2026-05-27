const { test, expect, startAuditAs, addManual, switchZone, counted, card } = require('../fixtures');

test.describe('move between zones + All Count', () => {
  test.beforeEach(async ({ page }) => { await startAuditAs(page, 'manager'); });

  test('move an item to another zone without delete + re-add', async ({ page, db }) => {
    await addManual(page, 'Campari 1L', 4); // counted in Liquor Room (default zone)
    await expect.poll(() => db.t.kount_entries.length).toBe(1);

    // Open the move menu on the card and pick "Bar".
    await card(page, 'Campari 1L').getByRole('button', { name: /Move to another zone/i }).click();
    await page.locator('#moveZoneModal').waitFor({ state: 'visible' });
    await page.locator('#moveZoneModal').getByRole('button', { name: 'Bar', exact: true }).click();

    // Local state: now in Bar, gone from Liquor Room.
    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Campari 1L');
      return it ? it.zone : null;
    }).toBe('Bar');
    // Server row's zone column was updated in place (still one row).
    await expect.poll(() => db.t.kount_entries.length).toBe(1);
    await expect.poll(() => db.t.kount_entries[0].zone).toBe('Bar');
  });

  test('All Count shows cross-zone totals and supports per-zone edits', async ({ page, db }) => {
    // Count the same item in two zones.
    await addManual(page, 'Belvedere 1L', 3);            // Liquor Room
    await switchZone(page, 'Bar');
    await addManual(page, 'Belvedere 1L', 2);            // Bar
    await expect.poll(() => db.t.kount_entries.filter(r => r.item_name === 'Belvedere 1L').length).toBe(2);

    // Switch to the All Count tab.
    await page.getByRole('button', { name: 'All Count', exact: true }).click();

    // The aggregated total across zones (3 + 2 = 5) is shown via the app's own aggregator.
    const agg = await page.evaluate(() => window.getAllCountAggregated().find(g => g.name === 'Belvedere 1L'));
    expect(agg.total).toBe(5);
    expect(agg.rows.length).toBe(2);

    // Expand the row → per-zone breakdown is editable; bump one zone by +1.
    await page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' }).click();
    const beforeTotal = await page.evaluate(() => window.getAllCountAggregated().find(g => g.name === 'Belvedere 1L').total);
    await page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .getByRole('button', { name: '+', exact: true }).first().click();
    await expect.poll(() => page.evaluate(() => window.getAllCountAggregated().find(g => g.name === 'Belvedere 1L').total)).toBe(beforeTotal + 1);
  });
});
