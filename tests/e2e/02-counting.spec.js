const { test, expect, startAuditAs, addManual, counted, qtyOf, tapPlus, tapMinus, M } = require('../fixtures');

test.describe('counting: add / merge / adjust', () => {
  test.beforeEach(async ({ page }) => { await startAuditAs(page, 'manager'); });

  test('manual add of a catalog item links to its master and syncs cleanly', async ({ page, db }) => {
    await addManual(page, 'Belvedere 1L', 3);
    expect(await qtyOf(page, 'Belvedere 1L')).toBe(3);
    const items = await counted(page);
    expect(items.find(i => i.name === 'Belvedere 1L').masterId).toBe(M.belv);
    // The FK-fix invariant: item_id is null, the real id lives in master_item_id.
    await expect.poll(() => db.t.kount_entries.length).toBeGreaterThan(0);
    const row = db.t.kount_entries.find(r => r.item_name === 'Belvedere 1L');
    expect(row.item_id).toBeNull();
    expect(row.master_item_id).toBe(M.belv);
    expect(row.qty).toBe(3);
  });

  test('counting the same item again merges (sums) — does not duplicate', async ({ page, db }) => {
    await addManual(page, 'Campari 1L', 2);
    await addManual(page, 'Campari 1L', 5);
    const campari = (await counted(page)).filter(i => i.name === 'Campari 1L');
    expect(campari.length).toBe(1);
    expect(campari[0].qty).toBe(7);
    await expect.poll(() => db.t.kount_entries.filter(r => r.item_name === 'Campari 1L').length).toBe(1);
    await expect.poll(() => db.t.kount_entries.find(r => r.item_name === 'Campari 1L').qty).toBe(7);
  });

  test('+ and - adjust the quantity on the unified card', async ({ page, db }) => {
    await addManual(page, "Tito's Handmade Vodka 750ml", 2);
    await tapPlus(page, "Tito's");
    await expect.poll(() => qtyOf(page, "Tito's Handmade Vodka 750ml")).toBe(3);
    await tapMinus(page, "Tito's");
    await expect.poll(() => qtyOf(page, "Tito's Handmade Vodka 750ml")).toBe(2);
    // the absolute qty mirrored to the server row
    await expect.poll(() => db.t.kount_entries.find(r => /Tito/.test(r.item_name)).qty).toBe(2);
  });

  test('a never-in-catalog typed item is still counted (as a custom item)', async ({ page }) => {
    await addManual(page, 'Some Obscure Amaro 500ml', 1);
    expect(await qtyOf(page, 'Some Obscure Amaro 500ml')).toBe(1);
  });
});
