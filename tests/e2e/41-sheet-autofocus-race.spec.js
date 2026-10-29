/* Deferred autofocus must not steal focus from a field the counter already
 * moved to (2026-10-29).
 *
 * openRecountEntry / openGuidedEntry / openManualEntry each focus their first
 * field from a setTimeout(…, 100) so the slide-up sheet is on screen first.
 * The timer focused UNCONDITIONALLY: a tap into another field of the same
 * sheet before it fired (or a main thread busy long enough to delay it) had
 * focus yanked back to the qty/name box mid-typing. In the recount sheet the
 * "Why?" text then landed in the number input (an invalid number reads back
 * as ''), the reason stayed blank, and Confirm refused with "Enter a valid
 * quantity" — the sheet stayed open. That was the intermittent
 * "recount sheet doesn't close on Confirm" in 24 / 38 / 39: Playwright's
 * fill() of the reason field occasionally straddled the 100 ms timer.
 *
 * Each test focuses a second field in the same tick the sheet opens, waits
 * past the timer, and types — deterministic on the old code.
 */
const { test, expect, startAuditAs, addManual, switchZone, M } = require('../fixtures');

const ITEM = 'Belvedere 1L';
const PAST_AUTOFOCUS_MS = 300;   // > the sheets' 100 ms deferred focus

async function addItem(page, zone, name, qty) {
  await addManual(page, name, qty);
  const picker = page.locator('#fuzzyMatchPickerModal');
  if (await picker.isVisible().catch(() => false)) {
    const exact = picker.locator('.fuzzy-pick', { hasText: name }).first();
    await (await exact.count() ? exact : picker.locator('.fuzzy-pick').first()).click();
    await picker.waitFor({ state: 'hidden' });
  }
  await expect
    .poll(() => page.evaluate((z) => (((appState.audit || {}).counts || {})[z] || []).length, zone))
    .toBeGreaterThan(0);
}

async function seedRecount(page, db, zone, qty) {
  await switchZone(page, zone);
  await addItem(page, zone, ITEM, qty);
  await page.evaluate(() => closeCount1());
  await page.locator('#confirmDialog').waitFor({ state: 'visible' });
  await page.evaluate(() => window.closeConfirm(true));
  await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
  await expect.poll(() => db.t.kount_recounts.filter((r) => r.item_name === ITEM).length, { timeout: 5000 }).toBe(1);
  await expect.poll(() => page.evaluate(() => !!appState.audit._recountListPending)).toBe(false);
}

const activeId = (page) => page.evaluate(() => document.activeElement && document.activeElement.id);

test.describe('sheet autofocus never steals a field the counter is typing in', () => {
  test('recount sheet: "Why?" keeps focus, and Confirm saves and closes', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, 'Bar', 2);
    const key = ITEM + '|Bar';

    // The counter taps straight into "Why?" before the sheet's autofocus fires.
    await page.evaluate((k) => {
      openRecountEntry(k);
      document.getElementById('recountReasonInput').focus();
    }, key);
    await page.waitForTimeout(PAST_AUTOFOCUS_MS);
    expect(await activeId(page)).toBe('recountReasonInput');
    await page.keyboard.insertText('matches the shelf');
    await expect(page.locator('#recountReasonInput')).toHaveValue('matches the shelf');

    await page.fill('#guidedQty', '2');
    await page.selectOption('#recountResultSelect', 'verified');
    await page.locator('#guidedConfirmBtn').click();
    await expect(page.locator('#guidedEntryModal')).toBeHidden();
    await expect.poll(() => db.t.kount_recounts.find((r) => r.zone === 'Bar').count2_qty).toBe(2);
    expect(db.t.kount_recounts.find((r) => r.zone === 'Bar').audit_reason).toBe('matches the shelf');
  });

  test('recount sheet: with nothing focused, the qty field still gets the autofocus', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, 'Bar', 2);
    await page.evaluate((k) => openRecountEntry(k), ITEM + '|Bar');
    await expect.poll(() => activeId(page)).toBe('guidedQty');
  });

  test('count sheet: issue notes keep focus while the counter types', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate((id) => {
      openGuidedEntry(id);
      document.getElementById('guidedIssueNotes').focus();
    }, M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.waitForTimeout(PAST_AUTOFOCUS_MS);
    expect(await activeId(page)).toBe('guidedIssueNotes');
    await page.keyboard.insertText('sticker fell off');
    await expect(page.locator('#guidedIssueNotes')).toHaveValue('sticker fell off');
    await page.evaluate(() => closeGuidedEntry());
  });

  test('manual sheet: a qty typed before the autofocus fires stays in the qty box', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => {
      openManualEntry();
      const q = document.getElementById('manualQty'); q.focus(); q.select();
    });
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.waitForTimeout(PAST_AUTOFOCUS_MS);
    expect(await activeId(page)).toBe('manualQty');
    await page.keyboard.insertText('3');
    await expect(page.locator('#manualQty')).toHaveValue('3');
    await expect(page.locator('#manualName')).toHaveValue('');
  });
});
