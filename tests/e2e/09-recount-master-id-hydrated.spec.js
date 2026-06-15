const { test, expect, startAuditAs, M } = require('../fixtures');

/* M1 regression (HYDRATED path): kount_recounts.master_item_id survives a
 * Supabase round-trip.
 *
 * 08-recount-master-id.spec.js proves the SAME-SESSION path: count a catalog
 * item locally → closeCount1 → the derived recount row carries the master id.
 * In that path the in-memory entry never lost its masterId, so it can't catch
 * the bug fixed here.
 *
 * THE BUG: entryFromSupabaseRow() (and the audit-rejoin loader) mapped masterId
 * from the legacy `item_id` column — which the current app always writes null —
 * instead of `master_item_id`. So any entry HYDRATED from Supabase (reload /
 * rejoin / a second device's realtime INSERT) came back with masterId: null.
 * Then closeCount1's all-counted-items branch read that null masterId, and
 * syncRecountsToSupabase wrote kount_recounts.master_item_id = null even though
 * the entry's own DB row had a perfectly good master_item_id.
 *
 * THE FIX: masterId: row.master_item_id ?? row.item_id  (counting-app.html:5175,
 * and the rejoin loader at ~11876).
 *
 * WHY THE REALTIME-MERGE PATH (not join-by-code or reload):
 *   - onAuditEntryRealtime → mergeRemoteEntryIntoLocal → entryFromSupabaseRow
 *     (counting-app.html:5491/5499/5516) calls the EXACT fixed function on a row
 *     whose item_id is null and master_item_id is set — i.e. the hydration the
 *     bug lived in.
 *   - It keeps a MANAGER in control of the session. closeCount1 is gated to
 *     manager/corporate (renderCountPage ~6853), so a counter who joins by code
 *     could hydrate the entry but could not close Count 1. Driving the realtime
 *     INSERT into the manager's own session lets the same persona both hydrate
 *     the foreign entry and close the count — no second persona / phase juggling.
 *   - It exercises the identical entryFromSupabaseRow mapping that the
 *     join-by-code loader (line 4934) and reload hydrator use, so it is a
 *     faithful stand-in for "entry came from the DB, not from this session".
 */
test.describe('M1: kount_recounts.master_item_id (hydrated entry)', () => {
  test('a recount row derived from a Supabase-HYDRATED entry carries the master id (not null)', async ({ page, db }) => {
    // Manager starts a real networked audit (creates the kount_audits row +
    // appState.audit.supabaseId, and is authorized to close Count 1).
    await startAuditAs(page, 'manager');

    // The manager's networked-start inserts exactly one kount_audits row; its id
    // is appState.audit.supabaseId. (appState is a module const, not a window
    // global, so we read the id from the mock DB — same value, Node side.)
    await expect.poll(() => db.t.kount_audits.length).toBe(1);
    const auditId = db.t.kount_audits[0].id;
    expect(auditId, 'the manager audit must have a Supabase id').toBeTruthy();

    // Seed a kount_entries row EXACTLY as the current app writes it: the master
    // id lives in master_item_id, and the legacy item_id column is null. This is
    // an entry that exists in the DB but was NOT counted in this browser session
    // (think: a teammate's phone, or this phone before a reload). Insert through
    // the real REST mock so FK/NOT-NULL constraints apply, proving the row is
    // a valid, app-shaped row.
    const seededRow = {
      audit_id: auditId,
      zone: 'Bar',
      item_name: 'Belvedere 1L',
      category: 'Liquor Cost',
      qty: 4,
      sku: null,
      issue: 'none',
      issue_notes: null,
      photo_id: null,
      item_id: null,            // legacy purchase_items FK — always null now
      master_item_id: M.belv,   // the real id lives here (Path B)
      method: 'manual',
      counted_by_email: 'counter@hwood.com',
      counted_by_name: 'Casey',
      timestamp: '2026-05-27T10:00:00Z',
      is_recount: false,
    };
    const ins = db.insert('kount_entries', {}, seededRow);
    expect(ins.status, 'the app-shaped row must insert cleanly (item_id null + master_item_id set)').toBe(201);
    const dbRow = ins.body[0];
    // Sanity: the row in the DB is shaped like the bug requires (this is what
    // distinguishes the hydrated path from the same-session path).
    expect(dbRow.item_id).toBeNull();
    expect(dbRow.master_item_id).toBe(M.belv);

    // HYDRATE it into the running app via the realtime-merge path — the same
    // entryFromSupabaseRow mapping a reload / rejoin / second device would use.
    // (eventType INSERT, evt.new = the DB row, with the audit_id matching the
    // active audit so mergeRemoteEntryIntoLocal accepts it.)
    await page.evaluate((row) => {
      window.onAuditEntryRealtime({ eventType: 'INSERT', new: row });
    }, dbRow);

    // The hydrated entry is now in local state. PRE-FIX this masterId would be
    // null (mapped from the null item_id); POST-FIX it is M.belv. This is the
    // load-bearing intermediate assertion that pins the fix at its source.
    const hydrated = await page.evaluate(() =>
      window.getAllCountedItems().find(i => i.name === 'Belvedere 1L') || null);
    expect(hydrated, 'the realtime INSERT must hydrate the entry into local state').toBeTruthy();
    expect(hydrated.qty).toBe(4);
    expect(hydrated.masterId,
      'PRE-FIX this is null (masterId came from the null item_id); the fix maps it from master_item_id'
    ).toBe(M.belv);

    // v1.70: closeCount1 normally computes variance (AVT rows carry null
    // masterId). The all-counted-items branch — which preserves the hydrated
    // entry's masterId — fires when compute can't run, so go offline to take it.
    // (syncRecountsToSupabase still reaches the in-process mock.)
    await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false }); });

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits.find(a => a.id === auditId).count_phase).toBe('review');

    // Recount rows are synced fire-and-forget after closeCount1 confirms.
    await expect.poll(() => db.t.kount_recounts.length).toBeGreaterThan(0);

    const recount = db.t.kount_recounts.find(r => r.item_name === 'Belvedere 1L');
    expect(recount, 'a recount row for the hydrated catalog item must exist').toBeTruthy();

    // THE REGRESSION ASSERTION. Pre-fix the hydrated entry's masterId was null,
    // so this synced row's master_item_id came out null even though the entry's
    // own DB row (dbRow above) had master_item_id = M.belv. The fix makes the
    // synced recount row carry the real master id.
    expect(recount.master_item_id,
      'the synced recount row must carry the hydrated entry\'s master id, not null'
    ).toBe(M.belv);
    // And the master id must never leak into the legacy purchase_items FK column.
    expect(recount.item_id).toBeNull();
  });
});
