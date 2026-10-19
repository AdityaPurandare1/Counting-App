/* v2.21 — counter-added zones must survive a venue-list reload.

   Little Luck, 10/19, LL-038: Jonathan's phone stopped showing "Wine Room"
   (and the other zones counters had added) mid-count while Alexa's still
   showed them, so he created a second "Wine room".

   Root cause: loadVenuesFromSupabase rebuilt every venue with zones = the
   admin's default_zones only, dropping the counter-added kount_venue_zones.
   It runs on ANY kount_venues change (realtime), on every offline->online
   flip, and on session restore -- so whichever phones happened to hit one of
   those lost the zones, and the others did not. */
const { test, expect, startAuditAs, switchZone, addManual } = require('../fixtures');

const tabs = (page) => page.$$eval('.zone-tab[data-zone]', (els) => els.map((e) => e.dataset.zone));

async function seedCustomZone(db, name) {
  db.t.kount_venue_zones.push({ id: 'z-' + name, venue_id: 'v-delilah', zone_name: name,
    created_by: 'manager@hwood.com', created_at: '2026-10-18T04:27:08Z' });
}

test.describe('v2.21 zones survive a venue reload', () => {
  test('a counter-added zone is still there after the venue list reloads', async ({ page, db }) => {
    await seedCustomZone(db, 'Wine Room');
    await startAuditAs(page, 'manager');
    await expect.poll(() => tabs(page)).toContain('Wine Room');

    // What an admin venue edit (realtime) or coming back online triggers.
    await page.evaluate(() => loadVenuesFromSupabase());
    await page.evaluate(() => renderCountPage());
    expect(await tabs(page)).toContain('Wine Room');
    expect(await page.evaluate(() => appState.currentVenue.zones)).toContain('Wine Room');
  });

  test('coming back online does not hide counter-added zones', async ({ page, db }) => {
    await seedCustomZone(db, 'Walk-in cooler');
    await startAuditAs(page, 'manager');
    await expect.poll(() => tabs(page)).toContain('Walk-in cooler');

    await page.evaluate(() => {
      Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false });
      window.dispatchEvent(new Event('offline'));
      Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => true });
      window.dispatchEvent(new Event('online'));
    });
    // Give the online handler's venue reload time to land, then re-render.
    await page.waitForTimeout(800);
    await page.evaluate(() => renderCountPage());
    expect(await tabs(page)).toContain('Walk-in cooler');
  });

  test('a zone another phone added while realtime was down appears on the next reload', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    expect(await tabs(page)).not.toContain('Basement Fridge');
    // Added on the server; this phone never got the realtime INSERT.
    await seedCustomZone(db, 'Basement Fridge');
    await page.evaluate(() => loadVenuesFromSupabase());
    await expect.poll(() => tabs(page)).toContain('Basement Fridge');
  });

  test('an admin-removed default zone disappears, unless it holds counts in the live audit', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Bar');
    await addManual(page, 'Belvedere 1L', 2);
    await expect.poll(() => page.evaluate(() => (appState.audit.counts['Bar'] || []).length)).toBe(1);

    // Admin removes BOTH "Bar" (has a count) and "Service Well" (empty).
    db.t.kount_venues[0].default_zones = ['Liquor Room'];
    await page.evaluate(() => loadVenuesFromSupabase());
    await page.evaluate(() => renderCountPage());
    const z = await tabs(page);
    expect(z).toContain('Bar');               // its count must stay visible
    expect(z).not.toContain('Service Well');  // nothing in it: the removal applies
    expect(z).toContain('Liquor Room');
  });
});
