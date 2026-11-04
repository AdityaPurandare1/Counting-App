// v2.32 — per-person permissions on the phone (0148). Every role's template gives the same answers as the old
// role checks; a person's own list wins over their role; and the approved fixes: an admin sees every venue,
// creates catalog items, approves barcodes and finalizes from Count 1 (the old checks said 'corporate').
const { test, expect, startAuditAs } = require('../fixtures');

test.describe('v2.32 permissions', () => {
  test('each role\'s template answers every gate as the old role checks did (admin: the approved fixes)', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(() => {
      const out = {};
      for (const role of ['admin', 'corporate', 'manager', 'venue_manager', 'counter']) {
        appState.user.role = role; appState.user.features = PHONE_ROLE_TEMPLATES[role];
        out[role] = [isManagerRole(role), canApproveUpcs(), isCorporateUser(), isCountReadOnly(), userCan('audit:manage'), userCan('team:issues'),
          rowVenueIds({ role, venue_ids: ['v1'] })];
      }
      appState.user.role = 'manager'; appState.user.features = PHONE_ROLE_TEMPLATES.manager;
      return out;
    });
    //                 run    approve catalog read-only finalize issues  venues
    expect(r.admin).toEqual([true, true, true, false, true, true, 'all']);
    expect(r.corporate).toEqual([true, true, true, false, true, true, 'all']);
    expect(r.manager).toEqual([true, true, false, false, false, true, ['v1']]);
    expect(r.venue_manager).toEqual([false, false, false, true, false, true, ['v1']]);
    expect(r.counter).toEqual([false, false, false, false, false, false, ['v1']]);
  });

  test('a person\'s own permissions win over their role; a row from before 0148 falls back to its role', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(() => {
      const out = [];
      appState.user.role = 'manager'; appState.user.features = ['phone:count'];           // a manager who may only count
      out.push(isManagerRole('manager'), isCountReadOnly());
      appState.user.role = 'corporate'; appState.user.features = [];                      // corporate with nothing ticked
      out.push(isCountReadOnly(), rowVenueIds(appState.user));
      appState.user.role = 'counter'; delete appState.user.features;                     // saved before v2.32
      out.push(isCountReadOnly(), isManagerRole('counter'));
      appState.user.role = 'manager'; appState.user.features = PHONE_ROLE_TEMPLATES.manager;
      return out;
    });
    expect(r).toEqual([false, false, true, [], false, false]);
  });
});
