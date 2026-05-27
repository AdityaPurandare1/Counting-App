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

    // Close Count 2 via the (temporarily) relaxed gate: incomplete recounts
    // are allowed after an explicit confirm. Audit finalizes as submitted.
    await page.evaluate(() => window.closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
  });
});
