/* v2.13 CLIENT ERROR TELEMETRY COVERAGE.
 *
 * kount_client_errors (0041) + logClientError() existed, but only 7 catch sites
 * fed it; failures in audit start/join, recount sync, audit-meta sync, local
 * state save/load and UPC links only reached the device console. v2.13 wires
 * logClientError into those paths. These specs force a failure in a few of
 * them and assert a row actually lands in kount_client_errors (the mock stores
 * every REST POST as a row).
 */
const { test, expect, startAuditAs, addManual } = require('../fixtures');

const errorsFor = (db, context) =>
  (db.t.kount_client_errors || []).filter((r) => r.context === context);

test.describe('v2.13 client error logging', () => {
  test('a failed recount sync is recorded, tagged phone + version + user', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
    await expect.poll(() => page.evaluate(() => Object.keys(appState.audit.recounts || {}).length)).toBeGreaterThan(0);

    await page.evaluate(async () => {
      supabaseRest.update = async () => ({ data: null, error: { message: 'HTTP 500 forced by test' } });
      await syncRecountUpdateToSupabase(Object.keys(appState.audit.recounts)[0]);
    });

    await expect.poll(() => errorsFor(db, 'syncRecountUpdateToSupabase').length).toBeGreaterThan(0);
    const row = errorsFor(db, 'syncRecountUpdateToSupabase')[0];
    expect(row.app).toBe('phone');
    expect(row.message).toContain('forced by test');
    expect(row.app_version).toBe(await page.evaluate(() => APP_VERSION));
    expect(row.user_email).toBeTruthy();
  });

  test('a failed audit-meta sync is recorded', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(async () => {
      supabaseRest.update = async () => ({ data: null, error: { message: 'HTTP 403 forced by test' } });
      await syncAuditMetaToSupabase({ notes: 'x' });
    });
    await expect.poll(() => errorsFor(db, 'syncAuditMetaToSupabase').length).toBeGreaterThan(0);
  });

  test('a failed local state save is recorded', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => {
      const real = Storage.prototype.setItem;
      Storage.prototype.setItem = function (k, v) {
        if (k === 'hwood_v3') throw new Error('QuotaExceededError forced by test');
        return real.call(this, k, v);
      };
      saveState();
    });
    await expect.poll(() => errorsFor(db, 'saveState').length).toBeGreaterThan(0);
    expect(errorsFor(db, 'saveState')[0].message).toContain('QuotaExceededError');
  });

  test('repeated identical failures are de-duplicated, not spammed', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(async () => {
      supabaseRest.update = async () => ({ data: null, error: { message: 'HTTP 503 same error' } });
      for (let i = 0; i < 5; i++) await syncAuditMetaToSupabase({ notes: 'x' + i });
    });
    await expect.poll(() => errorsFor(db, 'syncAuditMetaToSupabase').length).toBeGreaterThan(0);
    await page.waitForTimeout(300);
    expect(errorsFor(db, 'syncAuditMetaToSupabase').length).toBe(1);
  });

  test('supabase-js is pinned to an exact version, not a floating major', async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    const src = await page.locator('script[src*="supabase-js@"]').getAttribute('src');
    expect(src).toMatch(/supabase-js@\d+\.\d+\.\d+$/);
  });
});
