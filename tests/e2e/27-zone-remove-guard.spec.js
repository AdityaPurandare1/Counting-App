/* v2.12 — a zone holding counts in the live audit cannot be removed
   (from hursh-dev v1.99, d263442, narrowed).

   Removing a zone hides its counts from every on-screen total, and recounting
   the same bottles under another zone then reads as new stock. The branch
   blocked ALL removal during an audit; but the phone only shows zone
   management during an audit, so that also blocked deleting a typo zone added
   a minute ago. The guard is therefore scoped to zones that hold counts.

   confirm() is stubbed to return false so the "allowed" case stops at the
   prompt — reaching it is the proof the guard let it through.

   FAIL-BEFORE: the zone with counts reached confirm() (and, confirmed, was
   spliced out of venue.zones). */
const { test, expect } = require('../fixtures');

test.describe('v2.12 zone removal guard', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.removeCustomZone)).toBe('function');
  });

  const run = (page, zone) => page.evaluate(async (zoneName) => {
    const toasts = [];
    let prompted = false;
    const origToast = window.showToast;
    const origConfirm = window.confirm;
    window.showToast = (msg, kind) => { toasts.push({ msg, kind }); };
    window.confirm = () => { prompted = true; return false; };
    const saved = { user: appState.user, venue: appState.currentVenue, audit: appState.audit };
    try {
      appState.user = { email: 'gm@test', role: 'manager' };
      appState.currentVenue = { id: 'vt', zones: ['Main Bar', 'Back Bar', 'Typo Zone'], _defaultZones: ['Main Bar'] };
      appState.audit = { counts: { 'Back Bar': [{ name: 'Probe', qty: 2 }], 'Typo Zone': [] } };
      await window.removeCustomZone(zoneName);
      return { toasts, prompted, zones: appState.currentVenue.zones.slice() };
    } finally {
      appState.user = saved.user; appState.currentVenue = saved.venue; appState.audit = saved.audit;
      window.showToast = origToast; window.confirm = origConfirm;
    }
  }, zone);

  test('a zone with counts in the live audit is refused before any prompt', async ({ page }) => {
    const r = await run(page, 'Back Bar');
    expect(r.prompted).toBe(false);
    expect(r.zones).toContain('Back Bar');
    expect(r.toasts.map(t => t.msg).join(' ')).toMatch(/has counts in this audit/);
  });

  test('an empty zone can still be removed mid-audit (reaches the confirm)', async ({ page }) => {
    const r = await run(page, 'Typo Zone');
    expect(r.prompted).toBe(true);
    expect(r.toasts.map(t => t.msg).join(' ')).not.toMatch(/has counts/);
  });

  test('default zones stay protected regardless', async ({ page }) => {
    const r = await run(page, 'Main Bar');
    expect(r.prompted).toBe(false);
    expect(r.toasts.map(t => t.msg).join(' ')).toMatch(/default zone/);
  });
});
