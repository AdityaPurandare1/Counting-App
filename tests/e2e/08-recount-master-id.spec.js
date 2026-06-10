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

    // No AVT uploaded → closeCount1 takes the all-counted-items fallback branch
    // that derives recount rows from counted entries (and so carries masterId).
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

    // Count a catalog item so the audit is non-empty. (When AVT is present,
    // closeCount1 builds the recount list purely from AVT variance items via
    // generateRecountFromAvt — it does NOT fold in counted-derived rows, so the
    // only synced recount row here is the AVT one we assert on below.)
    await addManual(page, 'Belvedere 1L', 3);

    // Seed an AVT report into the mock for an item that is NOT in the catalog,
    // so the recount row it generates is name-derived with no master id. A large
    // variance_value scores HIGH → needsRecount() flags it. venue_id must match
    // the active venue (v-delilah) or generateRecountFromAvt filters it out.
    // We drive the app's real loadAvtFromSupabase() (reads kount_avt_reports +
    // kount_avt_rows) rather than poking module-private appState directly.
    // v1.62: report selection filters venue_ids (text[]) with the PostgREST
    // contains operator (`venue_ids=cs.{venue}`) and prefers source ASC
    // ('computed' < 'uploaded'), newest first — so the seed must carry the
    // venue_ids array or the report is correctly filtered out.
    db.t.kount_avt_reports = [{
      id: 'avt-rep-1', venue_id: 'v-delilah', venue_ids: ['v-delilah'],
      source: 'uploaded', uploaded_at: '2026-05-27T12:00:00Z',
    }];
    db.t.kount_avt_rows = [{
      id: 'avt-row-1', report_id: 'avt-rep-1', store: 'Delilah LA',
      venue_id: 'v-delilah', venue_name: 'Delilah LA',
      item_name: 'Phantom Amaro 700ml', category: 'Liquor Cost',
      actual: 0, theo: 12, variance: -12, variance_value: 9999, variance_pct: -100,
      cu_price: 50, start_qty: 12, purchases: 0, depletions: 0,
    }];
    // Load it through the real code path (returns a promise that resolves true
    // once appState.avtData is populated from the seeded rows).
    const loaded = await page.evaluate(() => window.loadAvtFromSupabase());
    expect(loaded, 'loadAvtFromSupabase must pick up the seeded AVT report').toBe(true);

    // With AVT present, closeCount1 takes the AVT branch (masterId: null).
    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    await expect.poll(() => db.t.kount_recounts.length).toBeGreaterThan(0);

    const avtRow = db.t.kount_recounts.find(r => r.item_name === 'Phantom Amaro 700ml');
    expect(avtRow, 'the AVT-flagged item must produce a recount row').toBeTruthy();
    // M1: AVT/name-derived rows legitimately carry null.
    expect(avtRow.master_item_id).toBeNull();
    expect(avtRow.item_id).toBeNull();
  });
});
