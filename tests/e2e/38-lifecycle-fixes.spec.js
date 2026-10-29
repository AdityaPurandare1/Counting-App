/* Audit lifecycle / recount / multi-device sync / summary fixes (review batch,
 * 2026-10-28). One focused test per finding where the mock can drive it.
 *
 * Seeding mirrors 24-recount-location-move: the mock's compute_avt_for_audit
 * flags Belvedere 1L HIGH (actual 1 vs theo 6, -5 bottles), so counting it in
 * zones and closing Count 1 yields one recount row per zone. The mock has no
 * realtime, so "another device" is simulated by writing to db.t directly and
 * driving the poll (reconcileAuditEntries) or the merge path by hand.
 */
const { test, expect, startAuditAs, joinAuditAs, addManual, switchZone, M } = require('../fixtures');

const ITEM = 'Belvedere 1L';

async function addItem(page, zone, name, qty) {
  await addManual(page, name, qty);
  const picker = page.locator('#fuzzyMatchPickerModal');
  if (await picker.isVisible().catch(() => false)) {
    const exact = picker.locator('.fuzzy-pick', { hasText: name }).first();
    await (await exact.count() ? exact : picker.locator('.fuzzy-pick').first()).click();
    await picker.waitFor({ state: 'hidden' });
  }
  await expect
    .poll(() => page.evaluate((z) => (((appState.audit || {}).counts || {})[z] || []).length, zone))
    .toBeGreaterThan(0);
}

/* Count ITEM per zone, close Count 1, wait until the recount list is on the
   server (bulk upload landed). Leaves the audit in count_phase 'review'. */
async function seedRecount(page, db, perZone) {
  for (const [zone, qty] of perZone) {
    await switchZone(page, zone);
    await addItem(page, zone, ITEM, qty);
  }
  await page.evaluate(() => closeCount1());
  await page.locator('#confirmDialog').waitFor({ state: 'visible' });
  await page.evaluate(() => window.closeConfirm(true));
  await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
  await expect.poll(() => db.t.kount_recounts.filter((r) => r.item_name === ITEM).length, { timeout: 5000 })
    .toBe(perZone.length);
  await expect.poll(() => page.evaluate(() => !!appState.audit._recountListPending)).toBe(false);
}

const keyFor = (zone) => ITEM + '|' + zone;

async function recordRecount(page, key, { qty, result, reason, zone }) {
  await page.evaluate((k) => openRecountEntry(k), key);
  await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
  if (zone) await page.selectOption('#recountZoneSelect', zone);
  await page.fill('#guidedQty', String(qty));
  await page.selectOption('#recountResultSelect', result);
  await page.fill('#recountReasonInput', reason);
  await page.locator('#guidedConfirmBtn').click();
  await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
}

/* Run the reconcile poll until fn() is truthy (the poll is single-flight, so
   a call can be a no-op while the 12s timer's pass is running). */
async function pollUntil(page, fn, arg) {
  await expect.poll(async () => {
    await page.evaluate(() => reconcileAuditEntries());
    return page.evaluate(fn, arg);
  }).toBe(true);
}

/* Capture what exportCSV / exportCountCSV would download. */
async function captureCsv(page, fn) {
  return page.evaluate(async (fnSrc) => {
    let blob = null;
    const origCreate = URL.createObjectURL;
    const origClick = HTMLAnchorElement.prototype.click;
    URL.createObjectURL = (b) => { blob = b; return 'blob:test'; };
    HTMLAnchorElement.prototype.click = function () {};
    try { (0, eval)(fnSrc); } finally {
      URL.createObjectURL = origCreate;
      HTMLAnchorElement.prototype.click = origClick;
    }
    if (!blob) return null;
    const t = await blob.text();
    return t.charCodeAt(0) === 0xFEFF ? t.slice(1) : t;   // drop the Excel BOM
  }, fn);
}

test.describe('recount corrections reach the report and the totals', () => {
  test('#1/#2 a Count Corrected syncs with its master id; Summary + locked view show after-recount totals', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);

    // Every AVT-derived row carries the resolved master id (compute ignores
    // recounts without one).
    expect(db.t.kount_recounts.filter((r) => r.item_name === ITEM).map((r) => r.master_item_id))
      .toEqual([M.belv, M.belv]);

    await recordRecount(page, keyFor('Liquor Room'), { qty: 4, result: 'corrected', reason: 'found one more' });
    await expect.poll(() => (db.t.kount_recounts.find((r) => r.item_name === ITEM && r.zone === 'Liquor Room') || {}).count2_qty).toBe(4);
    const row = db.t.kount_recounts.find((r) => r.item_name === ITEM && r.zone === 'Liquor Room');
    expect(row.master_item_id).toBe(M.belv);
    expect(row.audit_result).toBe('corrected');

    // Locked count view: 1 distinct item (two zone entries), 4 + 2 = 6.
    await page.evaluate(() => showPage('count'));
    const overlay = page.locator('#auditLockedOverlay');
    await expect(overlay).toContainText('after recount');
    const overlayStats = await overlay.locator('.stat-row').allInnerTexts();
    expect(overlayStats.find((t) => /Items counted/.test(t))).toMatch(/\b1$/);
    expect(overlayStats.find((t) => /Total quantity/.test(t))).toMatch(/\b6$/);

    // Summary: same numbers, labelled, with the Count-1 figure alongside.
    await page.evaluate(() => showPage('summary'));
    const stats = page.locator('#summaryStats');
    await expect(stats).toContainText('after recount');
    const rows = await stats.locator('.stat-row').allInnerTexts();
    expect(rows.find((t) => /Unique items/.test(t))).toMatch(/\b1$/);
    expect(rows.find((t) => /Total quantity/.test(t))).toMatch(/\b6$/);
    expect(rows.find((t) => /Count 1 quantity/.test(t))).toMatch(/\b5$/);
    await expect(page.locator('#zoneSummary')).toContainText('Liquor Room');

    // Raw CSV carries the recount next to the Count-1 row.
    const csv = await captureCsv(page, 'exportCSV()');
    const lines = csv.trim().split('\n');
    expect(lines[0]).toContain('Recount Qty,Recount Result');
    const lr = lines.find((l) => l.includes('"Liquor Room"'));
    expect(lr).toMatch(/,4,"corrected"$/);
  });

  test('#1 the AVT-name -> master resolver follows the DB rules (exact, unambiguous, no fuzzy guess)', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(({ BELV, TITOS }) => {
      const z = appState.currentZone;
      const res = {};
      // No entries: the one catalog master with that exact name (any case).
      res.catalog = findMasterIdForAvtItem({ itemName: 'belvedere 1l' });
      // A partial name would fuzzy-match, but must not resolve.
      res.fuzzy = findMasterIdForAvtItem({ itemName: 'Belvedere' });
      // This audit's entries win over the catalog...
      appState.audit.counts[z].push({ id: 'x1', name: 'House Pour', masterId: TITOS, qty: 1 });
      res.entry = findMasterIdForAvtItem({ itemName: 'House Pour' });
      // ...but two different masters under one name is ambiguous.
      appState.audit.counts[z].push({ id: 'x2', name: 'House Pour', masterId: BELV, qty: 1 });
      res.ambiguous = findMasterIdForAvtItem({ itemName: 'House Pour' });
      appState.audit.counts[z] = appState.audit.counts[z].filter((e) => e.id !== 'x1' && e.id !== 'x2');
      return res;
    }, { BELV: M.belv, TITOS: M.titos });
    expect(r).toEqual({ catalog: M.belv, fuzzy: null, entry: M.titos, ambiguous: null });
  });

  test('#12 Count 2 CSV sums the zone rows, prints a counted 0, and matches issues exactly', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);
    await recordRecount(page, keyFor('Liquor Room'), { qty: 4, result: 'corrected', reason: 'found one' });
    await recordRecount(page, keyFor('Bar'), { qty: 2, result: 'verified', reason: 'matches' });
    // A different product sharing the first word, with an issue: must not
    // be pinned on the Belvedere 1L row.
    await page.evaluate(() => {
      appState.audit.counts['Bar'].push({ id: 'Ex', name: 'Belvedere Ghost Edition', qty: 1, issue: 'damaged', masterId: null });
    });
    const csv = await captureCsv(page, 'exportCountCSV(2)');
    const lines = csv.split('\n');
    const belv = lines.find((l) => l.startsWith('"Delilah LA","Count 2","Belvedere 1L"'));
    expect(belv).toBeTruthy();
    const cells = belv.split(',');
    // ... Counted Qty (App), Severity, Needs Recount, Recount Qty, Status, Issue Type, Issue Notes
    expect(cells.slice(-4, -1)).toEqual(['6', 'Recounted', '""']);
    const titos = lines.find((l) => l.includes("Tito's Handmade Vodka 750ml"));
    // Not counted at all -> a real 0 in Counted Qty (12th..13th column).
    expect(titos.split(',')[12]).toBe('0');
  });
});

test.describe('who can lock the audit from Summary', () => {
  test('#3 a counter cannot submit a shared audit, and the button is hidden for them', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const code = db.t.kount_audits[0].join_code;
    await joinAuditAs(page, 'counter', code);

    await page.evaluate(() => showPage('summary'));
    await expect(page.locator('#summarySubmitBtn')).toBeHidden();
    await page.evaluate(() => submitAudit());
    await expect(page.locator('.toast')).toContainText(/Only managers can submit/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();
    expect(db.t.kount_audits[0].status).toBe('active');
  });

  test('#3 a manager\'s submit applies the recount gates', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3]]);
    await page.evaluate(() => { showPage('summary'); });
    await expect(page.locator('#summarySubmitBtn')).toBeVisible();
    await page.evaluate(() => submitAudit());
    await expect(page.locator('.toast')).toContainText(/still need a recount decision/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();
    expect(db.t.kount_audits[0].status).toBe('active');
  });
});

test.describe('multi-device sync', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.mergeRemoteEntryIntoLocal)).toBe('function');
  });

  test('#4 a peer\'s zone move relocates the card instead of duplicating it', async ({ page }) => {
    const out = await page.evaluate((BELV) => {
      appState.audit = {
        supabaseId: 'AUD1',
        counts: {
          Bar: [{ id: 'SRV1', supabaseId: 'SRV1', clientEntryId: 'E1', name: 'Belvedere 1L', masterId: BELV, qty: 3, isRecount: false, issue: 'none' }],
          'Liquor Room': [],
        },
      };
      // The other phone re-zoned the SAME row (UPDATE zone).
      window.mergeRemoteEntryIntoLocal({
        id: 'SRV1', audit_id: 'AUD1', zone: 'Liquor Room', item_name: 'Belvedere 1L', master_item_id: BELV,
        qty: 3, is_recount: false, issue: 'none', issue_notes: null, timestamp: '2026-10-28T00:00:00Z', client_entry_id: 'E1',
      }, 'UPDATE');
      return { bar: appState.audit.counts.Bar.length, lr: appState.audit.counts['Liquor Room'].length };
    }, M.belv);
    expect(out).toEqual({ bar: 0, lr: 1 });
  });
});

test.describe('poll + offline recovery', () => {
  test('#6/#7 the poll picks up a close this phone missed, and recount progress', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const code = db.t.kount_audits[0].join_code;
    await joinAuditAs(page, 'counter', code);
    expect(await page.evaluate(() => appState.audit.countPhase)).toBe('count1');

    // The manager closed Count 1 on another phone; no realtime event arrived.
    const audit = db.t.kount_audits[0];
    audit.count_phase = 'review';
    audit.count1_closed_at = new Date().toISOString();
    db.t.kount_recounts.push({ id: 'rc-1', audit_id: audit.id, item_name: ITEM, master_item_id: M.belv, zone: 'Bar',
      severity: 'HIGH', variance_value: -150, variance_qty: -5, count1_qty: 2, count2_qty: null, status: 'pending', created_at: '2026-10-28T00:00:00Z' });

    await pollUntil(page, () => appState.audit.countPhase === 'review');
    await expect(page.locator('#auditLockedOverlay')).toBeVisible();
    await expect.poll(() => page.evaluate(() => Object.keys(appState.audit.recounts || {}).length)).toBe(1);

    // Another counter recorded it; the next poll shows it here.
    Object.assign(db.t.kount_recounts[0], { count2_qty: 2, status: 'done', audit_result: 'verified', audit_reason: 'ok' });
    await pollUntil(page, (k) => (appState.audit.recounts[k] || {}).status === 'done', keyFor('Bar'));
    // Counter phone has no theo for this row: no "System expects 0" claim.
    await page.evaluate(() => showPage('recount'));
    await expect(page.locator('#recountList')).not.toContainText('System expects');
  });

  test('#6 the poll does not revert this phone\'s own unsynced close — and does apply the server once nothing is queued', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => stopAuditEntriesPoll());
    await page.evaluate(() => {
      appState.audit.countPhase = 'review';
      enqueuePendingMutation('rest-update', { table: 'kount_audits', filter: 'id=eq.' + encodeURIComponent(appState.audit.supabaseId), body: { count_phase: 'review' } });
    });
    await page.evaluate(() => reconcileAuditEntries());
    expect(await page.evaluate(() => appState.audit.countPhase)).toBe('review');

    // Control: with nothing queued, the same poll applies the server's phase.
    await page.evaluate(() => { pendingMutations.length = 0; persistPendingMutations(); });
    db.t.kount_audits[0].count_phase = 'count1';
    await pollUntil(page, () => appState.audit.countPhase === 'count1');
  });

  test('#5/#11 a recount list that failed to upload is retried, and holds the close meanwhile', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Bar');
    await addItem(page, 'Bar', ITEM, 2);

    // kount_recounts writes fail (offline-like 503) while Count 1 closes.
    const failRecounts = (route, req) => (req.method() === 'GET' ? route.fallback()
      : route.fulfill({ status: 503, contentType: 'application/json', body: '{"message":"upstream down"}' }));
    await page.route('**/rest/v1/kount_recounts**', failRecounts);
    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
    await expect.poll(() => page.evaluate(() => !!appState.audit._recountListPending)).toBe(true);
    expect(db.t.kount_recounts.length).toBe(0);

    // A decision recorded meanwhile is parked, not lost.
    await recordRecount(page, keyFor('Bar'), { qty: 2, result: 'verified', reason: 'matches' });
    expect(await page.evaluate((k) => !!appState.audit.recounts[k]._pendingSync, keyFor('Bar'))).toBe(true);

    // The close is held while the list/decision are unsent.
    await page.evaluate(() => closeCount2());
    await expect(page.locator('.toast')).toContainText(/recount change/i);
    await expect(page.locator('#confirmDialog')).toBeHidden();

    // Network back: the retry (ticker / 'online') uploads list + decision.
    await page.unroute('**/rest/v1/kount_recounts**', failRecounts);
    // (A flush the close attempt kicked off may still be failing on the way
    // out, so keep nudging — exactly what the 30s ticker does.)
    await expect.poll(async () => {
      await page.evaluate(() => flushPendingRecountSyncs());
      return (db.t.kount_recounts.find((r) => r.item_name === ITEM) || {}).count2_qty;
    }).toBe(2);
    expect(db.t.kount_recounts.find((r) => r.item_name === ITEM).audit_result).toBe('verified');
    expect(await page.evaluate(() => !!appState.audit._recountListPending)).toBe(false);
    await expect.poll(() => page.evaluate((k) => !!appState.audit.recounts[k]._pendingSync, keyFor('Bar'))).toBe(false);
  });

  test('#5 an update that matches 0 rows inserts the row instead of reporting success', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Bar', 2]]);
    // This test removes the row server-side by hand; the 12s poll would
    // (correctly) drop the local row too and the sheet would have nothing to
    // open — the intermittent failure seen once. Drive it without the poll.
    await page.evaluate(() => stopAuditEntriesPoll());
    db.t.kount_recounts = [];   // the row vanished server-side
    await recordRecount(page, keyFor('Bar'), { qty: 3, result: 'corrected', reason: 'one more' });
    await expect.poll(() => db.t.kount_recounts.filter((r) => r.item_name === ITEM).length).toBe(1);
    const row = db.t.kount_recounts[0];
    expect([row.zone, row.count2_qty, row.master_item_id, row.audit_result]).toEqual(['Bar', 3, M.belv, 'corrected']);
  });

  test('#10 a refresh keeps the theo / weeksActive this phone computed', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Bar', 2]]);
    const before = await page.evaluate((k) => { const r = appState.audit.recounts[k]; return { theo: r.theo, variance: r.variance, w: typeof r.weeksActive }; }, keyFor('Bar'));
    expect(before.theo).toBe(6);
    await page.evaluate(() => refreshRecountsFromSupabase());
    const after = await page.evaluate((k) => { const r = appState.audit.recounts[k]; return { theo: r.theo, variance: r.variance, w: typeof r.weeksActive }; }, keyFor('Bar'));
    expect(after).toEqual(before);
    await page.evaluate(() => showPage('recount'));
    await expect(page.locator('#recountList')).toContainText('System expects 6');
  });
});

test.describe('recount rows: dismissed, submitted, folds, the sheet', () => {
  test('#8 a row dismissed in the admin no longer blocks the close or counts as open', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);
    db.t.kount_recounts.find((r) => r.zone === 'Bar').status = 'dismissed';
    await page.evaluate(() => refreshRecountsFromSupabase());
    await recordRecount(page, keyFor('Liquor Room'), { qty: 3, result: 'verified', reason: 'matches' });

    await page.evaluate(() => showPage('recount'));
    await expect(page.locator('#recountList')).toContainText('Dismissed');
    await expect(page.locator('#recountProgress')).toContainText('1 of 1 recounted');
    // N3: a dismissed zone row is not tappable (recording it would undo the dismissal).
    await page.locator('.recount-zone-row[data-recount-key="' + keyFor('Bar') + '"]').click();
    await expect(page.locator('#guidedEntryModal')).toHaveClass(/\bhide\b/);

    await page.evaluate(() => closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(false));
  });

  test('#9 recount rows are read-only once the audit is submitted', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Bar', 2]]);
    await page.evaluate(() => { stopAuditEntriesPoll(); appState.audit.status = 'submitted'; });
    await page.evaluate((k) => openRecountEntry(k), keyFor('Bar'));
    await expect(page.locator('.toast')).toContainText(/recount is closed/i);
    await expect(page.locator('#guidedEntryModal')).toHaveClass(/\bhide\b/);
    await page.evaluate(() => verifyItemTotal('Belvedere 1L'));
    await expect(page.locator('#confirmDialog')).toBeHidden();
    await page.evaluate((k) => { appState.audit.recounts[k].recountQty = 9; return syncRecountUpdateToSupabase(k); }, keyFor('Bar'));
    expect(db.t.kount_recounts[0].count2_qty).toBeNull();
  });

  test('#13 a move into a zone that was not recounted keeps it pending and uploads the merged Count 1', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);
    await recordRecount(page, keyFor('Liquor Room'), { qty: 3, result: 'corrected', reason: 'lives in the bar', zone: 'Bar' });

    const dest = await page.evaluate((k) => {
      const r = appState.audit.recounts[k];
      return { count1Qty: r.count1Qty, recountQty: r.recountQty, status: r.status, auditResult: r.auditResult };
    }, keyFor('Bar'));
    expect(dest).toEqual({ count1Qty: 5, recountQty: null, status: 'pending', auditResult: null });
    await expect.poll(() => (db.t.kount_recounts.find((r) => r.item_name === ITEM && r.zone === 'Bar') || {}).count1_qty).toBe(5);
    expect(db.t.kount_recounts.find((r) => r.zone === 'Bar').status).toBe('pending');
  });

  test('#18 the recount sheet hides the Count-1 issue/notes/wrong-bottle controls and resets the placeholder', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    // A Count-1 entry left in Add mode with an issue picked.
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.evaluate(() => setGuidedQtyMode('add'));
    await expect(page.locator('#guidedQty')).toHaveAttribute('placeholder', 'amount to add');
    await page.evaluate(() => closeGuidedEntry());

    await switchZone(page, 'Bar');
    await addItem(page, 'Bar', ITEM, 2);
    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => page.evaluate((k) => !!(appState.audit.recounts || {})[k], keyFor('Bar'))).toBe(true);

    await page.evaluate((k) => openRecountEntry(k), keyFor('Bar'));
    await expect(page.locator('#guidedQty')).toHaveAttribute('placeholder', '0');
    await expect(page.locator('#guidedIssueGroup')).toBeHidden();
    await expect(page.locator('#guidedNotesGroup')).toBeHidden();
    await expect(page.locator('#guidedWrongBarcodeBtn')).toBeHidden();
    await page.evaluate(() => closeGuidedEntry());
    // Restored for normal counting.
    expect(await page.evaluate(() => [
      document.getElementById('guidedIssueGroup').classList.contains('hide'),
      document.getElementById('guidedNotesGroup').classList.contains('hide'),
    ])).toEqual([false, false]);
  });
});

test.describe('joining, venues, summary target, quick edits', () => {
  test('#14 a mistyped join code leaves the current audit intact', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const auditId = db.t.kount_audits[0].id;
    await expect.poll(() => db.t.kount_members.filter((m) => m.audit_id === auditId).length).toBe(1);
    const res = await page.evaluate(() => joinNetworkedAudit('NOPE-0000'));
    expect(res).toBeNull();
    expect(await page.evaluate(() => appState.audit.supabaseId)).toBe(auditId);
    expect(await page.evaluate(() => _auditEntriesPollTimer !== null)).toBe(true);
    expect(db.t.kount_members.filter((m) => m.audit_id === auditId).length).toBe(1);
  });

  test('#15 closing Count 1 while another venue is selected is refused', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addItem(page, await page.evaluate(() => appState.currentZone), ITEM, 1);
    await page.evaluate(() => {
      const other = { id: 'v-other', name: 'Other Venue', address: '', zones: ['Bar'] };
      appState.venues.push(other);
      appState.currentVenue = other;
    });
    await page.evaluate(() => closeCount1());
    await expect(page.locator('.toast')).toContainText(/This audit is for Delilah LA/);
    await expect(page.locator('#confirmDialog')).toBeHidden();
    expect(db.t.kount_audits[0].count_phase || 'count1').toBe('count1');
  });

  test('#16 Export acts on the audit shown; a submitted audit stops its clock', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => {
      summaryAuditData = {
        venueName: 'Past Venue', startedAt: '2026-10-01T10:00:00Z', completedAt: '2026-10-01T11:00:00Z',
        status: 'submitted', counts: { Bar: [{ name: 'Old Gin', qty: 7, method: 'manual' }] }, recounts: {},
      };
      renderSummaryContent();
    });
    await expect(page.locator('#summarySubmitBtn')).toBeHidden();
    const csv = await captureCsv(page, 'exportCSV()');
    expect(csv).toContain('"Old Gin"');
    await page.evaluate(() => submitAudit());
    await expect(page.locator('.toast')).toContainText(/Select the current audit/);

    // completed_at from the server (realtime/poll) is kept.
    await page.evaluate(() => applyAuditMetaRow({ status: 'submitted', count_phase: 'final', completed_at: '2026-10-28T12:00:00Z' }));
    expect(await page.evaluate(() => appState.audit.completedAt)).toBe('2026-10-28T12:00:00Z');
    // N4: reopened in the admin (kount_reopen_audit clears completed_at).
    await page.evaluate(() => applyAuditMetaRow({ status: 'active', count_phase: 'count1', completed_at: null }));
    expect(await page.evaluate(() => appState.audit.completedAt)).toBeNull();
  });

  test('#17 an edit made before the first insert answered is written over the adopted row', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const auditId = db.t.kount_audits[0].id;
    const zone = await page.evaluate(() => appState.currentZone);
    // The first insert (qty 1) committed but its response never came back...
    db.insert('kount_entries', {}, {
      audit_id: auditId, zone, item_name: ITEM, master_item_id: M.belv, item_id: null, qty: 1,
      issue: 'none', issue_notes: null, method: 'guided', counted_by_email: 'manager@hwood.com',
      is_recount: false, client_entry_id: 'E_quick', timestamp: '2026-10-28T00:00:00Z',
    });
    // ...and the counter already changed it to 4 (heal-insert path).
    const ret = await page.evaluate(async ({ BELV, zone }) => {
      const e = { id: 'E_quick', clientEntryId: 'E_quick', name: 'Belvedere 1L', masterId: BELV, qty: 4,
        method: 'guided', issue: 'none', notes: null, timestamp: new Date().toISOString() };
      appState.audit.counts[zone].unshift(e);
      const row = await syncEntryToSupabase(e, zone);
      return { qty: row && Number(row.qty), stamped: !!e.supabaseId };
    }, { BELV: M.belv, zone });
    expect(ret).toEqual({ qty: 4, stamped: true });
    expect(Number(db.t.kount_entries.find((r) => r.client_entry_id === 'E_quick').qty)).toBe(4);
  });
});

/* ---- review follow-ups (2026-10-28, second pass) ---- */
test.describe('review follow-ups', () => {
  test('B1 non-uuid master ids (custom / items.json) never 400 the recount list or its updates', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Bar');
    await addItem(page, 'Bar', ITEM, 2);
    await page.evaluate(() => {
      appState.audit.counts.Bar.push(
        { id: 'Ecus', name: 'House Bitters', masterId: 'CUS1700000000000_abc', qty: 1, method: 'manual', issue: 'none' },
        { id: 'Eim', name: 'Old Fallback Gin', masterId: 'IM0042', qty: 4, method: 'manual', issue: 'none' });
    });
    // The all-counted-items fallback (no compute "offline") keeps each entry's id.
    await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false }); });
    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_recounts.length).toBe(3);
    const byName = (n) => db.t.kount_recounts.find((r) => r.item_name === n);
    expect([byName('House Bitters').master_item_id, byName('Old Fallback Gin').master_item_id, byName(ITEM).master_item_id])
      .toEqual([null, null, M.belv]);
    await expect.poll(() => page.evaluate(() => !!appState.audit._recountListPending)).toBe(false);

    await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => true }); });
    await recordRecount(page, 'House Bitters|Bar', { qty: 1, result: 'verified', reason: 'matches' });
    await expect.poll(() => byName('House Bitters').count2_qty).toBe(1);
    expect(await page.evaluate(() => !!appState.audit.recounts['House Bitters|Bar']._pendingSync)).toBe(false);
  });

  test('B1 a 4xx on the bulk list insert falls back to row-by-row', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    let rejected = 0;
    await page.route('**/rest/v1/kount_recounts**', (route, req) => {
      let body = null; try { body = req.postDataJSON(); } catch (e) {}
      if (req.method() === 'POST' && Array.isArray(body)) {
        rejected++;
        return route.fulfill({ status: 400, contentType: 'application/json', body: '{"message":"one bad row"}' });
      }
      return route.fallback();
    });
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);
    expect(rejected).toBe(1);
    expect(await page.evaluate(() => Object.values(appState.audit.recounts).every((r) => !!r.supabaseId))).toBe(true);
  });

  test('B1 a recount update the server rejects (4xx) is reported, not retried forever, and does not hold the close', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Bar', 2]]);
    const reject = (route, req) => (req.method() === 'PATCH'
      ? route.fulfill({ status: 400, contentType: 'application/json', body: '{"message":"rejected"}' })
      : route.fallback());
    await page.route('**/rest/v1/kount_recounts**', reject);
    await recordRecount(page, keyFor('Bar'), { qty: 2, result: 'verified', reason: 'matches' });
    await expect(page.locator('.toast')).toContainText(/rejected the recount/i);
    expect(await page.evaluate((k) => !!appState.audit.recounts[k]._pendingSync, keyFor('Bar'))).toBe(false);
    await page.unroute('**/rest/v1/kount_recounts**', reject);
    await page.evaluate(() => closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(false));
  });

  test('B2 a retried list upload adopts the rows and never wipes a recount another counter recorded', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Liquor Room');
    await addItem(page, 'Liquor Room', ITEM, 3);
    await switchZone(page, 'Bar');
    await addItem(page, 'Bar', ITEM, 2);

    // The first list insert COMMITS, but its response is lost.
    let lost = false;
    const commitThenFail = (route, req) => {
      let body = null; try { body = req.postDataJSON(); } catch (e) {}
      if (!lost && req.method() === 'POST' && Array.isArray(body)) {
        lost = true;
        db.insert('kount_recounts', {}, body);
        return route.fulfill({ status: 503, contentType: 'application/json', body: '{"message":"gateway timeout"}' });
      }
      return route.fallback();
    };
    await page.route('**/rest/v1/kount_recounts**', commitThenFail);
    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_recounts.length).toBe(2);
    await expect.poll(() => page.evaluate(() => !!appState.audit._recountListPending)).toBe(true);

    // Another counter recorded Bar (it got the list from the server).
    const bar = db.t.kount_recounts.find((r) => r.zone === 'Bar');
    Object.assign(bar, { count2_qty: 7, status: 'done', audit_result: 'corrected', audit_reason: 'counter B found more' });

    // Retry: adopts the server rows, inserts nothing, deletes nothing.
    await page.unroute('**/rest/v1/kount_recounts**', commitThenFail);
    await expect.poll(async () => {
      await page.evaluate(() => flushPendingRecountSyncs());
      return page.evaluate(() => !!appState.audit._recountListPending);
    }).toBe(false);
    expect(db.t.kount_recounts.length).toBe(2);
    const after = db.t.kount_recounts.find((r) => r.zone === 'Bar');
    expect([after.id, after.count2_qty, after.audit_result, after.status]).toEqual([bar.id, 7, 'corrected', 'done']);
    expect(await page.evaluate((k) => appState.audit.recounts[k].supabaseId, keyFor('Bar'))).toBe(bar.id);
    // ...and this phone now shows counter B's recount.
    await page.evaluate(() => refreshRecountsFromSupabase());
    expect(await page.evaluate((k) => appState.audit.recounts[k].recountQty, keyFor('Bar'))).toBe(7);
  });

  test('S1 a recount save still on the wire holds the close until it lands', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Bar', 2]]);
    expect(await page.evaluate(() => {
      _recountSyncInFlight['x|y'] = 1;
      const held = pendingUploadsBlockClose();
      delete _recountSyncInFlight['x|y'];
      return held;
    })).toBe(true);

    const slow = async (route, req) => {
      if (req.method() === 'PATCH') await new Promise((r) => setTimeout(r, 1500));
      return route.fallback();
    };
    await page.route('**/rest/v1/kount_recounts**', slow);
    await recordRecount(page, keyFor('Bar'), { qty: 2, result: 'verified', reason: 'matches' });
    expect(await page.evaluate(() => Object.keys(_recountSyncInFlight).length)).toBeGreaterThan(0);
    const closing = page.evaluate(() => closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    // The close waited for the save: the server already has it.
    expect(db.t.kount_recounts.find((r) => r.zone === 'Bar').count2_qty).toBe(2);
    await closing;
    await page.evaluate(() => window.closeConfirm(false));
  });

  test('S2 folding into a zone this phone has no decision for keeps another counter\'s recount there', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);
    await page.evaluate(() => stopAuditEntriesPoll());   // this phone missed counter B's save
    Object.assign(db.t.kount_recounts.find((r) => r.zone === 'Bar'),
      { count2_qty: 2, status: 'done', audit_result: 'verified', audit_reason: 'counter B' });

    await recordRecount(page, keyFor('Liquor Room'), { qty: 3, result: 'corrected', reason: 'lives in the bar', zone: 'Bar' });
    await expect.poll(() => db.t.kount_recounts.find((r) => r.zone === 'Bar').count1_qty).toBe(5);
    const bar = db.t.kount_recounts.find((r) => r.zone === 'Bar');
    expect([bar.count2_qty, bar.status, bar.audit_result]).toEqual([2, 'done', 'verified']);
  });

  test('S3 the poll does not revert an entry edit that is queued or still on the wire', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => stopAuditEntriesPoll());
    const zone = await page.evaluate(() => appState.currentZone);
    await addItem(page, zone, ITEM, 3);
    await expect.poll(() => page.evaluate((z) => !!(appState.audit.counts[z][0] || {}).supabaseId, zone)).toBe(true);
    const qty = () => page.evaluate((z) => appState.audit.counts[z].find((e) => e.name === 'Belvedere 1L').qty, zone);

    // Queued (e.g. made offline): the server still says 3.
    await page.evaluate((z) => {
      const e = appState.audit.counts[z].find((x) => x.name === 'Belvedere 1L');
      e.qty = 5;
      enqueuePendingMutation('rest-update', { table: 'kount_entries', filter: 'id=eq.' + encodeURIComponent(e.supabaseId), body: { qty: 5 } });
    }, zone);
    await page.evaluate(() => reconcileAuditEntries());
    expect(await qty()).toBe(5);

    // On the wire: a "+" whose PATCH hasn't landed.
    await page.evaluate(() => { pendingMutations.length = 0; persistPendingMutations(); });
    const slow = async (route, req) => {
      if (req.method() === 'PATCH') await new Promise((r) => setTimeout(r, 1500));
      return route.fallback();
    };
    await page.route('**/rest/v1/kount_entries**', slow);
    db.t.kount_entries.find((r) => r.item_name === ITEM).qty = 3;
    await page.evaluate((z) => {
      const e = appState.audit.counts[z].find((x) => x.name === 'Belvedere 1L');
      adjustQuantity(e.id, 1);
    }, zone);
    await page.evaluate(() => reconcileAuditEntries());
    expect(await qty()).toBe(6);
    await page.unroute('**/rest/v1/kount_entries**', slow);

    // Control: nothing queued or in flight -> the server value applies.
    await expect.poll(() => Number(db.t.kount_entries.find((r) => r.item_name === ITEM).qty)).toBe(6);
    db.t.kount_entries.find((r) => r.item_name === ITEM).qty = 9;
    await pollUntil(page, (z) => appState.audit.counts[z].find((e) => e.name === 'Belvedere 1L').qty === 9, zone);
  });

  test('S4 starting an audit at another venue while offline leaves the current audit in place', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const auditId = db.t.kount_audits[0].id;
    await expect.poll(() => db.t.kount_members.filter((m) => m.audit_id === auditId).length).toBe(1);
    await page.evaluate(() => {
      const other = { id: 'v-other', name: 'Other Venue', address: '', zones: ['Bar'] };
      appState.venues.push(other);
      appState.currentVenue = other;
      Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false });
    });
    const starting = page.evaluate(() => startNewAudit());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await starting;
    await expect(page.locator('.toast')).toContainText(/must be online/i);
    expect(await page.evaluate(() => appState.audit.supabaseId)).toBe(auditId);
    expect(await page.evaluate(() => _auditEntriesPollTimer !== null)).toBe(true);
    expect(db.t.kount_members.filter((m) => m.audit_id === auditId).length).toBe(1);
  });

  test('S5 the admin role passes the manager gates; venue_manager stays read-only', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(() => {
      const out = ['admin', 'corporate', 'manager', 'counter', 'venue_manager'].map(isManagerRole);
      appState.user.role = 'admin';
      out.push(canSubmitAudit());
      appState.user.role = 'counter';
      out.push(canSubmitAudit());
      appState.user.role = 'manager';
      return out;
    });
    expect(r).toEqual([true, true, true, false, false, true, false]);
  });

  test('N6 recount decisions still unsent when the audit gets submitted are reported, not dropped silently', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Bar', 2]]);
    await page.evaluate((k) => {
      stopAuditEntriesPoll();
      appState.audit.recounts[k]._pendingSync = true;
      applyAuditMetaRow({ status: 'submitted', count_phase: 'final', completed_at: new Date().toISOString() });
    }, keyFor('Bar'));
    await expect(page.locator('.toast')).toContainText(/never reached the server/i);
    expect(await page.evaluate((k) => !!appState.audit.recounts[k]._pendingSync, keyFor('Bar'))).toBe(false);
  });
});
