/* v2.09 offline counting: a count made without internet is accepted and saved
   locally, parked in the durable retry queue, and uploaded on reconnect --
   into the audit it was counted in, with the counter's latest qty, never as a
   ghost of something they removed. Closing is refused while this phone still
   holds unuploaded count changes. (Pre-v2.09 the count was REFUSED offline
   with "Disconnected" and nothing was ever queued.) */
const { test, expect, startAuditAs, addManual, tapPlus, qtyOf } = require('../fixtures');

const goOffline = (page) => page.evaluate(() => {
  Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false });
  window.dispatchEvent(new Event('offline'));
});
const goOnline = (page) => page.evaluate(() => {
  Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => true });
  window.dispatchEvent(new Event('online'));
});
const queueFor = (page, name) => page.evaluate((n) =>
  pendingMutations
    .filter((op) => op.kind === 'entry-sync' && op.args && op.args.entry && op.args.entry.name === n)
    .map((op) => ({ live: op.args.live, auditId: op.args.auditId, zone: op.args.zone })), name);
const liveEntry = (page, name) => page.evaluate((n) => {
  for (const zone of Object.keys(appState.audit.counts)) {
    const hit = appState.audit.counts[zone].find((e) => e.name === n);
    if (hit) return { qty: hit.qty, supabaseId: hit.supabaseId || null, zone };
  }
  return null;
}, name);

test.describe('v2.09 offline counting', () => {
  test('a count made offline is accepted, queued durably, and uploads on reconnect with the live qty', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const auditId = db.t.kount_audits[0].id;
    await goOffline(page);

    // Counting works offline: the card appears with its qty.
    await addManual(page, 'Belvedere 1L', 3);
    expect(await qtyOf(page, 'Belvedere 1L')).toBe(3);

    // Nothing reached the server, but the insert is parked -- bound to this
    // audit and to the live card -- and persisted so a reload can't lose it.
    expect(db.t.kount_entries.filter((r) => r.item_name === 'Belvedere 1L').length).toBe(0);
    const q1 = await queueFor(page, 'Belvedere 1L');
    expect(q1.length).toBe(1);
    expect(q1[0]).toEqual({ live: true, auditId, zone: expect.any(String) });
    const persisted = await page.evaluate(() => localStorage.getItem('hwood_pending_mutations_v1') || '');
    expect(persisted).toContain('Belvedere 1L');

    // The banner tells the truth now.
    await expect(page.locator('#auditOfflineBanner')).toContainText(/Offline .* keep counting/i);

    // An offline +1 on the still-unsynced card must not be lost either.
    await tapPlus(page, 'Belvedere 1L');
    expect(await qtyOf(page, 'Belvedere 1L')).toBe(4);
    expect(db.t.kount_entries.length).toBe(0);

    // Reconnect: the queue drains into ONE server row carrying the live qty,
    // the live card is stamped with its server id, and the banner clears.
    await goOnline(page);
    await expect.poll(() => db.t.kount_entries.filter((r) => r.item_name === 'Belvedere 1L').length).toBe(1);
    const row = db.t.kount_entries.find((r) => r.item_name === 'Belvedere 1L');
    expect(Number(row.qty)).toBe(4);
    expect(row.audit_id).toBe(auditId);
    await expect.poll(async () => (await liveEntry(page, 'Belvedere 1L')).supabaseId).toBe(row.id);
    await expect.poll(() => page.evaluate(() => pendingMutations.length)).toBe(0);
    await expect(page.locator('#auditOfflineBanner')).toHaveCount(0);
  });

  test('a count removed while still offline never uploads (no ghost row)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await goOffline(page);

    await addManual(page, 'Ghost Vodka', 2);
    expect((await queueFor(page, 'Ghost Vodka')).length).toBe(1);

    // Take it to zero -> "Remove from count?" -> confirm.
    await page.evaluate(() => {
      const it = appState.audit.counts[appState.currentZone].find((e) => e.name === 'Ghost Vodka');
      window.adjustQuantity(it.id, -2);
    });
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    expect(await liveEntry(page, 'Ghost Vodka')).toBeNull();

    await goOnline(page);
    await expect.poll(() => page.evaluate(() => pendingMutations.length)).toBe(0);
    expect(db.t.kount_entries.some((r) => r.item_name === 'Ghost Vodka')).toBe(false);
  });

  test('a queued count replays into the audit it was made in, even after the phone moved on', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const auditId = db.t.kount_audits[0].id;
    await goOffline(page);
    await addManual(page, 'Stray Rum', 1);
    expect((await queueFor(page, 'Stray Rum'))[0].auditId).toBe(auditId);

    // The phone is now looking at a different audit when the network returns.
    await page.evaluate(() => { appState.audit.supabaseId = 'some-other-audit'; });
    await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => true }); });
    await page.evaluate(() => window.replayPendingMutations());

    await expect.poll(() => db.t.kount_entries.filter((r) => r.item_name === 'Stray Rum').length).toBe(1);
    expect(db.t.kount_entries.find((r) => r.item_name === 'Stray Rum').audit_id).toBe(auditId);
    await expect.poll(() => page.evaluate(() => pendingMutations.length)).toBe(0);
  });

  test('Close Count 1 is refused while this phone still has unuploaded counts, then proceeds once drained', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await goOffline(page);
    await addManual(page, 'Gate Gin', 1);

    await page.evaluate(() => window.closeCount1());
    await expect(page.locator('.toast')).toContainText(/still need to upload/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();
    expect(db.t.kount_audits[0].count_phase || 'count1').toBe('count1');

    await goOnline(page);
    await expect.poll(() => page.evaluate(() => pendingMutations.length)).toBe(0);
    await page.evaluate(() => window.closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
  });

  test('an expired-session 401 is retryable (token refresh), other 4xx still are not', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(() => ({
      e401: isRetryableError(new Error('HTTP 401: JWT expired')),
      e403: isRetryableError(new Error('HTTP 403: row-level security')),
      e404: isRetryableError(new Error('HTTP 404: Not Found')),
      net: isRetryableError(new TypeError('Failed to fetch')),
    }));
    expect(r).toEqual({ e401: true, e403: false, e404: false, net: true });
  });
});
