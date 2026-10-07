/* v2.12 RECOUNT CARD UX (counter feedback, Anna @ Poppy).
 *
 * 1. Tap target: the per-zone row (div.recount-zone-row) must open THAT zone's
 *    recount entry when tapped anywhere on it — not only on the zone name.
 * 2. Silent flags: a CRITICAL/HIGH card whose item-level variance is exactly 0
 *    (flagged on weeksActive alone) must explain why instead of showing only
 *    the badge. weeksActive is threaded generateRecountFromAvt -> recount row.
 *
 * Seeding mirrors 18-verify-total: the mock's compute_avt_for_audit flags
 * Belvedere 1L HIGH at -5 bottles; counting it in two zones yields two rows.
 */
const { test, expect, startAuditAs, addManual, switchZone } = require('../fixtures');

async function seedTwoZoneRecount(page, db) {
  await switchZone(page, 'Liquor Room');
  await addManual(page, 'Belvedere 1L', 3);
  await switchZone(page, 'Bar');
  await addManual(page, 'Belvedere 1L', 2);

  await page.evaluate(() => closeCount1());
  await page.locator('#confirmDialog').waitFor({ state: 'visible' });
  await page.evaluate(() => window.closeConfirm(true));
  await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
  await expect
    .poll(() => page.evaluate(() =>
      Object.values((appState.audit && appState.audit.recounts) || {})
        .filter((r) => r.itemName === 'Belvedere 1L').length), { timeout: 5000 })
    .toBeGreaterThanOrEqual(2);
}

/* Force the item-level variance to 0 and set weeksActive on every Belvedere
   row, then re-render — the shape scoreSeverity produces for a chronic item
   whose count matched theoretical this audit. */
async function makeSilentFlag(page, weeks) {
  await page.evaluate((w) => {
    Object.values(appState.audit.recounts)
      .filter((r) => r.itemName === 'Belvedere 1L')
      .forEach((r) => { r.variance = 0; r.varianceValue = 0; r.weeksActive = w; });
    renderRecountPage();
  }, weeks);
}

const card = (page) => page.locator('div.focus-item[data-recount-item="Belvedere 1L"]');

test.describe('v2.12 recount card — why-flagged explanation', () => {
  test('weeksActive is threaded onto every stored recount row', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    const types = await page.evaluate(() =>
      Object.values(appState.audit.recounts)
        .filter((r) => r.itemName === 'Belvedere 1L')
        .map((r) => typeof r.weeksActive));
    expect(types.length).toBeGreaterThanOrEqual(2);
    for (const t of types) expect(t).toBe('number');
  });

  test('a real over/short figure still shows, with NO fallback text', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    const text = await card(page).innerText();
    expect(text).toContain('5.0 bottles short');
    expect(text).not.toContain('No change this count');
  });

  test('zero variance + weeksActive explains the chronic flag', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    await makeSilentFlag(page, 7);
    const text = await card(page).innerText();
    expect(text).toContain('No change this count');
    expect(text).toContain('flagged for being off 7 weeks running');
    expect(text).not.toContain('bottles short');
    expect(text).not.toContain('bottles over');
    // Rendered once per card, not once per zone row.
    expect((text.match(/No change this count/g) || []).length).toBe(1);
  });

  test('singular "week" for weeksActive = 1', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    await makeSilentFlag(page, 1);
    const text = await card(page).innerText();
    expect(text).toContain('flagged for being off 1 week running');
    expect(text).not.toContain('1 weeks');
  });

  test('zero variance with no weeksActive falls back to a generic reason', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    await makeSilentFlag(page, 0);
    const text = await card(page).innerText();
    expect(text).toContain('flagged by historical pattern');
  });
});

/* Root cause of the suite's intermittent "Did you mean?" failures: the Manual
   modal's delayed name-field focus (100ms) stole focus from the qty box, so the
   qty keystrokes landed in the name ("Belvedere 1L3"). Reproduced
   deterministically here by focusing qty inside that 100ms window. */
test.describe('v2.12 manual entry — delayed focus never steals from qty', () => {
  test('focusing qty right after opening keeps focus (and the typed qty) there', async ({ page }) => {
    await startAuditAs(page, 'manager');
    // Open and focus qty in ONE synchronous tick, so qty is guaranteed to be
    // focused before the 100ms delayed focus fires (a real race, not timing luck).
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
});

test.describe('v2.12 recount card — full-row tap target', () => {
  test('tapping the RIGHT side of a zone row opens that row\'s recount entry', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    const rows = card(page).locator('div.recount-zone-row');
    await expect(rows).toHaveCount(2);

    for (let i = 0; i < 2; i++) {
      const row = rows.nth(i);
      const key = await row.getAttribute('data-recount-key');

      // Tap the "Awaiting" badge (far from the zone name).
      await row.getByText('Awaiting').click();
      const modal = page.locator('#guidedEntryModal');
      await expect(modal).not.toHaveClass(/\bhide\b/);
      expect(await modal.getAttribute('data-master-id')).toBe(key);
      await page.evaluate(() => closeGuidedEntry());
      await expect(modal).toHaveClass(/\bhide\b/);

      // Tap the trailing chevron too.
      await row.getByText('›').click();
      await expect(modal).not.toHaveClass(/\bhide\b/);
      expect(await modal.getAttribute('data-master-id')).toBe(key);
      await page.evaluate(() => closeGuidedEntry());
    }
  });

  // Apple HIG minimum touch target is 44pt; the pre-v2.12 row was ~27px.
  test('zone row meets the 44px minimum touch target', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    const box = await card(page).locator('div.recount-zone-row').first().boundingBox();
    expect(box).not.toBeNull();
    expect(box.height).toBeGreaterThanOrEqual(44);
  });
});
