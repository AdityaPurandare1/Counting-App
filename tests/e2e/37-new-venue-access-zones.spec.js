/* Repro: an existing counter is given access to a NEW venue — are all of that
   venue's zones visible?

   Little Luck keeps 7 of its 8 zones as counter-added rows (kount_venue_zones);
   only "Bar" is an admin default. A phone that has never opened the venue has
   none of those cached, so everything rides on the zone load after the pick. */
const { test, expect, loginAs, waitForCatalog, settleStartupToast } = require('../fixtures');

const tabs = (page) => page.$$eval('.zone-tab[data-zone]', (els) => els.map((e) => e.dataset.zone));

function seedLittleLuck(db) {
  db.t.kount_venues.push({ id: 'v-luck', name: 'Little Luck', address: 'LA', ordinal: 2, is_active: true,
    default_zones: ['Bar'], store_aliases: [] });
  for (const z of ['Wine Room', 'Cellar', 'Back Bar']) {
    db.t.kount_venue_zones.push({ id: 'z-' + z, venue_id: 'v-luck', zone_name: z,
      created_by: 'manager@hwood.com', created_at: '2026-10-18T04:27:08Z' });
  }
}

async function grant(page, db, email, venueId) {
  db.t.app_users.find((u) => u.email === email).venue_ids.push(venueId);
  // What the app_users realtime event runs on the phone.
  await page.evaluate(() => loadAppUsersFromSupabase());
}

async function startAt(page, venueName) {
  await page.evaluate(() => showPage('venues'));
  await page.getByText(venueName).first().click();
  await page.locator('#preAuditScreen').waitFor({ state: 'visible' });
  await page.getByRole('button', { name: /^Start audit/i }).click();
  await page.locator('#activeAuditContent').waitFor({ state: 'visible' });
  const gotIt = page.getByRole('button', { name: /^Got it/i });
  if (await gotIt.isVisible().catch(() => false)) await gotIt.click();
  await waitForCatalog(page);
  await settleStartupToast(page);
}

test.describe('new venue access: zones', () => {
  test('granted while signed in, then picks the venue and starts a count', async ({ page, db }) => {
    seedLittleLuck(db);
    await loginAs(page, 'manager');
    await grant(page, db, 'manager@hwood.com', 'v-luck');
    await startAt(page, 'Little Luck');
    await expect.poll(() => tabs(page), { timeout: 5000 }).toEqual(expect.arrayContaining(['Bar', 'Wine Room', 'Cellar', 'Back Bar']));
  });

  test('granted, app reopened, then picks the venue', async ({ page, db }) => {
    seedLittleLuck(db);
    await loginAs(page, 'manager');
    await grant(page, db, 'manager@hwood.com', 'v-luck');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.locator('#page-login').waitFor({ state: 'visible' }).catch(() => {});
    if (await page.locator('#page-login').isVisible()) await loginAs(page, 'manager');
    await startAt(page, 'Little Luck');
    await expect.poll(() => tabs(page), { timeout: 5000 }).toEqual(expect.arrayContaining(['Bar', 'Wine Room', 'Cellar', 'Back Bar']));
  });

  test('a counter granted the venue joins a running count there', async ({ page, db }) => {
    seedLittleLuck(db);
    db.t.app_users.find((u) => u.email === 'manager@hwood.com').venue_ids.push('v-luck');
    await loginAs(page, 'manager');
    await startAt(page, 'Little Luck');
    const code = await page.evaluate(() => appState.audit.joinCode);
    expect(code).toBeTruthy();

    // Same phone hands over to the counter, who is granted Little Luck after signing in.
    await page.evaluate(() => { appState.audit = null; saveState(); return handleLogout(); });
    await loginAs(page, 'counter');
    await grant(page, db, 'counter@hwood.com', 'v-luck');
    await page.evaluate(() => showPage('venues'));
    await page.getByText('Little Luck').first().click();
    await page.locator('#preAuditScreen').waitFor({ state: 'visible' });
    await page.getByRole('button', { name: /^Join audit/i }).click();
    await page.locator('#joinAuditCodeInput').waitFor({ state: 'visible' });
    await page.fill('#joinAuditCodeInput', code);
    await page.getByRole('button', { name: /^Join$/ }).click();
    await page.locator('#activeAuditContent').waitFor({ state: 'visible' });
    await expect.poll(() => tabs(page), { timeout: 5000 }).toEqual(expect.arrayContaining(['Bar', 'Wine Room', 'Cellar', 'Back Bar']));
  });
});
