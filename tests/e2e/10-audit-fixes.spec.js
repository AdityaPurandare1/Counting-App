/* v1.62 audit-fix safety net:
     - closeCount2 strict gate RESTORED: every recount row needs a decision,
       a non-blank reason, and a numeric recountQty — hard block, no bypass.
     - closeCount1 is manager/corporate-only (counter button hidden + the
       function itself refuses for a counter with a stale tab).
     - client_entry_id idempotent replay: re-sending an insert whose response
       was lost adopts the committed row instead of double-merging qty. */
const { test, expect, startAuditAs, loginAs, addManual } = require('../fixtures');

test.describe('v1.62 audit fixes', () => {
  test('strict closeCount2 blocks while a recount row lacks decision / reason / qty', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);

    // Close Count 1 → review (generates pending recount rows, no AVT).
    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // 1) No decision yet → hard toast, no confirm dialog, nothing submitted.
    await page.evaluate(() => window.closeCount2());
    await expect(page.locator('.toast')).toContainText(/still need a recount decision/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();

    // 2) Decision present but reason blank → still blocked.
    await page.evaluate(() => {
      Object.values(appState.audit.recounts).forEach((r) => { r.auditResult = 'verified'; });
      window.closeCount2();
    });
    await expect(page.locator('.toast')).toContainText(/missing a reason/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();

    // 3) Reason present but recountQty missing → still blocked.
    await page.evaluate(() => {
      Object.values(appState.audit.recounts).forEach((r) => { r.auditReason = 'verified on shelf'; });
      window.closeCount2();
    });
    await expect(page.locator('.toast')).toContainText(/missing a recount quantity/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();

    // Through all three blocks the audit never advanced.
    expect(db.t.kount_audits[0].status).toBe('active');
    expect(db.t.kount_audits[0].count_phase).toBe('review');

    // 4) Fully complete rows → the close confirm finally appears.
    await page.evaluate(() => {
      Object.values(appState.audit.recounts).forEach((r) => {
        r.recountQty = r.count1Qty != null ? r.count1Qty : 0;
        r.status = 'done';
      });
      window.closeCount2();
    });
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
  });

  test('a counter cannot close Count 1 (button hidden + function refuses)', async ({ page, db }) => {
    // Manager starts the audit and counts something, so the only thing
    // standing between the counter and a phase flip is the role gate.
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits.length).toBe(1);
    const code = db.t.kount_audits[0].join_code;

    // Counter joins by code.
    await loginAs(page, 'counter');
    await page.getByText('Delilah LA').first().click();
    await page.locator('#preAuditScreen').waitFor({ state: 'visible' });
    await page.getByRole('button', { name: /^Join audit/i }).click();
    await page.fill('#joinAuditCodeInput', code);
    await page.getByRole('button', { name: /^Join$/ }).click();
    await expect(page.locator('#activeAuditContent')).toBeVisible();

    // UI mirror: the Close Count 1 button is hidden for counters.
    await expect(page.locator('#closeCount1Btn')).toBeHidden();
    // v1.62: the networked-audit Cancel (end early) button is hidden too.
    await expect(page.locator('#cancelAuditBtn')).toBeHidden();

    // Defense-in-depth: calling the function directly (stale tab) refuses.
    await page.evaluate(() => window.closeCount1());
    await expect(page.locator('.toast')).toContainText(/only managers can close count 1/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();
    expect(db.t.kount_audits[0].count_phase).toBe('count1');
  });

  test('replaying an insert with the same client_entry_id adopts the row — qty not doubled', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);

    await expect.poll(() => db.t.kount_entries.filter(r => r.item_name === 'Belvedere 1L').length).toBe(1);
    const row = db.t.kount_entries.find(r => r.item_name === 'Belvedere 1L');
    expect(row.client_entry_id).toBeTruthy();
    expect(row.qty).toBe(3);

    // Simulate the lost-response replay: re-send the SAME logical insert
    // (same client_entry_id, no supabaseId — as a retry-queue snapshot
    // would) straight through syncEntryToSupabase.
    const adoptedId = await page.evaluate(async () => {
      const e = window.getAllCountedItems().find(i => i.name === 'Belvedere 1L');
      const replay = {
        id: e.id,
        clientEntryId: e.clientEntryId || e.id,
        name: e.name, category: e.category, qty: e.qty,
        method: e.method, masterId: e.masterId, timestamp: e.timestamp,
      };
      const res = await syncEntryToSupabase(replay, e.zone);
      return replay.supabaseId || (res && res.id) || null;
    });

    // Still ONE row, qty untouched, and the replay adopted the committed row.
    const rows = db.t.kount_entries.filter(r => r.item_name === 'Belvedere 1L');
    expect(rows.length).toBe(1);
    expect(rows[0].qty).toBe(3);
    expect(adoptedId).toBe(rows[0].id);
  });

  test('zone-move replay colliding on the client key adopts the committed row instead of dropping', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);

    await expect.poll(() => db.t.kount_entries.filter(r => r.item_name === 'Belvedere 1L').length).toBe(1);
    const committed = db.t.kount_entries.find(r => r.item_name === 'Belvedere 1L');

    // Replay the same logical insert into a DIFFERENT zone — the shape a
    // queued move-zone re-insert has once the committed row's zone no longer
    // matches the snapshot. The merge key (zone+name) misses, so the 23505
    // is on kount_entries_client_key; the handler must look up by
    // (audit_id, client_entry_id) and adopt, not drop the move.
    const adoptedId = await page.evaluate(async () => {
      const e = window.getAllCountedItems().find(i => i.name === 'Belvedere 1L');
      const replay = {
        id: e.id,
        clientEntryId: e.clientEntryId || e.id,
        name: e.name, category: e.category, qty: e.qty,
        method: e.method, masterId: e.masterId, timestamp: e.timestamp,
      };
      const res = await syncEntryToSupabase(replay, 'Replay Target Zone');
      return replay.supabaseId || (res && res.id) || null;
    });

    // Still ONE row, qty untouched (no merge), and the replay adopted it.
    const rows = db.t.kount_entries.filter(r => r.item_name === 'Belvedere 1L');
    expect(rows.length).toBe(1);
    expect(rows[0].qty).toBe(3);
    expect(adoptedId).toBe(committed.id);
  });
});
