/* v1.98 BUG 4 — closeCount1AndFinalize handles loadAvtForAudit === 'error'
   (counting-app.html ~13543).

   compute_avt_for_audit can SUCCEED while the immediate read-back of the report
   errors (read-replica lag). loadAvtForAudit distinguishes this by returning the
   tri-state 'error' (vs false = genuinely-absent). closeCount1 must treat that
   as "variance computed but not readable yet": show a WARNING, fall back to the
   all-items recount list for now, and ENQUEUE a recompute — NOT imply there's no
   POS link, and NOT report a clean/finished success.

   We keep the default compute stub (succeeds, inserts the report) but make every
   kount_avt_reports SELECT error, so loadAvtForAudit retries once and returns
   'error'. Mirrors spec 13's monkeypatch-the-shared-db approach.

   FAIL-BEFORE: with the `loaded === 'error'` handling reverted, computeReadError
   stays false → no recompute is enqueued and the toast is the misleading
   "couldn't be computed (offline or no POS link)" message. */
const { test, expect, startAuditAs, addManual } = require('../fixtures');

test.describe('v1.98 Count 1 close: AVT read-replica lag', () => {
  test("loadAvt 'error' → warning + recompute enqueued (no false 'no POS link' / success)", async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');
    const auditId = db.t.kount_audits[0].id;

    // compute_avt_for_audit still succeeds (default stub inserts the report),
    // but reading the report back errors — even on loadAvtForAudit's retry.
    const origSelect = db.select.bind(db);
    db.select = function (table, headers, qs) {
      if (table === 'kount_avt_reports') {
        return { status: 503, body: { code: 'PGRST_LAG', message: 'read replica lag', details: null, hint: null } };
      }
      return origSelect(table, headers, qs);
    };

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // The phase flips (meta sync) BEFORE the compute RPC + loadAvtForAudit's
    // 800ms read retry finish, so poll rather than read once. The compute RPC
    // did run and wrote a report row (proves compute succeeded, not "no POS").
    await expect
      .poll(() => db.t.kount_avt_reports.filter((r) => r.audit_id === auditId && r.source === 'computed').length,
        { timeout: 5000 })
      .toBe(1);

    // WARNING that names the read-lag ("wasn't readable yet / variance will
    // update shortly") — NOT the misleading "offline or no POS link" message,
    // and NOT a clean-success "no significant variance".
    const toast = page.locator('.toast').last();
    await expect(toast).toContainText(/wasn.t readable yet|variance will update shortly/i);
    await expect(toast).not.toContainText(/no significant variance/i);
    await expect(toast).not.toContainText(/no POS link/i);

    // A recompute for THIS audit is enqueued so the variance heals later.
    await expect
      .poll(() => page.evaluate(({ id }) => avtComputeQueue.filter((e) => e && e.auditId === id).length, { id: auditId }),
        { timeout: 5000 })
      .toBeGreaterThan(0);

    // All-items fallback list is populated so the counter isn't stranded.
    const recountCount = await page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length);
    expect(recountCount).toBeGreaterThan(0);
  });

  /* The fix ALSO lives in the CORPORATE-only closeCount1AndFinalize (~13840).
     The manager closeCount1 test above exercises the sibling pattern, but the
     corporate finalize path (submit/stamp + compute, Count 2 skipped) has its
     own copy of the loaded==='error' handling, so drive it directly.
     Setup/harness mirrors 16-v183-features.spec.js F7 (corporate + confirm). */
  test("corporate closeCount1AndFinalize: loadAvt 'error' → 'still loading' warning + recompute (no false 'final report ready')", async ({ page, db }) => {
    await startAuditAs(page, 'corporate');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');
    const auditId = db.t.kount_audits[0].id;

    // Same read-error hook: compute RPC succeeds (default stub writes the report)
    // but every kount_avt_reports read-back errors → loadAvtForAudit → 'error'.
    const origSelect = db.select.bind(db);
    db.select = function (table, headers, qs) {
      if (table === 'kount_avt_reports') {
        return { status: 503, body: { code: 'PGRST_LAG', message: 'read replica lag', details: null, hint: null } };
      }
      return origSelect(table, headers, qs);
    };

    await page.evaluate(() => closeCount1AndFinalize());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));

    // Finalize still stamps submitted/final (compute lag must not block the close).
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');

    // Compute DID run (phase flips before the RPC + 800ms loadAvt retry — poll).
    await expect
      .poll(() => db.t.kount_avt_reports.filter((r) => r.audit_id === auditId && r.source === 'computed').length,
        { timeout: 5000 })
      .toBe(1);

    // WARNING that the report is still loading — NOT the false "final report ready"
    // success (which would render an empty/stale variance page under a green banner).
    const toast = page.locator('.toast').last();
    await expect(toast).toContainText(/still loading|appear shortly/i);
    await expect(toast).not.toContainText(/final report ready/i);

    // A recompute for THIS audit is enqueued so the variance heals later.
    await expect
      .poll(() => page.evaluate(({ id }) => avtComputeQueue.filter((e) => e && e.auditId === id).length, { id: auditId }),
        { timeout: 5000 })
      .toBeGreaterThan(0);
  });
});
