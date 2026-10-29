/* Count-entry sheet / counted list + scan / photo / manual capture fixes
 * (review batch, 2026-10-28). One focused test per finding where the mock can
 * drive it. The mock has no realtime; "background re-render" is simulated by
 * calling renderGuidedMode / reconcileAuditEntries directly, the way the 12 s
 * poll does.
 */
const { test, expect, startAuditAs, addManual, switchZone, counted, M } = require('../fixtures');

const SUPA = 'https://mnraeesscqsaappkaldb.supabase.co';

const zoneEntries = (page, zone) => page.evaluate((z) =>
  ((appState.audit.counts || {})[z || appState.currentZone] || []).map((e) => ({ ...e })), zone);

/* Count an item in the current zone through the real guided sheet. */
async function countViaSheet(page, masterId, qty, opts) {
  opts = opts || {};
  await page.evaluate((id) => openGuidedEntry(id), masterId);
  await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
  if (opts.issue) await page.locator('#guidedIssueChips .issue-chip[data-issue="' + opts.issue + '"]').click();
  if (opts.notes != null) await page.fill('#guidedIssueNotes', opts.notes);
  await page.fill('#guidedQty', String(qty));
  await page.locator('#guidedConfirmBtn').click();
  await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
}

/* A real (canvas) camera stream, so the photo shutter has frames to arm on.
   The fixture's fake stream object can't be attached to a <video>. */
async function useCanvasCamera(page) {
  await page.evaluate(() => {
    navigator.mediaDevices.getUserMedia = async () => {
      const c = document.createElement('canvas');
      c.width = 64; c.height = 48;
      const ctx = c.getContext('2d');
      ctx.fillStyle = '#884'; ctx.fillRect(0, 0, 64, 48);
      const s = c.captureStream(10);
      // Keep painting so frames keep flowing.
      setInterval(() => { ctx.fillRect(0, 0, 1 + Math.random() * 63, 48); }, 50);
      return s;
    };
  });
}

/* Hold every parse-bottle-label request until the test releases it. */
async function holdLabelReads(page) {
  const held = [];
  await page.route(SUPA + '/functions/v1/parse-bottle-label', (route) => { held.push(route); });
  return held;
}
const release = (route, body) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });

async function takePhoto(page) {
  await page.evaluate(() => openPhotoCapture());
  await expect(page.locator('#photoCaptureBtn')).toBeEnabled({ timeout: 5000 });
  await page.locator('#photoCaptureBtn').click();
  await page.locator('#photoReviewModal').waitFor({ state: 'visible' });
}

const BELV_READ = { name: 'Belvedere', brand: '', category: 'spirits', vintage: '', size: '1L', details: '', matchedId: M.belv, confidence: 'high' };

test.describe('count-entry sheet + counted list', () => {
  test('A1 reopening a counted item keeps its issue + notes; a new item opens blank', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await countViaSheet(page, M.belv, 3, { issue: 'damaged', notes: 'cracked cap' });

    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await expect(page.locator('#guidedIssueChips .issue-chip.selected')).toHaveAttribute('data-issue', 'damaged');
    await expect(page.locator('#guidedIssueNotes')).toHaveValue('cracked cap');
    await page.fill('#guidedQty', '5');
    await page.locator('#guidedConfirmBtn').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    const e = (await zoneEntries(page)).find((x) => x.masterId === M.belv);
    expect(e.qty).toBe(5);
    expect(e.issue).toBe('damaged');
    expect(e.notes).toBe('cracked cap');
    await expect.poll(() => (db.t.kount_entries.find((r) => r.master_item_id === M.belv) || {}).qty).toBe(5);
    const row = db.t.kount_entries.find((r) => r.master_item_id === M.belv);
    expect(row.issue).toBe('damaged');
    expect(row.issue_notes).toBe('cracked cap');

    // A different, uncounted item starts blank.
    await page.evaluate((id) => openGuidedEntry(id), M.campari);
    await expect(page.locator('#guidedIssueChips .issue-chip.selected')).toHaveAttribute('data-issue', 'none');
    await expect(page.locator('#guidedIssueNotes')).toHaveValue('');
  });

  test('A2 an item missing from the catalog: toast, scan falls back to the modal, reference row not tappable', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => openGuidedEntry('99999999-0000-4000-8000-000000000000'));
    await expect(page.locator('.toast')).toContainText(/not in the catalog/i);
    await expect(page.locator('#guidedEntryModal')).toHaveClass(/hide/);

    // A learned barcode whose master isn't loaded: not an instant hit.
    const handled = await page.evaluate(() => {
      upcMappingsCache['5060071510995'] = { title: 'Ghost Gin', category: 'spirits',
        masterId: '99999999-0000-4000-8000-000000000000', barcode: '5060071510995' };
      return { resolved: resolveInstantScan('5060071510995'), instant: instantScanCount('5060071510995') };
    });
    expect(handled.resolved).toBeNull();
    expect(handled.instant).toBe(false);

    // A prior-audit reference row that no longer resolves isn't tappable.
    await page.evaluate((belv) => {
      appState.priorAuditReference = { byZone: { [appState.currentZone]: [
        { id: '99999999-0000-4000-8000-000000000000', name: 'Ghost Gin', category: 'spirits' },
        { id: belv, name: 'Belvedere 1L', category: 'spirits' },
      ] } };
      renderGuidedMode();
    }, M.belv);
    const ghost = page.locator('#guidedContent .c-item', { hasText: 'Ghost Gin' });
    await expect(ghost).toHaveCount(1);
    await expect(ghost.locator('[onclick]')).toHaveCount(0);
    await expect(page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' }).locator('[onclick]')).toHaveCount(1);
  });

  test('A3 a background re-render waits while the All Count search or a qty edit is focused', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 2);
    await page.evaluate(() => setCountView('all'));
    const search = page.locator('#allCountSearch');
    await search.click();
    await search.type('belv');
    const same = await page.evaluate(() => {
      const before = document.getElementById('allCountSearch');
      const z = appState.currentZone;
      appState.audit.counts[z][0].qty = 7;    // a change another phone made
      renderGuidedMode();                      // the poll's re-render
      return document.getElementById('allCountSearch') === before && document.activeElement === before;
    });
    expect(same).toBe(true);
    await expect(search).toHaveValue('belv');
    // Leaving the field applies the deferred render.
    await page.evaluate(() => document.activeElement.blur());
    await expect(page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' }).locator('.qty-val').first()).toHaveText('7');

    // Tap-to-edit qty input survives too.
    await page.evaluate(() => setCountView('zone'));
    await page.locator('#guidedContent .qty-editable').first().click();
    const editKept = await page.evaluate(() => {
      const inp = document.activeElement;
      renderGuidedMode();
      return inp && inp.tagName === 'INPUT' && inp.isConnected && document.activeElement === inp;
    });
    expect(editKept).toBe(true);
    await page.keyboard.type('9');
    await page.keyboard.press('Enter');
    await expect.poll(async () => (await zoneEntries(page))[0].qty).toBe(9);
    await expect(page.locator('#guidedContent .qty-editable').first()).toHaveText('9');
  });

  test('A3 the poll does not re-render the list when nothing changed — and does when a row changed', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 2);
    await expect.poll(() => db.t.kount_entries.filter((r) => r.master_item_id === M.belv).length).toBe(1);
    await expect.poll(async () => (await zoneEntries(page))[0].supabaseId || null).not.toBeNull();
    await page.evaluate(() => { document.querySelector('#guidedContent .c-item').dataset.marker = 'kept'; });
    await page.evaluate(() => reconcileAuditEntries());
    await expect(page.locator('#guidedContent .c-item[data-marker="kept"]')).toHaveCount(1);

    // Positive control: another phone changed the row → the poll repaints.
    db.t.kount_entries.find((r) => r.master_item_id === M.belv).qty = 6;
    await page.evaluate(() => reconcileAuditEntries());
    await expect(page.locator('#guidedContent .c-item[data-marker="kept"]')).toHaveCount(0);
    await expect(page.locator('#guidedContent .qty-editable').first()).toHaveText('6');
  });

  test('A3 deferred render, then a real click on a search result opens the sheet; the list refreshes after', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 2);
    await page.fill('#guidedSearchInput', 'Campari');
    await expect(page.locator('#guidedSearchResults .c-item', { hasText: 'Campari 1L' }).first()).toBeVisible();
    const deferred = await page.evaluate(() => {
      appState.audit.counts[appState.currentZone][0].qty = 7;   // another phone's change
      renderGuidedMode();                                       // the poll's re-render
      return _guidedRenderDeferred;
    });
    expect(deferred).toBe(true);
    await expect(page.locator('#guidedContent .qty-editable').first()).toHaveText('2');
    await page.locator('#guidedSearchResults .c-item', { hasText: 'Campari 1L' }).first().click();
    await expect(page.locator('#guidedEntryModal')).toBeVisible();
    await expect(page.locator('#guidedHeroTitle')).toHaveText('Campari 1L');
    await expect(page.locator('#guidedContent .qty-editable').first()).toHaveText('7');
  });

  test('item 1: an inline qty edit applies to the CURRENT count, not the one it opened with', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    const bump = (q) => page.evaluate((qq) => {   // a reconcile/realtime update while the field is open
      appState.audit.counts[appState.currentZone][0].qty = qq;
      renderGuidedMode();
    }, q);

    // Plain number = SET: 3 → (5 underneath) → type 4 → 4, not 6.
    await page.locator('#guidedContent .qty-editable').first().click();
    await bump(5);
    await page.keyboard.type('4');
    await page.keyboard.press('Enter');
    await expect.poll(async () => (await zoneEntries(page))[0].qty).toBe(4);

    // "+N" stays relative to the current count: 4 → (6 underneath) → +2 → 8.
    await page.locator('#guidedContent .c-item').first().getByRole('button', { name: 'Add multiple at once' }).click();
    await bump(6);
    await page.keyboard.type('2');
    await page.keyboard.press('Enter');
    await expect.poll(async () => (await zoneEntries(page))[0].qty).toBe(8);

    // Leaving the field untouched does not put the old value back.
    await page.locator('#guidedContent .qty-editable').first().click();
    await bump(9);
    await page.keyboard.press('Enter');
    await expect.poll(async () => (await zoneEntries(page))[0].qty).toBe(9);
  });

  test('item 3: the locked count page repaints its after-recount totals when the poll brings a recount', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    for (const [zone, qty] of [['Liquor Room', 3], ['Bar', 2]]) {
      await switchZone(page, zone);
      await addManual(page, 'Belvedere 1L', qty);
      await expect.poll(async () => (await zoneEntries(page, zone)).length).toBe(1);
    }
    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
    await expect.poll(() => db.t.kount_recounts.filter((r) => r.item_name === 'Belvedere 1L').length, { timeout: 5000 }).toBe(2);
    await expect.poll(() => page.evaluate(() => !!appState.audit._recountListPending)).toBe(false);

    await page.evaluate(() => showPage('count'));
    const total = () => page.locator('#auditLockedOverlay .stat-row', { hasText: 'Total quantity' }).innerText();
    expect(await total()).toMatch(/\b5$/);
    // Another phone records a corrected recount for Liquor Room (3 → 4).
    Object.assign(db.t.kount_recounts.find((r) => r.zone === 'Liquor Room'),
      { count2_qty: 4, audit_result: 'corrected', audit_reason: 'found one', status: 'done' });
    await page.evaluate(() => reconcileAuditEntries());
    await expect.poll(total).toMatch(/\b6$/);
  });

  test('A1 reopen a flagged entry → None → Confirm clears the issue locally and on the server', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await countViaSheet(page, M.belv, 2, { issue: 'damaged', notes: 'cracked cap' });
    await expect.poll(() => (db.t.kount_entries.find((r) => r.master_item_id === M.belv) || {}).issue).toBe('damaged');
    await expect.poll(async () => (await zoneEntries(page))[0].supabaseId || null).not.toBeNull();
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedIssueChips .issue-chip[data-issue="none"]').click();
    await page.fill('#guidedIssueNotes', '');
    await page.locator('#guidedConfirmBtn').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
    const e = (await zoneEntries(page))[0];
    expect(e.issue).toBe('none');
    expect(e.notes || null).toBeNull();
    await expect.poll(() => db.t.kount_entries.find((r) => r.master_item_id === M.belv).issue).toBe('none');
    expect(db.t.kount_entries.find((r) => r.master_item_id === M.belv).issue_notes || null).toBeNull();
  });

  test('A1 a scan reopen (Add mode) keeps the issue + notes', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await countViaSheet(page, M.belv, 3, { issue: 'damaged', notes: 'cracked cap' });
    await page.evaluate((id) => openScanEntry(id, '5060071510019'), M.belv);
    await expect(page.locator('#gqmAddBtn')).toHaveClass(/active/);
    await expect(page.locator('#guidedIssueChips .issue-chip.selected')).toHaveAttribute('data-issue', 'damaged');
    await expect(page.locator('#guidedIssueNotes')).toHaveValue('cracked cap');
    await page.fill('#guidedQty', '2');
    await page.locator('#guidedConfirmBtn').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
    await page.evaluate(() => closeBarcodeScanner());   // Confirm re-opens the scanner
    const e = (await zoneEntries(page))[0];
    expect([e.qty, e.issue, e.notes]).toEqual([5, 'damaged', 'cracked cap']);
    await expect.poll(() => (db.t.kount_entries.find((r) => r.master_item_id === M.belv) || {}).qty).toBe(5);
    expect(db.t.kount_entries.find((r) => r.master_item_id === M.belv).issue).toBe('damaged');
  });

  test('A4 "Wrong bottle?" sends the remap only on Confirm; zone change / Cancel drop it', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const CODE = '5060071510019';
    await page.evaluate(({ id, code }) => openScanEntry(id, code), { id: M.belv, code: CODE });
    await page.locator('#guidedWrongBarcodeBtn').click();
    await expect(page.locator('#remapBanner')).toContainText(CODE);

    // Opening another item no longer files the remap — it says it will...
    await page.evaluate((id) => openGuidedEntry(id), M.titos);
    await expect(page.locator('#guidedRemapNote')).toBeVisible();
    await expect(page.locator('#guidedRemapNote')).toContainText('Also fixes barcode ' + CODE);
    await page.waitForTimeout(300);
    expect(db.t.upc_mappings.length).toBe(0);
    // ...skipping it neither.
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Skip' }).click();
    expect(db.t.upc_mappings.length).toBe(0);
    await expect(page.locator('#remapBanner')).toContainText(CODE);
    // Confirming the corrected item does.
    await countViaSheet(page, M.titos, 1);
    await expect.poll(() => db.t.upc_mappings.length).toBe(1);
    expect(db.t.upc_mappings[0]).toMatchObject({ barcode_raw: CODE, master_item_id: M.titos, status: 'pending' });
    await expect(page.locator('#remapBanner')).toBeEmpty();

    // A zone change drops a pending fix.
    await page.evaluate(({ id, code }) => openScanEntry(id, code), { id: M.belv, code: CODE });
    await page.locator('#guidedWrongBarcodeBtn').click();
    await switchZone(page, 'Bar');
    await expect(page.locator('#remapBanner')).toBeEmpty();
    expect(await page.evaluate(() => pendingRemapCode)).toBeNull();

    // Any other path that changes the zone (add/remove zone, venue switch)
    // voids it too, at the next render or confirm.
    await page.evaluate(({ id, code }) => openScanEntry(id, code), { id: M.belv, code: CODE });
    await page.locator('#guidedWrongBarcodeBtn').click();
    await expect(page.locator('#remapBanner')).toContainText(CODE);
    await page.evaluate(() => { appState.currentZone = 'Service Well'; renderCountPage(); });
    await expect(page.locator('#remapBanner')).toBeEmpty();
    expect(await page.evaluate(() => pendingRemapCode)).toBeNull();
    await page.evaluate(() => { appState.currentZone = 'Bar'; renderCountPage(); });
    // The same item the barcode already pointed at: no note, nothing sent.
    await page.evaluate(({ id, code }) => openScanEntry(id, code), { id: M.belv, code: CODE });
    await page.locator('#guidedWrongBarcodeBtn').click();
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await expect(page.locator('#guidedRemapNote')).toBeHidden();
    await page.evaluate(() => closeGuidedEntry());

    // So does Cancel on the banner, and opening Manual.
    await page.evaluate(({ id, code }) => openScanEntry(id, code), { id: M.belv, code: CODE });
    await page.locator('#guidedWrongBarcodeBtn').click();
    await page.locator('#remapBanner').getByRole('button', { name: 'Cancel' }).click();
    expect(await page.evaluate(() => pendingRemapCode)).toBeNull();
    await page.evaluate(({ id, code }) => openScanEntry(id, code), { id: M.belv, code: CODE });
    await page.locator('#guidedWrongBarcodeBtn').click();
    await page.evaluate(() => openManualEntry());
    expect(await page.evaluate(() => pendingRemapCode)).toBeNull();
    await page.evaluate(() => closeManualEntry());
    await countViaSheet(page, M.campari, 1);
    await page.waitForTimeout(300);
    expect(db.t.upc_mappings.length).toBe(1);
  });

  test('A5 partial chips: Full does not keep adding, partials replace, highlight follows the tap', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await expect(page.locator('#guidedPartialBtns .partial-btn.active')).toHaveCount(0);
    const qty = page.locator('#guidedQty');
    const chip = (t) => page.locator('#guidedPartialBtns .partial-btn', { hasText: t });
    await qty.fill('3');
    await chip('Full').click();
    await expect(qty).toHaveValue('4');
    await chip('Full').click();
    await expect(qty).toHaveValue('4');
    await chip('50%').click();
    await expect(qty).toHaveValue('3.5');
    await chip('75%').click();
    await expect(qty).toHaveValue('3.75');
    await expect(page.locator('#guidedPartialBtns .partial-btn.active')).toHaveText('75%');
    // Typing starts over from what was typed.
    await qty.fill('2');
    await expect(page.locator('#guidedPartialBtns .partial-btn.active')).toHaveCount(0);
    await chip('25%').click();
    await expect(qty).toHaveValue('2.25');
    // Reopening clears the base + highlight.
    await page.evaluate(() => closeGuidedEntry());
    await page.evaluate((id) => openGuidedEntry(id), M.campari);
    await expect(page.locator('#guidedPartialBtns .partial-btn.active')).toHaveCount(0);
    await qty.fill('1');
    await chip('50%').click();
    await expect(qty).toHaveValue('1.5');
  });

  test('A6 no float noise from -/+ or prefills; recount Count 1 total formatted', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 2.3);
    await page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' }).getByRole('button', { name: '-', exact: true }).click();
    const e = (await zoneEntries(page))[0];
    expect(e.qty).toBe(1.3);
    await expect(page.locator('#guidedContent .qty-editable').first()).toHaveAttribute('data-qty', '1.3');

    await page.evaluate(() => { appState.audit.counts[appState.currentZone][0].qty = 1.2999999999999998; });
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await expect(page.locator('#guidedQty')).toHaveValue('1.3');
    await page.evaluate(() => closeGuidedEntry());

    const total = await page.evaluate(() => {
      appState.audit.countPhase = 'review';
      appState.audit.recounts = {
        'Belvedere 1L|Liquor Room': { itemName: 'Belvedere 1L', zone: 'Liquor Room', count1Qty: 0.1, severity: 'HIGH', status: 'pending', avtItem: { itemName: 'Belvedere 1L' } },
        'Belvedere 1L|Bar': { itemName: 'Belvedere 1L', zone: 'Bar', count1Qty: 0.2, severity: 'HIGH', status: 'pending', avtItem: { itemName: 'Belvedere 1L' } },
      };
      renderRecountPage();
      return document.getElementById('recountList').textContent;
    });
    expect(total).toContain('Count 1 total: 0.30 across 2 zones');
  });

  test('A7 an All Count row whose key has an apostrophe expands', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => {
      appState.audit.counts[appState.currentZone].push({ id: 'Ejoe', name: "Joe's Pickles", category: 'food', qty: 2, method: 'manual', masterId: null, issue: 'none' });
      setCountView('all');
    });
    const row = page.locator('#guidedContent .c-item', { hasText: "Joe's Pickles" });
    await row.locator('[data-key]').click();
    await expect(row.locator('.qty-editable')).toHaveCount(1);
  });

  test('A8 search "counted" shows this zone, or the all-zones total', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Liquor Room');
    await addManual(page, 'Belvedere 1L', 3);
    await switchZone(page, 'Bar');
    await addManual(page, 'Belvedere 1L', 5);
    await switchZone(page, 'Liquor Room');
    await page.fill('#guidedSearchInput', 'Belvedere 1L');
    await expect(page.locator('#guidedSearchResults .c-item', { hasText: 'Belvedere 1L' }).first()).toContainText('counted: 3');
    await page.locator('#guidedSearchInput').blur();
    await switchZone(page, 'Service Well');
    await page.fill('#guidedSearchInput', 'Belvedere 1L');
    await expect(page.locator('#guidedSearchResults .c-item', { hasText: 'Belvedere 1L' }).first()).toContainText('counted: 8 (all zones)');
  });

  test('A9 tap-to-edit qty uses the decimal keypad', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 2);
    await page.locator('#guidedContent .qty-editable').first().click();
    expect(await page.evaluate(() => document.activeElement.inputMode)).toBe('decimal');
  });

  test('A10 moving a flagged item into a zone that already has it keeps the flag', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Bar');
    await countViaSheet(page, M.belv, 2, { notes: 'top shelf' });
    await switchZone(page, 'Liquor Room');
    await countViaSheet(page, M.belv, 1, { issue: 'damaged', notes: 'torn label' });
    await expect.poll(() => db.t.kount_entries.filter((r) => r.master_item_id === M.belv && r.id).length).toBe(2);
    await expect.poll(async () => (await zoneEntries(page, 'Bar'))[0].supabaseId || null).not.toBeNull();
    const id = (await zoneEntries(page, 'Liquor Room'))[0].id;
    await page.evaluate((eid) => moveEntryToZone(eid, 'Bar'), id);
    const bar = (await zoneEntries(page, 'Bar'))[0];
    expect(bar.qty).toBe(3);
    expect(bar.issue).toBe('damaged');
    expect(bar.notes).toBe('top shelf · torn label');
    await expect.poll(() => (db.t.kount_entries.find((r) => r.zone === 'Bar' && r.master_item_id === M.belv) || {}).issue).toBe('damaged');
    expect(db.t.kount_entries.find((r) => r.zone === 'Bar' && r.master_item_id === M.belv).issue_notes).toBe('top shelf · torn label');
  });
});

test.describe('capture flows', () => {
  test('B1 one "Did you mean?" per submit; main + extra location each land in their own zone', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Liquor Room');
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.fill('#manualName', 'Belveder');
    await page.fill('#manualQty', '3');
    await page.locator('#manualModal button', { hasText: '+ Location' }).click();
    await page.locator('#manualExtraLocations select').selectOption('Bar');
    await page.locator('#manualExtraLocations .extra-loc-qty').fill('2');
    await page.locator('#manualModal').getByRole('button', { name: 'Add to count', exact: true }).click();

    const picker = page.locator('#fuzzyMatchPickerModal');
    await picker.waitFor({ state: 'visible' });
    await picker.locator('.fuzzy-pick', { hasText: 'Belvedere 1L' }).first().click();
    await picker.waitFor({ state: 'hidden' });
    await page.waitForTimeout(200);
    await expect(picker).toBeHidden();   // no second picker

    const all = await counted(page);
    const lr = all.filter((i) => i.zone === 'Liquor Room' && i.masterId === M.belv);
    const bar = all.filter((i) => i.zone === 'Bar' && i.masterId === M.belv);
    expect(lr.map((i) => i.qty)).toEqual([3]);
    expect(bar.map((i) => i.qty)).toEqual([2]);
    // The list re-rendered after the answer (the entry keeps the typed name).
    await expect(page.locator('#guidedContent .qty-editable[data-qty="3"]')).toHaveCount(1);
  });

  test('B1 barcode sheet: "Did you mean?" + Location — one picker, each zone gets its own qty', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await switchZone(page, 'Liquor Room');
    await page.evaluate(() => openBarcodeEntryModal('5060071510774', { notFound: true }));
    await page.fill('#barcodeName', 'Belveder');
    await page.fill('#barcodeQty', '3');
    await page.locator('#barcodeEntryModal button', { hasText: '+ Location' }).click();
    await page.locator('#barcodeExtraLocations select').selectOption('Bar');
    await page.locator('#barcodeExtraLocations .extra-loc-qty').fill('2');
    await page.locator('#barcodeEntryModal').getByRole('button', { name: 'Add to count', exact: true }).click();

    const picker = page.locator('#fuzzyMatchPickerModal');
    await picker.waitFor({ state: 'visible' });
    await picker.locator('.fuzzy-pick', { hasText: 'Belvedere 1L' }).first().click();
    await picker.waitFor({ state: 'hidden' });
    await page.waitForTimeout(200);
    await expect(picker).toBeHidden();
    const all = await counted(page);
    expect(all.filter((i) => i.zone === 'Liquor Room' && i.masterId === M.belv).map((i) => i.qty)).toEqual([3]);
    expect(all.filter((i) => i.zone === 'Bar' && i.masterId === M.belv).map((i) => i.qty)).toEqual([2]);
  });

  test('B2 retyping the barcode name drops the picked item (count + UPC link)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => openBarcodeEntryModal('5060071510774', { notFound: true }));
    await page.fill('#barcodeName', 'Belv');
    await page.locator('#barcodeNameSuggestions .barcode-suggestion', { hasText: 'Belvedere 1L' }).click();
    await expect(page.locator('#barcodeUpcLinkBanner')).toBeVisible();
    await page.fill('#barcodeName', 'Campari 1L');
    await expect(page.locator('#barcodeUpcLinkBanner')).toBeHidden();
    await page.locator('#barcodeEntryModal').getByRole('button', { name: 'Add to count', exact: true }).click();
    const all = await counted(page);
    expect(all.filter((i) => i.masterId === M.belv)).toHaveLength(0);
    expect(all.filter((i) => i.masterId === M.campari)).toHaveLength(1);
    await page.waitForTimeout(300);
    expect(db.t.upc_mappings.filter((m) => m.master_item_id === M.belv)).toHaveLength(0);
  });

  test('B3/B5/B9 a late label read never overwrites the counter\'s pick or the next photo', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await useCanvasCamera(page);
    const held = await holdLabelReads(page);

    // Photo 1: the counter picks Campari before the AI answers.
    await takePhoto(page);
    await expect.poll(() => held.length).toBe(1);
    await page.fill('#photoName', 'Campari');
    await page.locator('#photoSearchResults div', { hasText: 'Campari 1L' }).first().click();
    await release(held[0], BELV_READ);
    await page.waitForTimeout(300);
    await expect(page.locator('#photoName')).toHaveValue('Campari 1L');
    expect(await page.evaluate(() => document.getElementById('photoName').dataset.masterId)).toBe(M.campari);

    // Photo 2: its read is still running when the counter closes the review
    // (with leftovers on the form) and takes photo 3.
    await page.evaluate(() => closePhotoReview());
    await takePhoto(page);
    await expect.poll(() => held.length).toBe(2);
    await page.evaluate(() => {
      const n = document.getElementById('photoName');
      n.dataset.aiNew = '1'; n.dataset.aiSize = '1.5L';
      document.getElementById('photoSearchResults').innerHTML = '<div>stale</div>';
      document.getElementById('photoSuggestBtn').style.display = 'block';
      closePhotoReview();
    });
    await takePhoto(page);
    // Photo 3's form starts clean (B5/B9)...
    const fresh = await page.evaluate(() => {
      const n = document.getElementById('photoName');
      return { aiNew: n.dataset.aiNew || null, aiSize: n.dataset.aiSize || null,
        results: document.getElementById('photoSearchResults').innerHTML,
        suggest: document.getElementById('photoSuggestBtn').style.display };
    });
    expect(fresh).toEqual({ aiNew: null, aiSize: null, results: '', suggest: 'none' });
    // ...and photo 2's read arriving late doesn't touch it (B3).
    await expect.poll(() => held.length).toBe(3);
    await release(held[1], { ...BELV_READ, matchedId: M.campari });
    await page.waitForTimeout(300);
    await expect(page.locator('#photoName')).toHaveValue('');
    // Photo 3's own read applies.
    await release(held[2], BELV_READ);
    await expect(page.locator('#photoName')).toHaveValue('Belvedere 1L');
  });

  test('B3 a read that lands after the review closed is dropped', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await useCanvasCamera(page);
    const held = await holdLabelReads(page);
    await takePhoto(page);
    await expect.poll(() => held.length).toBe(1);
    await page.evaluate(() => closePhotoReview());
    await release(held[0], BELV_READ);
    await page.waitForTimeout(300);
    await expect(page.locator('#photoName')).toHaveValue('');
  });

  test('B4 an AI match shows "Already counted N here"', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 4);
    await page.evaluate((p) => window.populatePhotoFormFromParsed(p, document.getElementById('parsingStatus')),
      { ...BELV_READ, matchedId: M.campari });   // Campari has no size siblings
    await expect(page.locator('#photoDupeWarning')).toBeEmpty();
    await page.evaluate(() => { document.getElementById('photoSearchResults').innerHTML = '<div>old</div>'; });
    await page.evaluate((p) => window.populatePhotoFormFromParsed(p, document.getElementById('parsingStatus')), BELV_READ);
    // Belvedere has a 1.75L sibling: keep the photo match.
    const picker = page.locator('#sizePickerModal');
    if (await picker.isVisible().catch(() => false)) await page.locator('#sizePickerCancelBtn').click();
    await expect(page.locator('#photoDupeWarning')).toContainText('Already counted 4 here');
    await expect(page.locator('#photoSearchResults')).toBeEmpty();
  });

  test('B5 retyping an AI new-product name drops the new-product flags', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const before = db.t.kount_pending_items.length;
    await page.evaluate(() => window.populatePhotoFormFromParsed({ name: 'Bordeaux Supérieur', brand: 'Domaine des Justices',
      category: 'wine', vintage: '2020', size: '750ml', details: '', matchedId: null }, document.getElementById('parsingStatus')));
    expect(await page.evaluate(() => document.getElementById('photoName').dataset.aiNew)).toBe('1');
    await page.evaluate(() => document.getElementById('photoReviewModal').classList.remove('hide'));
    await page.fill('#photoName', 'Zzyzx Table Red');
    const flags = await page.evaluate(() => ({ a: document.getElementById('photoName').dataset.aiNew || null, s: document.getElementById('photoName').dataset.aiSize || null }));
    expect(flags).toEqual({ a: null, s: null });
    await page.evaluate(() => { window.capturedPhotoData = 'data:image/jpeg;base64,AAAA'; return submitPhotoEntry(); });
    await expect.poll(async () => (await counted(page)).filter((i) => i.name === 'Zzyzx Table Red').length).toBe(1);
    await page.waitForTimeout(300);
    expect(db.t.kount_pending_items.length).toBe(before);
  });

  test('B6 closing the scanner while the camera starts leaves no fallback running', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(async () => {
      let rejectCam;
      navigator.mediaDevices.getUserMedia = () => new Promise((res, rej) => { rejectCam = rej; });
      let inits = 0, starts = 0, stops = 0;
      Quagga.init = (cfg, cb) => { inits++; if (cb) cb(null); };
      Quagga.start = () => { starts++; };
      Quagga.stop = () => { stops++; };
      openBarcodeScanner();
      closeBarcodeScanner();
      rejectCam(new Error('NotAllowedError'));
      await new Promise((r) => setTimeout(r, 50));
      const afterCatch = { inits, starts };
      // Quagga's init answering after a close stops it instead of starting.
      barcodeActive = false;
      const stopsBefore = stops;
      openQuaggaBarcodeScanner();
      return { afterCatch, starts, stoppedOnInit: stops > stopsBefore };
    });
    expect(r.afterCatch).toEqual({ inits: 0, starts: 0 });
    expect(r.starts).toBe(0);
    expect(r.stoppedOnInit).toBe(true);
  });

  test('B6 close + reopen while the first camera is still starting: the stale stream is stopped, not adopted', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(async () => {
      const pending = [];
      navigator.mediaDevices.getUserMedia = () => new Promise((res) => { pending.push(res); });
      const mkStream = (tag) => {
        const t = { tag, stopped: false, kind: 'video', stop() { this.stopped = true; }, getCapabilities: () => ({}), applyConstraints: async () => {} };
        return { tag, track: t, getTracks: () => [t], getVideoTracks: () => [t] };
      };
      openBarcodeScanner();          // session 1 — camera prompt pending
      closeBarcodeScanner();
      openBarcodeScanner();          // session 2 — also pending
      const s1 = mkStream('s1');
      pending[0](s1);                // session 1's camera arrives late
      await new Promise((r) => setTimeout(r, 50));
      const adopted = nativeBarcodeStream && nativeBarcodeStream.tag;
      closeBarcodeScanner();
      return { s1Stopped: s1.track.stopped, adopted: adopted || null, interval: nativeScanInterval };
    });
    expect(r.s1Stopped).toBe(true);
    expect(r.adopted).toBeNull();
    expect(r.interval).toBeNull();
  });

  test('B7 a camera that never shows a picture says so instead of a dead shutter', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => { navigator.mediaDevices.getUserMedia = async () => new MediaStream(); });
    await page.evaluate(() => openPhotoCapture());
    await expect(page.locator('#photoCaptureBtn')).toBeDisabled();
    await expect(page.locator('.toast')).toContainText(/not showing a picture/i, { timeout: 8000 });
    await expect(page.locator('#photoCaptureBtn')).toBeDisabled();
    await page.evaluate(() => closePhotoCapture());
  });

  test('B7 the shutter waits for a live stream; closing detaches it', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await useCanvasCamera(page);
    await page.evaluate(() => {
      const orig = navigator.mediaDevices.getUserMedia;
      navigator.mediaDevices.getUserMedia = () => new Promise((res) => { window.__releaseCam = () => res(orig()); });
    });
    await page.evaluate(() => openPhotoCapture());
    await expect(page.locator('#photoCaptureBtn')).toBeDisabled();
    await page.evaluate(() => capturePhoto());    // a tap that slips through does nothing
    await expect(page.locator('#photoReviewModal')).toHaveClass(/hide/);
    await page.evaluate(() => window.__releaseCam());
    await expect(page.locator('#photoCaptureBtn')).toBeEnabled({ timeout: 5000 });
    await page.evaluate(() => closePhotoCapture());
    expect(await page.evaluate(() => document.getElementById('photoVideo').srcObject)).toBeNull();
    await expect(page.locator('#photoCaptureBtn')).toBeDisabled();
  });

  test('B8 a stale local UPC cache entry is ignored; a cached link never overrides a retyped name', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.route(/api\.upcitemdb\.com/, (route) => route.fulfill({ status: 404, body: '{}' }));
    // Archived master in the old per-device cache.
    await page.evaluate((arch) => { upcCache['5060071510880'] = { title: 'Belvedere 1L (old)', category: 'spirits', masterId: arch }; },
      M.arch);
    await page.evaluate(() => handleBarcodeResult('5060071510880'));
    await expect(page.locator('#barcodeEntryModal')).toBeVisible();
    await expect(page.locator('#barcodeLookupStatus')).toContainText(/not found/i);
    await expect(page.locator('#barcodeName')).toHaveValue('');
    expect(await page.evaluate(() => upcCache['5060071510880'] || null)).toBeNull();
    await page.evaluate(() => closeBarcodeEntry());

    // A valid cached link, but the counter typed a different product.
    await page.evaluate((belv) => {
      upcCache['5060071510897'] = { title: 'Belvedere 1L', category: 'spirits', masterId: belv };
      openBarcodeEntryModal('5060071510897', upcCache['5060071510897']);
    }, M.belv);
    await expect(page.locator('#barcodeName')).toHaveValue('Belvedere 1L');
    await page.fill('#barcodeName', 'Campari 1L');
    await page.locator('#barcodeEntryModal').getByRole('button', { name: 'Add to count', exact: true }).click();
    const all = await counted(page);
    expect(all.filter((i) => i.masterId === M.belv)).toHaveLength(0);
    expect(all.filter((i) => i.masterId === M.campari)).toHaveLength(1);
  });

  test('item 2: on the bundled items.json fallback (or before the live catalog) the UPC cache is left alone', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const GONE = '99999999-0000-4000-8000-000000000000';
    const r = await page.evaluate((gone) => {
      const out = {};
      upcCache['5060071510903'] = { title: 'Some Gin', category: 'spirits', masterId: gone };
      itemMasterIsStaleFallback = true;
      out.fallbackKept = !!usableUpcCacheEntry('5060071510903') && !!upcCache['5060071510903'];
      itemMasterIsStaleFallback = false;
      supabaseLoaded = false;
      out.notLoadedKept = !!usableUpcCacheEntry('5060071510903') && !!upcCache['5060071510903'];
      supabaseLoaded = true;
      out.liveDropped = usableUpcCacheEntry('5060071510903') === null && !upcCache['5060071510903'];
      return out;
    }, GONE);
    expect(r).toEqual({ fallbackKept: true, notLoadedKept: true, liveDropped: true });
  });

  test('B10 manual add: retyping drops the picked SKU, category resets, a UUID is never saved as a UPC', async ({ page, db }) => {
    await startAuditAs(page, 'corporate');
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.fill('#manualName', 'Belv');
    await page.locator('#manualSuggestions div', { hasText: 'Belvedere 1L' }).first().click();
    // The pick links the master, but its catalog id is never shown as a SKU
    // (wording batch, spec 40 W3).
    const pickedId = () => page.evaluate(() => document.getElementById('manualName').dataset.masterId || '');
    await expect(page.locator('#manualSku')).toHaveValue('');
    expect(await pickedId()).toBe(M.belv);
    await page.fill('#manualName', 'Brand New Gin 700ml');
    await expect(page.locator('#manualSku')).toHaveValue('');
    expect(await pickedId()).toBe('');

    // Even a UUID typed/pasted into SKU is not written as a barcode.
    await page.fill('#manualSku', M.belv);
    await page.locator('#manualCreateBtn').click();
    await expect.poll(() => db.t.master_items.filter((m) => /Brand New Gin/.test(m.name)).length).toBe(1);
    await page.waitForTimeout(300);
    const created = db.t.master_items.find((m) => /Brand New Gin/.test(m.name));
    expect(db.t.master_item_upcs.filter((u) => u.master_item_id === created.id)).toHaveLength(0);

    await page.selectOption('#manualCategory', 'beer');
    await page.evaluate(() => { closeManualEntry(); openManualEntry(); });
    await expect(page.locator('#manualCategory')).toHaveValue('wine');
  });

  test('B11 a photo new product is stored only when "add as new" is chosen', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const NEAR = { name: 'Belveder', brand: '', category: 'spirits', vintage: '', size: '', details: '', matchedId: null };
    const fill = () => page.evaluate((p) => window.populatePhotoFormFromParsed(p, document.getElementById('parsingStatus')), NEAR);
    const submit = () => page.evaluate(() => { window.capturedPhotoData = 'data:image/jpeg;base64,AAAA'; return submitPhotoEntry(); });
    const picker = page.locator('#fuzzyMatchPickerModal');
    const stored = () => db.t.kount_pending_items.filter((p) => p.name === 'Belveder').length;

    await fill(); await submit();
    await picker.waitFor({ state: 'visible' });
    await picker.getByRole('button', { name: 'Cancel' }).click();
    await page.waitForTimeout(300);
    expect(stored()).toBe(0);

    await fill(); await submit();
    await picker.waitFor({ state: 'visible' });
    await picker.locator('.fuzzy-pick', { hasText: 'Belvedere 1L' }).first().click();
    await page.waitForTimeout(300);
    expect(stored()).toBe(0);
    expect((await counted(page)).filter((i) => i.masterId === M.belv)).toHaveLength(1);

    await fill(); await submit();
    await picker.waitFor({ state: 'visible' });
    await picker.locator('#fuzzyAddNewBtn').click();
    await expect.poll(stored).toBe(1);
  });
});
