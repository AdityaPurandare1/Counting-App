/* v2.15 RECOUNT CARD UX (counter feedback, Anna @ Poppy).
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
const { test, expect, startAuditAs } = require('../fixtures');

/* Add an entry through the app's own addCountEntry (the function the Manual
   modal calls), NOT by typing into the modal. The modal's delayed name-field
   focus can swallow the qty keystroke ("Belvedere 1L3"), which made this
   setup fail at random; the recount card is what these specs are about. */
async function addEntry(page, zone, name, qty) {
  await page.evaluate(([z, n, q]) => {
    appState.currentZone = z;
    addCountEntry(n, 'spirits', q, 'manual', '', '', 'none', null, null, null);
  }, [zone, name, qty]);
}

async function seedTwoZoneRecount(page, db) {
  await addEntry(page, 'Liquor Room', 'Belvedere 1L', 3);
  await addEntry(page, 'Bar', 'Belvedere 1L', 2);

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

test.describe('v2.15 recount card — why-flagged explanation', () => {
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

  test('card states what the system expects, once per card, so over/short can be judged', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    const theo = await page.evaluate(() =>
      Object.values(appState.audit.recounts).find((r) => r.itemName === 'Belvedere 1L').theo);
    expect(typeof theo).toBe('number');
    const text = await card(page).innerText();
    expect((text.match(/System expects/g) || []).length).toBe(1);
    expect(text).toContain('System expects ' + Number(theo.toFixed(1)));
  });

  test('expected line is omitted (not "NaN") when theo is missing', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    await page.evaluate(() => {
      Object.values(appState.audit.recounts)
        .filter((r) => r.itemName === 'Belvedere 1L').forEach((r) => { delete r.theo; });
      renderRecountPage();
    });
    const text = await card(page).innerText();
    expect(text).not.toContain('System expects');
    expect(text).not.toContain('NaN');
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

test.describe('v2.15 recount card — full-row tap target', () => {
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

  // Apple HIG minimum touch target is 44pt; the pre-v2.15 row was ~27px.
  test('zone row meets the 44px minimum touch target', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db);
    const box = await card(page).locator('div.recount-zone-row').first().boundingBox();
    expect(box).not.toBeNull();
    expect(box.height).toBeGreaterThanOrEqual(44);
  });
});
