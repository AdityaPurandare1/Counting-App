/* v1.98 BUG 2 — 23505 collision + 0-row lookup no longer silently drops a
   count (counting-app.html ~6389/6432).

   When an INSERT collides on the merge unique index (23505) but the follow-up
   SELECT for the colliding row comes back EMPTY (concurrent delete / read-
   replica lag / an item_name the ilike filter didn't line up with), the old
   code left `lastError` as the raw 23505 → isRetryableError said NON-retryable
   → the count was SILENTLY DROPPED. The fix swaps in a retryable marker
   ('entry-collision-unresolved: …') so the count is RE-ENQUEUED and a later
   replay re-inserts once the row is truly gone / re-collides+merges once it's
   visible — bounded by ENTRY_SYNC_MAX_ATTEMPTS so a never-healing op can't spin
   or block the FIFO queue forever.

   The mock's ghostEntryNames hook reproduces the exact race: the primary's
   unique index rejects the insert (23505) but nothing is persisted, so the
   caller's re-read finds 0 rows.

   FAIL-BEFORE: with the marker reverted, lastError stays 23505 → the count is
   dropped, NOTHING is enqueued, and it never persists on replay. */
const { test, expect, startAuditAs } = require('../fixtures');

// Drive one direct sync of a fresh entry (bypasses the modal so we can inject a
// deterministic clientEntryId). syncEntryToSupabase is a global.
async function syncOne(page, name, qty) {
  return page.evaluate(async ({ name, qty }) => {
    const entry = {
      id: 'Ecollide_' + name.replace(/\W/g, ''),
      clientEntryId: 'Ecollide_' + name.replace(/\W/g, ''),
      name: name, category: 'Liquor Cost', qty: qty, method: 'manual', masterId: null,
    };
    const res = await window.syncEntryToSupabase(entry, 'Bar', {});
    return res; // null on a queued/dropped failure
  }, { name, qty });
}

test.describe('v1.98 collision-replay (count is not lost)', () => {
  test('23505 with an empty lookup RE-ENQUEUES and eventually persists on replay', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const auditId = db.t.kount_audits[0].id;

    // The first insert for this item collides on the primary but reads back 0 rows.
    db.ghostEntryNames.add('ghosty gin 750ml');

    const res = await syncOne(page, 'Ghosty Gin 750ml', 4);
    expect(res).toBeNull(); // failed this attempt

    // NOT dropped: the count survives as a queued entry-sync op...
    const queued = await page.evaluate(() =>
      pendingMutations.filter((op) => op.kind === 'entry-sync' && /Ghosty Gin/.test(op.label || '')));
    expect(queued.length).toBe(1);
    // ...and it did NOT persist yet.
    expect(db.t.kount_entries.some((e) => e.item_name === 'Ghosty Gin 750ml')).toBe(false);

    // The colliding row becomes visible/gone — the ghost clears. A replay now
    // re-inserts successfully and the count is preserved (not lost).
    db.ghostEntryNames.clear();
    await page.evaluate(() => replayPendingMutations());

    await expect
      .poll(() => db.t.kount_entries.filter((e) => e.item_name === 'Ghosty Gin 750ml' && e.audit_id === auditId).length)
      .toBe(1);
    const row = db.t.kount_entries.find((e) => e.item_name === 'Ghosty Gin 750ml');
    expect(Number(row.qty)).toBe(4);
    // Queue drains once the op succeeds.
    await expect
      .poll(() => page.evaluate(() => pendingMutations.filter((op) => /Ghosty Gin/.test(op.label || '')).length))
      .toBe(0);
  });

  test('a perpetually-colliding op is DROPPED after the cap, not left blocking the queue', async ({ page, db }) => {
    await startAuditAs(page, 'manager');

    // This item collides forever (ghost never cleared) — the pathological
    // never-heals case. It must be bounded, not spin/block indefinitely.
    db.ghostEntryNames.add('zombie rum 750ml');

    const res = await syncOne(page, 'Zombie Rum 750ml', 2);
    expect(res).toBeNull();
    // It is queued (retryable marker), so far so good.
    expect(await page.evaluate(() =>
      pendingMutations.filter((op) => /Zombie Rum/.test(op.label || '')).length)).toBe(1);

    // Replay drives the entry-sync through its bounded re-enqueue cycle. It must
    // terminate (drop after ENTRY_SYNC_MAX_ATTEMPTS) rather than hang.
    await page.evaluate(() => replayPendingMutations());

    await expect
      .poll(() => page.evaluate(() => pendingMutations.filter((op) => /Zombie Rum/.test(op.label || '')).length),
        { timeout: 15000 })
      .toBe(0);
    // Bounded outcome: the never-healing count is dropped (surfaced), and it
    // never wrongly persisted a phantom row.
    expect(db.t.kount_entries.some((e) => e.item_name === 'Zombie Rum 750ml')).toBe(false);

    // Crucially, the queue is NOT wedged: a healthy op behind it still syncs.
    db.ghostEntryNames.clear();
    const ok = await syncOne(page, 'Healthy Whiskey 750ml', 3);
    expect(ok).not.toBeNull();
    expect(db.t.kount_entries.some((e) => e.item_name === 'Healthy Whiskey 750ml')).toBe(true);
  });
});
