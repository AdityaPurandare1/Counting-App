/* v2.13: pre-close checks (migration 0078, kount_count_guardrails). Before Count 1 closes, the phone asks
   the server for warnings (empty zones, missing items, size switches, low-after-delivery, invoice gaps).
   Warnings only: Cancel keeps counting, Confirm continues to the normal close confirm. No rows or a failed
   check go straight to the normal close. */
const { test, expect, startAuditAs, addManual } = require('../fixtures');

async function clickClose(page) {
  await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
  await page.locator('#confirmDialog').waitFor({ state: 'visible' });
}
const msg = (page) => page.locator('#confirmMsg').innerText();

test.describe('v2.13 close guardrails', () => {
  test('no warnings: the first dialog is the normal Close Count 1 confirm', async ({ page, db }) => {
    db.guardrailsRows = [];
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await clickClose(page);
    expect(await msg(page)).toMatch(/^Close Count 1\?/);
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
  });

  test('warnings first; Cancel keeps the count open and the warnings return on the next try', async ({ page, db }) => {
    db.guardrailsRows = [
      { kind: 'zone_empty', message: 'Liquor Room: 92 items there last count, nothing counted there now', sort_value: 92 },
      { kind: 'low_after_delivery', message: 'Diet Coke - Bev 8fl.oz: 6 counted, but 144 arrived since Sep 27.', sort_value: 144 },
      { kind: 'invoice_gap', message: 'SOUTHERN GLAZERS: no invoice for the week of Sep 14, Sep 21', sort_value: null },
    ];
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await clickClose(page);
    const text = await msg(page);
    expect(text).toContain('Before closing, please check');
    expect(text).toContain('Liquor Room: 92 items');
    expect(text).toContain('Diet Coke');
    expect(text).toContain('no invoice for the week of Sep 14');
    // zone warnings are listed before invoice gaps
    expect(text.indexOf('Liquor Room')).toBeLessThan(text.indexOf('SOUTHERN GLAZERS'));
    await page.evaluate(() => window.closeConfirm(false));
    await expect(page.locator('#confirmDialog')).toBeHidden();
    expect(db.t.kount_audits[0].count_phase).toBe('count1');
    await clickClose(page);
    expect(await msg(page)).toContain('Before closing, please check');
  });

  test('Confirm on the warnings leads to the normal close, which completes; acknowledged once per audit', async ({ page, db }) => {
    db.guardrailsRows = [{ kind: 'size_switch', message: 'Orange Juice 1L counted (18), but last count used orange juice 3L (3).', sort_value: 18 }];
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await clickClose(page);
    expect(await msg(page)).toContain('Possibly the wrong bottle size');
    await page.evaluate(() => window.closeConfirm(true));
    // the normal confirm opens next and keeps its handler (deferred retry)
    await expect.poll(() => msg(page)).toMatch(/^Close Count 1\?/);
    await page.evaluate(() => window.closeConfirm(false));
    // already acknowledged: the next try goes straight to the normal confirm
    await clickClose(page);
    expect(await msg(page)).toMatch(/^Close Count 1\?/);
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
  });

  test('a failed check never blocks the close', async ({ page, db }) => {
    db.guardrailsError = 'boom';
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await clickClose(page);
    expect(await msg(page)).toMatch(/^Close Count 1\?/);
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
  });
});
