const { test, expect, startAuditAs, addManual, M } = require('../fixtures');

/* M1 coverage: kount_recounts.master_item_id.
 *
 * closeCount1() generates the recount list and syncRecountsToSupabase() writes
 * it to kount_recounts. M1 made those rows carry a master_item_id:
 *   - rows derived from counted catalog items carry the item's master id, and
 *   - rows derived from an AVT/name report carry null.
 * The rest of the suite only proves the analogous kount_entries.master_item_id
 * path; these tests assert the kount_recounts path that M1 actually changed.
 */
test.describe('M1: kount_recounts.master_item_id', () => {
  test('counted-catalog-derived recount row carries the item master id', async ({ page, db }) => {
    await startAuditAs(page, 'manager');

    // Belvedere 1L is a carried catalog item whose manual add auto-links to its
    // master (M.belv) — same path 02-counting asserts for kount_entries.
    await addManual(page, 'Belvedere 1L', 3);
    expect((await page.evaluate(() => window.getAllCountedItems()))
      .find(i => i.name === 'Belvedere 1L').masterId).toBe(M.belv);

    // v1.70: closeCount1 normally COMPUTES variance and builds the recount list
    // from the (name-derived, masterId=null) AVT rows. The all-counted-items
    // fallback — which preserves masterId — fires when compute can't run. Force
    // that path by going offline before the close (the warning toast confirms
    // the fallback). syncRecountsToSupabase still reaches the in-process mock.
    await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false }); });

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // Recount rows are synced fire-and-forget after closeCount1 confirms.
    await expect.poll(() => db.t.kount_recounts.length).toBeGreaterThan(0);

    const row = db.t.kount_recounts.find(r => r.item_name === 'Belvedere 1L');
    expect(row, 'a recount row for the counted catalog item must exist').toBeTruthy();
    // M1: the counted-catalog-derived recount row carries the master id.
    expect(row.master_item_id).toBe(M.belv);
    // The master id must NOT leak into the legacy purchase_items FK column.
    expect(row.item_id).toBeNull();
  });

  test('AVT/name-derived recount row carries master_item_id = null', async ({ page, db }) => {
    await startAuditAs(page, 'manager');

    // Count a catalog item so the audit is non-empty. v1.70: closeCount1
    // computes variance and builds the recount list purely from the AVT rows
    // (generateRecountFromAvt) — it does NOT fold in counted-derived rows. AVT
    // rows are name-derived from the variance report and carry no master id, so
    // the synced recount row must have master_item_id = null even though the
    // counted entry it corresponds to DID link a master.
    await addManual(page, 'Belvedere 1L', 3);

    // The mock's compute_avt_for_audit stub emits a HIGH-variance Belvedere row
    // (actual 1 vs theo 6 → flagged). Close Count 1 to drive compute → load →
    // generateRecountFromAvt → syncRecountsToSupabase.
    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    await expect.poll(() => db.t.kount_recounts.length).toBeGreaterThan(0);

    const avtRow = db.t.kount_recounts.find(r => r.item_name === 'Belvedere 1L');
    expect(avtRow, 'the AVT-flagged item must produce a recount row').toBeTruthy();
    // M1: AVT/name-derived rows legitimately carry null.
    expect(avtRow.master_item_id).toBeNull();
    expect(avtRow.item_id).toBeNull();
  });
});
