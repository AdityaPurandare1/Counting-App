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

  test('All Count: tap-to-edit qty supports +N add syntax (Anna @ Poppy, 2026-06)', async ({ page, db }) => {
    // "In Craftable we can +6 to an existing total without having to add
    // each bottle individually". Tapping the qty value opens an inline
    // input; typing "+6" ADDS 6 to the current count, not sets to 6.
    await addManual(page, 'Belvedere 1L', 3);             // Liquor Room
    await page.getByRole('button', { name: 'All Count', exact: true }).click();
    await page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' }).click();

    // Tap the qty value cell → it turns into an input pre-filled with the current.
    const qtyCell = page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .locator('.qty-editable').first();
    await qtyCell.click();
    const input = page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .locator('input.qty-editable').first();
    await input.waitFor({ state: 'visible' });
    await expect(input).toHaveValue('3');

    // Replace contents with "+6" and press Enter.
    await input.fill('+6');
    await input.press('Enter');

    // Qty for the Liquor Room entry is now 9 (3 + 6).
    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Belvedere 1L' && i.zone === 'Liquor Room');
      return it ? it.qty : null;
    }).toBe(9);
    // The DB row was updated in place (single row, qty=9).
    await expect.poll(() => {
      const row = db.t.kount_entries.find(r => r.item_name === 'Belvedere 1L');
      return row ? row.qty : null;
    }).toBe(9);
  });

  test('All Count: tap-to-edit qty supports absolute set + ignores garbage input', async ({ page, db }) => {
    await addManual(page, 'Belvedere 1L', 3);
    await page.getByRole('button', { name: 'All Count', exact: true }).click();
    await page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' }).click();

    // Absolute SET: typing "10" replaces the qty.
    let qtyCell = page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .locator('.qty-editable').first();
    await qtyCell.click();
    let input = page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .locator('input.qty-editable').first();
    await input.fill('10');
    await input.press('Enter');
    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Belvedere 1L');
      return it ? it.qty : null;
    }).toBe(10);

    // Garbage input ("not a number") cancels — qty stays at 10.
    qtyCell = page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .locator('.qty-editable').first();
    await qtyCell.click();
    input = page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .locator('input.qty-editable').first();
    await input.fill('not a number');
    await input.press('Enter');
    // Still 10.
    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Belvedere 1L');
      return it ? it.qty : null;
    }).toBe(10);
  });

  test('All Count: move a per-zone entry to another zone (counter feedback @ Poppy, 2026-06)', async ({ page, db }) => {
    // Counter put an item in the wrong zone — previously they had to delete
    // and re-add. Now there's a ⇄ button on each zone row in All Count.
    await addManual(page, "Tito's Handmade Vodka 750ml", 6);    // Liquor Room
    await switchZone(page, 'Bar');
    await addManual(page, "Tito's Handmade Vodka 750ml", 2);    // Bar
    await expect.poll(() => db.t.kount_entries.length).toBe(2);

    // Switch to the All Count tab and expand the item's row.
    await page.getByRole('button', { name: 'All Count', exact: true }).click();
    await page.locator('#guidedContent .c-item', { hasText: "Tito's Handmade Vodka 750ml" }).click();

    // The "Liquor Room" entry (6) was actually counted in the Service Well —
    // move it. There are TWO per-zone rows visible; the ⇄ button targets the
    // Liquor Room one (first match in the breakdown's alphabetical order is
    // "Bar", so Liquor Room is the second move button).
    await page.locator('#guidedContent .c-item', { hasText: "Tito's Handmade Vodka 750ml" })
      .getByRole('button', { name: /Move to another zone/i }).nth(1).click();
    await page.locator('#moveZoneModal').waitFor({ state: 'visible' });
    // The "From" header should reflect the moved entry's actual zone, not
    // appState.currentZone (which is currently 'Bar' from the earlier
    // switchZone). This was the bug: showMoveMenu used to hard-code From.
    await expect(page.locator('#moveZoneModal')).toContainText('From Liquor Room');
    await page.locator('#moveZoneModal').getByRole('button', { name: 'Service Well', exact: true }).click();

    // The Liquor Room row is gone; Service Well now holds the 6.
    await expect.poll(() => db.t.kount_entries.find(r => r.item_name === "Tito's Handmade Vodka 750ml" && r.zone === 'Liquor Room')).toBeUndefined();
    await expect.poll(() => {
      const sw = db.t.kount_entries.find(r => r.item_name === "Tito's Handmade Vodka 750ml" && r.zone === 'Service Well');
      return sw ? sw.qty : null;
    }).toBe(6);
    // Total across zones still 8 (6 Service Well + 2 Bar).
    await expect.poll(() => page.evaluate(() => window.getAllCountAggregated().find(g => g.name === "Tito's Handmade Vodka 750ml").total)).toBe(8);
  });
});
