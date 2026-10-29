/* Wording / label fixes (review batch, 2026-10-29): what counters and
 * managers read — toasts, labels, CSV headers/cells, banners — plus debug
 * detail that is now kept for corporate (or the console) only.
 * One focused test per item where the mock can drive it.
 */
const { test, expect, startAuditAs, loginAs, waitForCatalog, addManual, M } = require('../fixtures');

const SUPA = 'https://mnraeesscqsaappkaldb.supabase.co';

/* Capture what an export function would download (same as spec 38). */
async function captureCsv(page, src) {
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
    return t.charCodeAt(0) === 0xFEFF ? t.slice(1) : t;
  }, src);
}

/* Record every toast. showToast is a global function, so the app's own
   calls go through this wrapper. */
async function recordToasts(page) {
  await page.evaluate(() => {
    window.__toasts = [];
    const orig = window.showToast;
    window.showToast = function (m, t) { window.__toasts.push({ m: String(m), t: t || '' }); return orig.apply(this, arguments); };
  });
}
const toasts = (page) => page.evaluate(() => window.__toasts.slice());

test.describe('wording fixes', () => {
  test('W1 Count 1 CSV during Count 1 carries issue data, issue words, and plain headers', async ({ page }) => {
    await startAuditAs(page, 'manager');
    expect(await page.evaluate(() => appState.audit.count1Data)).toBeNull();
    const csv = await captureCsv(page, `
      (function () {
        const z = appState.currentZone;
        appState.audit.counts[z].push({ id: 'w1a', name: 'Belvedere 1L', masterId: '${M.belv}', qty: 2, issue: 'damaged', notes: 'chipped' });
        appState.audit.counts[z].push({ id: 'w1b', name: 'Mystery Gin', qty: 1, issue: 'not-in-craftable', notes: '' });
        appState.avtData = [{ venueId: appState.audit.venueId || appState.currentVenue.id, itemName: 'Belvedere 1L',
          category: 'spirits', store: 'Bar', actual: 2, theo: 3, variance: -1, cuPrice: 30, varianceValue: -30, variancePct: -33.3 }];
        exportCountCSV(1);
      })();`);
    const lines = csv.split('\n');
    expect(lines[0]).toContain('"Actual Qty","Theo Qty","Qty Variance"');
    expect(csv).not.toContain('Craftable');
    const belv = lines.find((l) => l.startsWith('"Delilah LA","Count 1","Belvedere 1L"'));
    expect(belv).toMatch(/"damaged","chipped"$/);
    const gin = lines.find((l) => l.includes('"Mystery Gin"'));
    expect(gin).toContain('"Count 1 (App only)"');
    expect(gin).toContain('"not in inventory"');
    expect(csv).not.toContain('No issues reported');
    expect(csv).not.toContain('not-in-craftable');
    expect(lines).toContain('"not in inventory",1,"Mystery Gin"');
  });

  test('W2 server errors become plain sentences; debug footer + Copy are corporate-only', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate(() => ({
      jwt: friendlyError({ message: 'HTTP 401: {"code":"PGRST301","message":"JWT expired"}' }),
      dup: friendlyError('HTTP 409: {"code":"23505","message":"duplicate key value violates unique constraint"}'),
      dupCtx: friendlyError('duplicate key', null, { duplicate: 'Already pending' }),
      srv: friendlyError('HTTP 503: upstream connect error'),
      net: friendlyError(new TypeError('Failed to fetch')),
      other: friendlyError('HTTP 400: {"code":"22P02"}', 'Fallback text'),
    }));
    expect(r.jwt).toBe('Your session expired — sign in again');
    expect(r.dup).toBe('That barcode is already linked to another item');
    expect(r.dupCtx).toBe('Already pending');
    expect(r.srv).toBe('Couldn’t reach the server — try again');
    expect(r.net).toBe('Couldn’t reach the server — try again');
    expect(r.other).toBe('Fallback text');

    // A real UPC save rejected with an expired JWT.
    await page.route(SUPA + '/rest/v1/upc_mappings', (route) => route.fulfill({
      status: 401, contentType: 'application/json', body: '{"code":"PGRST301","message":"JWT expired"}' }));
    await recordToasts(page);
    await page.evaluate((id) => linkUPCToItem('5012345678900', itemMaster.find((i) => i.id === id)), M.belv);
    const t = await toasts(page);
    expect(t.map((x) => x.m)).toContain('UPC not saved: Your session expired — sign in again');
    expect(t.some((x) => /PGRST|JWT|HTTP/.test(x.m))).toBe(false);
    const log = await page.evaluate(() => appState.audit.log.map((e) => e.text).join('\n'));
    expect(log).not.toMatch(/PGRST|HTTP 401/);

    // The banner, as a manager: plain sentence, no role/status/path, no Copy.
    const banner = page.locator('#lastUpcErrorBanner');
    await expect(banner).toContainText('Your session expired');
    await expect(banner).toContainText('5012345678900');
    await expect(banner).not.toContainText('PGRST301');
    await expect(banner).not.toContainText('role ');
    await expect(banner).not.toContainText('ADD path');
    await expect(banner.getByRole('button', { name: 'Copy' })).toHaveCount(0);

    // Corporate still gets the raw detail to debug with.
    await page.evaluate(() => { appState.user.role = 'corporate'; renderLastUpcErrorBanner(); });
    await expect(banner).toContainText('PGRST301');
    await expect(banner).toContainText('ADD path');
    await expect(banner.getByRole('button', { name: 'Copy' })).toHaveCount(1);
  });

  test('W3 internal ids never show as a SKU (Issues page, raw CSV, manual pick field)', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const v = await page.evaluate(() => ['11111111-1111-4111-8111-111111111111', 'CUS1730000000000_ab1',
      'SKU0042', 'IM0042', 'MI17', '012345678905', 'ABC-123', ''].map(visibleSku));
    expect(v).toEqual(['', '', '', '', '', '012345678905', 'ABC-123', '']);

    await page.evaluate((belv) => {
      const z = appState.currentZone;
      appState.audit.counts[z].push({ id: 'w3a', name: 'Uuid Item', masterId: belv, sku: belv, qty: 1, method: 'guided', issue: 'damaged' });
      appState.audit.counts[z].push({ id: 'w3b', name: 'Phone Item', sku: 'CUS1730000000000_ab1', qty: 1, method: 'manual', issue: 'damaged' });
      appState.audit.counts[z].push({ id: 'w3c', name: 'Scanned Item', sku: '012345678905', qty: 1, method: 'barcode', issue: 'damaged' });
      syncIssuesToLog();
    }, M.belv);

    await page.evaluate(() => showPage('issues'));
    const issues = page.locator('#page-issues');
    await expect(issues).toContainText('Scanned Item');
    await expect(issues).toContainText('SKU: 012345678905');
    await expect(issues).not.toContainText(M.belv);
    await expect(issues).not.toContainText('CUS1730000000000');
    const issuesCsv = await captureCsv(page, 'exportIssuesCSV()');
    expect(issuesCsv).not.toContain(M.belv);
    expect(issuesCsv).not.toContain('CUS1730000000000');
    expect(issuesCsv).toContain('012345678905');

    await page.evaluate(() => showPage('summary'));
    const raw = await captureCsv(page, 'exportCSV()');
    expect(raw).not.toContain(M.belv);
    expect(raw).not.toContain('CUS1730000000000');
    expect(raw.split('\n').find((l) => l.startsWith('"Scanned Item"'))).toContain('"012345678905"');

    // Picking a catalog item in Manual shows no id in the SKU field, but the
    // entry still records it (as the guided path does).
    await page.evaluate(() => showPage('count'));
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.evaluate((id) => selectMasterItem(id), M.campari);
    await expect(page.locator('#manualSku')).toHaveValue('');
    await page.fill('#manualQty', '2');
    await page.locator('#manualModal').getByRole('button', { name: 'Add to count', exact: true }).click();
    await page.locator('#manualModal').waitFor({ state: 'hidden' });
    const e = await page.evaluate((id) => appState.audit.counts[appState.currentZone].find((x) => x.masterId === id), M.campari);
    expect(e.sku).toBe(M.campari);
  });

  test('W4 the guided item header shows the category name and no PAR 0', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    const meta = page.locator('#guidedHeroMeta');
    await expect(meta).toHaveText('Spirits');
    expect(await page.evaluate(() => [getCategoryName('wine'), getCategoryName('beer'), getCategoryName('???')]))
      .toEqual(['Wine', 'Beer', 'Other']);
  });

  test('W5 refresh does not claim success when the live catalog is unreachable', async ({ page }) => {
    await loginAs(page, 'manager');
    await waitForCatalog(page);
    const fail = /\/rest\/v1\/master_items\?/;
    await page.route(fail, (route) => route.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"boom"}' }));
    await recordToasts(page);
    await page.evaluate(() => kountRefresh());
    let t = await toasts(page);
    const last = t[t.length - 1];
    expect(last.t).toBe('warn');
    expect(last.m).toMatch(/Couldn’t reach the live inventory — still using the offline list/);
    expect(t.some((x) => /Inventory refreshed/.test(x.m))).toBe(false);
    expect(t.some((x) => /pull/i.test(x.m))).toBe(false);
    expect(await page.evaluate(() => itemMasterIsStaleFallback)).toBe(true);

    // Back online: now it may say so.
    await page.unroute(fail);
    await page.evaluate(() => { window.__toasts = []; return kountRefresh(); });
    t = await toasts(page);
    expect(t[t.length - 1]).toEqual(expect.objectContaining({ t: 'success' }));
    expect(t[t.length - 1].m).toMatch(/^Inventory refreshed \(/);

    // The empty-catalog banner names no internal source and no pull gesture.
    const text = await page.evaluate(() => {
      const saved = itemMaster;
      itemMaster = [];
      try { validateItemMaster('supabase'); return document.getElementById('kountMasterWarn').textContent; }
      finally { itemMaster = saved; hideMasterBanner(); }
    });
    expect(text).toBe('Inventory list is empty. Close and reopen the app to try again.');
  });

  test('W6 background catalog reloads are silent; the first/manual load still toasts', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await recordToasts(page);
    await page.evaluate(() => loadItemMaster({ silent: true }));
    expect((await toasts(page)).filter((x) => /items loaded/.test(x.m))).toEqual([]);
    await page.evaluate(() => loadItemMaster());
    expect((await toasts(page)).map((x) => x.m)).toContainEqual(expect.stringMatching(/items loaded from database$/));

    // Already on the offline list: a silent retry that falls back again stays quiet.
    await page.route(/\/rest\/v1\/master_items\?/, (route) => route.fulfill({ status: 500, contentType: 'application/json', body: '{}' }));
    await page.evaluate(() => { itemMasterIsStaleFallback = true; window.__toasts = []; return loadItemMaster({ silent: true }); });
    expect(await toasts(page)).toEqual([]);
  });

  test('W7 a "warning" toast is amber like "warn"', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const bg = await page.evaluate(() => ['warn', 'warning', 'info'].map((t) => {
      showToast('x', t, 60000);
      return getComputedStyle(document.querySelector('.toast')).backgroundColor;
    }));
    expect(bg[1]).toBe(bg[0]);
    expect(bg[2]).not.toBe(bg[0]);
  });

  test('W8 phases read as words in the header badge, locked view and Summary', async ({ page }) => {
    await startAuditAs(page, 'manager');
    expect(await page.evaluate(() => ['count1', 'review', 'count2', 'final', null].map(phaseLabel)))
      .toEqual(['Count 1', 'Recount review', 'Count 2 (recount)', 'Final', 'Count 1']);
    await page.evaluate(() => showPage('summary'));
    const phaseRow = page.locator('#summaryStats .stat-row', { hasText: 'Phase' });
    await expect(phaseRow).toContainText('Count 1');
    await expect(phaseRow).not.toContainText('count1');

    await page.evaluate(() => { appState.audit.countPhase = 'count2'; showPage('count'); });
    await expect(page.locator('#headerAuditBadge')).toHaveText('Count 2 (recount)');
    const overlayPhase = page.locator('#auditLockedOverlay .stat-row', { hasText: 'Phase' });
    await expect(overlayPhase).toContainText('Count 2 (recount)');
  });

  test('W9 roles read as words', async ({ page }) => {
    await loginAs(page, 'counter');
    await expect(page.locator('#venueSubtitle')).toContainText('Casey (Counter |');
    expect(await page.evaluate(() => ['corporate', 'manager', 'admin', 'venue_manager', 'counter'].map(roleLabel)))
      .toEqual(['Corporate', 'Manager', 'Admin', 'Venue manager (view only)', 'Counter']);
  });

  test('W10 one item / one issue read singular', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 1);
    await page.evaluate(() => { appState.audit.counts[appState.currentZone][0].issue = 'damaged'; showPage('summary'); });
    const zones = page.locator('#zoneSummary');
    await expect(zones).toContainText('1 item');
    await expect(zones).toContainText('1 issue');
    await expect(zones).not.toContainText('1 items');
    await expect(zones).not.toContainText('1 issues');
    // Cancel confirm on a one-item audit.
    await page.evaluate(() => { showPage('count'); endAuditEarly(); });
    await expect(page.locator('#confirmMsg')).toHaveText('Cancel this audit? 1 item has been counted and will be discarded. This cannot be undone.');
  });

  test('W11 barcode-link suggestions read UPCs from the mappings cache', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const r = await page.evaluate((belv) => {
      openBarcodeEntryModal('0890000000001', null);
      const status = document.getElementById('barcodeLookupStatus').textContent;
      upcMappingsCache['5000000000017'] = { title: 'Belvedere 1L', category: 'spirits', masterId: belv, barcode: '5000000000017' };
      upcMappingsCacheLoadedAt = Date.now();
      onBarcodeNameSearch('Belvedere');
      const rows = Array.from(document.querySelectorAll('#barcodeNameSuggestions .barcode-suggestion')).map((d) => d.textContent);
      selectBarcodeItem(belv);
      const banner = document.getElementById('barcodeUpcLinkText').textContent;
      // Cache not loaded yet: no badge either way.
      upcMappingsCacheLoadedAt = 0;
      onBarcodeNameSearch('Belvedere');
      const unknown = document.getElementById('barcodeNameSuggestions').textContent;
      return { status, rows, banner, unknown };
    }, M.belv);
    expect(r.status).toBe('Looking up this barcode online…');
    expect(r.rows.find((t) => t.includes('Belvedere 1L'))).toContain('has UPC');
    expect(r.rows.find((t) => t.includes('Belvedere 1.75L'))).toContain('no UPC');
    // The seed already maps one barcode to Belvedere 1L; ours is the second.
    expect(r.banner).toMatch(/^Already has UPC \d+, 5000000000017 — UPC 0890000000001 will be added on confirm$/);
    expect(r.unknown).not.toMatch(/(has|no) UPC/);
  });

  test('W13 photo: a readable label line, and a generic failure message', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate(() => window.populatePhotoFormFromParsed({ name: 'Bordeaux Supérieur', brand: 'Domaine des Justices',
      category: 'wine', vintage: '2020', size: '750ml', details: '', matchedId: null }, document.getElementById('parsingStatus')));
    await expect(page.locator('#ocrRawText')).toHaveText('Read from label: Domaine des Justices · Bordeaux Supérieur · 2020 · 750ml');

    await page.route(SUPA + '/functions/v1/parse-bottle-label', (route) => route.fulfill({
      status: 500, contentType: 'application/json', body: '{"error":"anthropic overloaded"}' }));
    const r = await page.evaluate(async () => {
      let seen = null;
      window.parsePhotoLabelTesseract = async () => { seen = document.getElementById('parsingStatus').textContent; };
      await parsePhotoLabel('data:image/jpeg;base64,AAAA', null);
      return { seen, log: appState.audit.log.map((e) => e.text) };
    });
    expect(r.seen).toBe('Couldn’t read the label automatically — trying another way…');
    expect(r.log).toContain('Photo label read failed — used the backup reader');
    expect(r.log.join('\n')).not.toMatch(/500|parse-bottle-label|overloaded/);
  });

  test('W14 the variance empty state says the report comes with Count 1', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const src = await page.evaluate(() => renderVariancePage.toString());
    expect(src).toContain('computed automatically when Count 1 closes');
    expect(src).not.toContain('when Count 2 closes');
  });

  test('W15 pending UPC approvals show only for roles that can approve', async ({ page }) => {
    await loginAs(page, 'counter');
    await page.evaluate(() => renderPendingApprovals());
    await expect(page.locator('#pendingApprovalsSection')).toBeHidden();
    await expect(page.locator('#pendingApprovalsList')).toBeEmpty();

    await loginAs(page, 'manager');
    await page.evaluate(() => { showPage('summary'); return renderPendingApprovals(); });
    await expect(page.locator('#pendingApprovalsSection')).toBeVisible();
    await expect(page.locator('#pendingApprovalsList')).toContainText('No pending UPC approvals');
  });

  test('W16 the activity log says what happened to a UPC, not the decision code', async ({ page }) => {
    await startAuditAs(page, 'manager');
    expect(await page.evaluate(() => ['blank-add-auto', 'admin-add', 'admin-overwrite', 'counter-update', 'manager-update'].map(upcLinkReasonLabel)))
      .toEqual(['linked', 'linked by admin', 'reassigned by admin', 'sent for admin approval', 'sent for admin approval']);
    await page.evaluate((id) => linkUPCToItem('5012345678900', itemMaster.find((i) => i.id === id)), M.belv);
    await expect.poll(() => page.evaluate(() => appState.audit.log.map((e) => e.text)))
      .toContainEqual('UPC 5012345678900 linked to Belvedere 1L');
    const log = await page.evaluate(() => appState.audit.log.map((e) => e.text).join('\n'));
    expect(log).not.toMatch(/blank-add-auto|-update\)/);
  });

  test('W17 the Ask AI greeting matches what it does', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const greet = page.locator('#aiChatMessages > div').first();
    await expect(greet).toContainText('Tips on searching, scanning & counting');
    await expect(greet).not.toContainText('Finding items in your inventory');
  });
});
