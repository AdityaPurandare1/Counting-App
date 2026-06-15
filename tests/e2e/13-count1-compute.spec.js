/* v1.70: Count 1 close now COMPUTES variance (computed AVT is the product;
   Craftable pre-loads are gone). Migration 0038 makes compute_avt_for_audit
   work at count-1 close too. These specs cover:
     - networked Count 1 close → compute runs → variance-driven recount list
     - compute returns zero variance → empty recount list, finalize still works
   The mock's compute_avt_for_audit stub (mockdb.computeAvtForAudit) emits a
   HIGH-variance Belvedere row by default; the zero-variance case monkeypatches
   it on the shared db instance before the close. */
const { test, expect, startAuditAs, addManual } = require('../fixtures');

test.describe('v1.70 Count 1 compute', () => {
  test('closing Count 1 on a networked audit computes variance and drives the recount list', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // compute_avt_for_audit produced exactly one computed report for THIS audit.
    await expect
      .poll(() => db.t.kount_avt_reports.filter((r) => r.audit_id === db.t.kount_audits[0].id && r.source === 'computed').length)
      .toBe(1);

    // The recount list is variance-driven: Belvedere (high variance) is flagged,
    // Tito's (zero variance) is not.
    await expect
      .poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 })
      .toBeGreaterThan(0);
    const names = await page.evaluate(() => Object.values(appState.audit.recounts).map((r) => r.itemName));
    expect(names).toContain('Belvedere 1L');
    expect(names).not.toContain("Tito's Handmade Vodka 750ml");

    // appState.avtData reflects the freshly computed report.
    const avtLen = await page.evaluate(() => (appState.avtData || []).length);
    expect(avtLen).toBeGreaterThan(0);
  });

  test('zero-variance compute → empty recount list, but finalize is still reachable', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);

    // Make compute emit a report with NO significant variance for this run.
    const rid = () => 'rrrrrrrr-rrrr-4rrr-8rrr-' + Date.now().toString(16).padStart(12, '0').slice(-12);
    db.computeAvtForAudit = function (args) {
      const uuid = rid;
      const auditId = args.p_audit_id;
      const audit = this.t.kount_audits.find((a) => a.id === auditId);
      const venueId = audit ? audit.venue_id : null;
      const reportId = uuid();
      const now = new Date().toISOString();
      if (!this.t.kount_avt_reports) this.t.kount_avt_reports = [];
      if (!this.t.kount_avt_rows) this.t.kount_avt_rows = [];
      this.t.kount_avt_reports.push({
        id: reportId, audit_id: auditId, venue_ids: [venueId],
        source: 'computed', uploaded_at: now, computed_at: now,
      });
      // A perfectly-matched row: zero variance → never flagged for recount.
      this.t.kount_avt_rows.push({
        id: uuid(), report_id: reportId, venue_id: venueId, venue_name: '',
        store: '', item_name: 'Belvedere 1L', category: 'Liquor Cost',
        actual: 3, theo: 3, variance: 0, variance_value: 0, variance_pct: 0,
        cu_price: 30, start_qty: 0, purchases: 0, depletions: 0,
      });
      return { status: 200, body: reportId };
    };

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // Computed cleanly with no significant variance → empty recount list and a
    // reassuring toast (not a confusing blank page).
    await expect(page.locator('.toast')).toContainText(/no significant variance/i);
    const count = await page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length);
    expect(count).toBe(0);

    // Finalize is still reachable with zero recount rows: closeCount2's gates
    // short-circuit on an empty entries list, so the confirm appears and the
    // audit submits.
    await page.evaluate(() => window.closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
  });
});
