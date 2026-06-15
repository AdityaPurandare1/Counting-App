const { test, expect, startAuditAs, addManual } = require('../fixtures');

test.describe('Count 1 → Count 2 lifecycle', () => {
  test('manager closes Count 1 (→ review) then closes Count 2 (→ submitted)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    // Close Count 1 → confirm.
    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // v1.70: closing Count 1 on a networked audit COMPUTES variance (the mock
    // compute_avt_for_audit stub emits a HIGH-variance Belvedere row), so the
    // recount list is variance-driven, not all-items. The Belvedere row is
    // present; the zero-variance Tito's row is NOT flagged.
    await expect.poll(() => db.t.kount_avt_reports.filter(r => r.audit_id === db.t.kount_audits[0].id && r.source === 'computed').length).toBe(1);
    await expect.poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 }).toBeGreaterThan(0);
    const recountNames = await page.evaluate(() =>
      Object.values(appState.audit.recounts).map((r) => r.itemName));
    expect(recountNames).toContain('Belvedere 1L');
    expect(recountNames).not.toContain("Tito's Handmade Vodka 750ml");

    // v1.62: the strict close gate is RESTORED — every recount row needs a
    // manager decision + reason + numeric recountQty before Count 2 can
    // close (the 2026-05-27 relaxed bypass is gone). Complete the rows the
    // way the recount modal would, then close. Audit finalizes as submitted.
    await page.evaluate(() => {
      Object.values(appState.audit.recounts).forEach((r) => {
        r.auditResult = 'verified';
        r.auditReason = 'robot QA: count verified against shelf';
        r.recountQty = r.count1Qty != null ? r.count1Qty : 0;
        r.status = 'done';
      });
    });
    await page.evaluate(() => window.closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
    // v1.62: finalize also mirrors count2_closed_at to the audit row.
    await expect.poll(() => db.t.kount_audits[0].count2_closed_at).toBeTruthy();
  });
});
