/* v2.17 COUNTER-RAISED ISSUES + FLAGGED COUNT (Poppy, P-843).
 *
 * "One item flagged, couldn't locate it, nothing under Critical/High": the flag
 * was a counter-raised 'Not in inventory' chip on one entry. It is not a
 * variance item, so it can never appear under Critical/High or the recount
 * list; it lived only on a header-menu Issues page and as a raw token.
 *
 * Entries are injected straight into appState (not via the Manual modal) so
 * these specs don't depend on the modal's focus timing.
 */
const { test, expect, startAuditAs } = require('../fixtures');

async function seedFlagged(page) {
  await page.evaluate(() => {
    appState.audit.counts['Bar'] = (appState.audit.counts['Bar'] || []).concat([
      { id: 'f1', name: 'Mount Gay Black Barrel 750ml', category: 'spirits', qty: 5.6,
        method: 'guided', issue: 'not-in-craftable', notes: '', timestamp: new Date().toISOString() },
      { id: 'f2', name: 'Belvedere 1L', category: 'spirits', qty: 2,
        method: 'guided', issue: 'none', notes: '', timestamp: new Date().toISOString() },
    ]);
    saveState();
  });
}
const stats = (page) => page.locator('#varianceStats');

test.describe('v2.17 flagged-by-counters on the Variance screen', () => {
  test('lists the flagged entry with a readable label, not the raw token', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await seedFlagged(page);
    await page.evaluate(() => showPage('variance'));
    const text = await stats(page).innerText();
    expect(text).toContain('Flagged by counters (1)');
    expect(text).toContain('Mount Gay Black Barrel 750ml');
    expect(text).toContain('Bar');
    expect(text).toContain('Not in inventory');
    expect(text).not.toContain('not-in-craftable');
    expect(text).not.toContain('Belvedere 1L'); // unflagged entry is not listed
  });

  test('no flagged entries -> the block is absent', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => showPage('variance'));
    expect(await stats(page).innerText()).not.toContain('Flagged by counters');
  });

  test('tapping the entry opens the Count screen on that zone', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await seedFlagged(page);
    await page.evaluate(() => { appState.currentZone = 'Liquor Room'; showPage('variance'); });
    await page.locator('.flagged-entry').first().click();
    await expect.poll(() => page.evaluate(() => appState.currentZone)).toBe('Bar');
    await expect(page.locator('#page-count')).toBeVisible();
  });

  test('zone list shows the readable label too', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await seedFlagged(page);
    await page.evaluate(() => { appState.currentZone = 'Bar'; showPage('count'); renderCountPage(); });
    const text = await page.locator('#guidedContent').innerText();
    expect(text).toContain('Not in inventory');
    expect(text).not.toContain('not-in-craftable');
  });

  test('closing Count 1 names the flagged entry in the confirmation', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await seedFlagged(page);
    await page.evaluate(() => {
      const id = appState.audit && appState.audit.supabaseId;
      if (id && typeof _guardrailsAck !== 'undefined') _guardrailsAck[id] = true;
      closeCount1();
    });
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    const msg = await page.locator('#confirmMsg').innerText();
    expect(msg).toContain('1 item flagged by counters');
    expect(msg).toContain('Mount Gay Black Barrel 750ml (Not in inventory, Bar)');
    await page.evaluate(() => window.closeConfirm(false));
  });
});

test.describe('v2.17 "Flagged for recount" equals the recount list', () => {
  test('counts the items on the list, not every MEDIUM-or-worse item', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => {
      const vid = appState.currentVenue.id;
      const mk = (n) => ({ store: '', venueId: vid, venueName: appState.currentVenue.name, itemName: n,
        category: 'spirits', theo: 10, actual: 7, variance: -3, varianceValue: -300, variancePct: -30, cuPrice: 100 });
      appState.avtData = [mk('Item A'), mk('Item B'), mk('Item C')];
      appState.audit.countPhase = 'review';
      appState.audit.recounts = { 'Item A|Bar': { itemName: 'Item A', zone: 'Bar', status: 'pending', severity: 'MEDIUM', count1Qty: 7 } };
      showPage('variance');
    });
    // Premise: all three are recount-worthy by severity alone.
    const sevs = await page.evaluate(() => appState.avtData.map((a) =>
      needsRecount(scoreSeverity({ varianceValue: a.varianceValue, variance: a.variance, variancePct: a.variancePct, category: a.category, weeksActive: 0 }))));
    expect(sevs).toEqual([true, true, true]);
    const row = stats(page).locator('.stat-row', { hasText: 'Flagged for recount' });
    await expect(row.locator('.stat-value')).toHaveText('1');
  });

  test('the filter chip says what it shows', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => showPage('variance'));
    await expect(page.locator('.mode-btn[data-vf="critical"]')).toHaveText('Crit + High');
    await page.evaluate(() => showPage('variance'));
    await expect(stats(page).locator('.stat-label', { hasText: 'Critical + High' })).toBeVisible();
  });
});
