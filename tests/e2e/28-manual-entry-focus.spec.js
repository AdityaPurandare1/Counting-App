/* v2.13 MANUAL ENTRY FOCUS RACE.
 *
 * openManualEntry() focuses #manualName on a 100ms setTimeout. If the qty field
 * was focused inside that window, the late focus() moved the caret to the name
 * mid-entry and the qty landed there: "Belvedere 1L" + qty 3 -> "Belvedere 1L3",
 * which misses the exact catalog match and opens the "Did you mean?" picker.
 * That was the cause of the suite's intermittent failures (03, 13, 16, 17, 18,
 * 25... — the failure snapshots all show "You typed: Belvedere 1L3").
 *
 * The test opens the modal and focuses qty in ONE synchronous tick, so qty is
 * guaranteed to be focused before the delayed focus fires — it reproduces the
 * race every time instead of only under load.
 */
const { test, expect, startAuditAs, addManual, qtyOf } = require('../fixtures');

test.describe('v2.13 manual entry — delayed focus never steals from qty', () => {
  test('focusing qty right after opening keeps focus (and the typed qty) there', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => {
      openManualEntry();
      document.getElementById('manualQty').focus();
    });
    await page.waitForTimeout(250); // well past the 100ms delayed focus
    expect(await page.evaluate(() => document.activeElement && document.activeElement.id)).toBe('manualQty');
    await page.keyboard.type('3');
    expect(await page.inputValue('#manualName')).toBe('');
  });

  test('with nothing focused, the name field still gets auto-focus', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await expect(page.locator('#manualName')).toBeFocused();
  });

  test('a normal manual add still links the exact catalog item', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect(page.locator('#fuzzyMatchPickerModal:not(.hide)')).toHaveCount(0);
    expect(await qtyOf(page, 'Belvedere 1L')).toBe(3);
  });
});
