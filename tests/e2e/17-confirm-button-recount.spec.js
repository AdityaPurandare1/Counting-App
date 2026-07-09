/* Regression: the guided Confirm button (#guidedConfirmBtn) must not leak a
 * stale "Confirm N" / "Confirm total N" label or its pulsing `needs-confirm`
 * class from one guided-entry open into the next — in particular into the
 * RECOUNT modal.
 *
 * THE BUG (now fixed):
 *   - onGuidedQtyInput() relabels #guidedConfirmBtn to "Confirm N" (set mode)
 *     or "Confirm total N" (add mode) and adds the pulsing `needs-confirm`
 *     class whenever the qty field holds a value.
 *   - closeGuidedEntry() did NOT reset that button, and openRecountEntry() —
 *     which reuses the same guided modal — set the recount qty but never
 *     re-synced the button. So a stale "Confirm total 8" label + pulse from a
 *     prior COUNT entry could bleed into the recount modal, mislabeling the
 *     recount's own action.
 *
 * THE FIX (counting-app.html):
 *   - closeGuidedEntry() now resets the button to text "Confirm" and removes
 *     `needs-confirm` (~line 9641-9642).
 *   - openRecountEntry() now calls onGuidedQtyInput() AFTER setting the qty
 *     (~line 14007) so the button reflects the recount's own field state.
 *
 * The manager closeCount1() -> recount-list flow used here is the same one
 * 16-v183-features's last test exercises; it reliably produces a "Belvedere 1L"
 * recount row whose recountQty is null (blank field), which is exactly the
 * empty-field case that proves `needs-confirm` is absent after the fix.
 */
const { test, expect, startAuditAs, addManual, M } = require('../fixtures');

test.describe('Confirm button does not leak stale label/pulse into recount', () => {
  test('count-entry label + pulse are reset on close and never bleed into a recount', async ({ page, db }) => {
    await startAuditAs(page, 'manager');

    // ---- (1) A normal count entry dirties the Confirm button. ----
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });

    const btn = page.locator('#guidedConfirmBtn');
    // Type 8 -> the input handler relabels the button and adds the pulse.
    await page.fill('#guidedQty', '8');
    await page.evaluate(() => onGuidedQtyInput());
    // Button now advertises the typed qty and pulses. (Set-mode label is
    // "Confirm 8"; add-mode would be "Confirm total 8" — accept either so the
    // assertion is robust to the modal's qty mode, but it MUST carry the 8.)
    await expect(btn).toHaveText(/^Confirm (total )?8$/);
    await expect(btn).toHaveClass(/needs-confirm/);

    // ---- (2) Closing (Skip) must RESET the button. ----
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Skip', exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
    // The reset runs on close, so even while hidden the label/pulse are gone.
    await expect(btn).toHaveText('Confirm');
    await expect(btn).not.toHaveClass(/needs-confirm/);

    // A fresh non-recount open must NOT resurrect the stale "Confirm 8".
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await expect(page.locator('#guidedQty')).toHaveValue('');
    await expect(btn).toHaveText('Confirm');
    await expect(btn).not.toHaveClass(/needs-confirm/);
    // Re-dirty it, then leave it dirty on close via the same Skip path — this
    // is the stale state that (pre-fix) leaked into the recount modal below.
    await page.fill('#guidedQty', '8');
    await page.evaluate(() => onGuidedQtyInput());
    await expect(btn).toHaveText(/^Confirm (total )?8$/);
    await expect(btn).toHaveClass(/needs-confirm/);
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Skip', exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    // ---- (3) Drive into a recount and open a recount entry. ----
    // Manager closeCount1 computes variance and builds the recount list. The
    // mock flags Belvedere as high-variance, so a "Belvedere 1L" recount row
    // exists. (Same flow as 16-v183-features's manager-closeCount1 test.)
    // Count something first so the audit is non-empty.
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // Wait for the recount list to materialize, then grab a real recount key.
    await expect
      .poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 })
      .toBeGreaterThan(0);
    const recountKey = await page.evaluate(() =>
      Object.keys(appState.audit.recounts).find(k => appState.audit.recounts[k].itemName === 'Belvedere 1L')
      || Object.keys(appState.audit.recounts)[0]);
    expect(recountKey, 'a recount row must exist to open').toBeTruthy();

    // The recount row's own recountQty (null here = blank field) drives what
    // the button SHOULD show after the fix.
    const recountQty = await page.evaluate((k) => appState.audit.recounts[k].recountQty, recountKey);

    // Open the recount entry — the guided modal is reused. Pre-fix the button
    // still read "Confirm total 8" + pulsed (leaked from step 2). Post-fix
    // openRecountEntry re-syncs it via onGuidedQtyInput.
    await page.evaluate((k) => openRecountEntry(k), recountKey);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await expect(page.locator('#guidedEntryModal')).toHaveAttribute('data-mode', 'recount');

    // (3a) NO stale label: the button must not still say "...8".
    await expect(btn).not.toHaveText(/8/);
    // Whatever it says, it must start with "Confirm".
    await expect(btn).toHaveText(/^Confirm/);

    // (3b) The button reflects the recount's OWN field state, and
    // (3c) `needs-confirm` presence matches whether a qty is present.
    if (recountQty == null || Number(recountQty) === 0 ||
        (await page.locator('#guidedQty').inputValue()).trim() === '') {
      // Blind recount starts blank -> plain "Confirm", no pulse.
      await expect(page.locator('#guidedQty')).toHaveValue('');
      await expect(btn).toHaveText('Confirm');
      await expect(btn).not.toHaveClass(/needs-confirm/);
    } else {
      // A prefilled recount qty -> "Confirm <qty>" + pulse.
      await expect(btn).toHaveText(new RegExp('^Confirm (total )?' + recountQty + '$'));
      await expect(btn).toHaveClass(/needs-confirm/);
    }

    // (3d) Behavioral proof of the live sync: typing in the recount field now
    // relabels + pulses, and clearing it resets — the button tracks THIS modal.
    await page.fill('#guidedQty', '5');
    await page.evaluate(() => onGuidedQtyInput());
    await expect(btn).toHaveText(/^Confirm (total )?5$/);
    await expect(btn).toHaveClass(/needs-confirm/);
    await page.fill('#guidedQty', '');
    await page.evaluate(() => onGuidedQtyInput());
    await expect(btn).toHaveText('Confirm');
    await expect(btn).not.toHaveClass(/needs-confirm/);
  });
});
