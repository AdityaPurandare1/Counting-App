/* v2.31 — two rules shared with compute_avt_for_audit (migration 0131) and the
 * admin (v0.78).
 *
 * 1) A 'verified' recount whose qty just repeats its own Count-1 snapshot
 *    overrides nothing: the entries stand. The manager "Verify all zones"
 *    cascade copies a stale snapshot into the recount qty — A-595 Stony Hill
 *    verified 0/0 against 31 counted wiped 31 bottles from the report. A
 *    verified row with a NEW number is a real correction (P-843 Volcan, Count 1
 *    23, verified 6, "Miscounted") and still overrides, as do 'corrected' rows
 *    and rows with no result. An unknown count1 counts as "not equal".
 *    FAIL-BEFORE (v2.30): the 0/0 row replaced the 31 with 0.
 *
 * 2) Category spelling variants ('liquor cost', 'beverage', 'bev', ...) are in
 *    scope, so the catalog load stops dropping those bottles, and each one is
 *    filed (label / name / colour) with its canonical form.
 *    FAIL-BEFORE (v2.30): a 'beverage' / 'liquor cost' row never reached search.
 *
 * Seeding for the recount tests mirrors 38-lifecycle-fixes: the mock's compute
 * flags Belvedere 1L, so counting it per zone and closing Count 1 yields one
 * recount row per zone.
 */
const { test, expect, startAuditAs, addManual, switchZone, M } = require('../fixtures');

const ITEM = 'Belvedere 1L';
const keyFor = (zone) => ITEM + '|' + zone;

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

async function recordRecount(page, key, { qty, result, reason }) {
  await page.evaluate((k) => openRecountEntry(k), key);
  await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
  await page.fill('#guidedQty', String(qty));
  await page.selectOption('#recountResultSelect', result);
  await page.fill('#recountReasonInput', reason);
  await page.locator('#guidedConfirmBtn').click();
  await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
}

async function captureCsv(page, fnSrc) {
  return page.evaluate(async (src) => {
    let blob = null;
    const origCreate = URL.createObjectURL;
    const origClick = HTMLAnchorElement.prototype.click;
    URL.createObjectURL = (b) => { blob = b; return 'blob:test'; };
    HTMLAnchorElement.prototype.click = function () {};
    try { (0, eval)(src); } finally {
      URL.createObjectURL = origCreate;
      HTMLAnchorElement.prototype.click = origClick;
    }
    if (!blob) return null;
    const t = await blob.text();
    return t.charCodeAt(0) === 0xFEFF ? t.slice(1) : t;
  }, fnSrc);
}

test.describe('v2.31 a verified recount that repeats Count 1 overrides nothing', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.getCorrectedTotals)).toBe('function');
  });

  test('getCorrectedTotals: the four cases', async ({ page }) => {
    const r = await page.evaluate(() => {
      const STONY = 'm-stony', VOLCAN = 'm-volcan';
      const entry = (name, masterId, qty) => ({ id: name + qty, name, masterId, qty });
      const rec = (itemName, masterId, zone, count1Qty, recountQty, auditResult) =>
        ({ itemName, masterId, zone, count1Qty, recountQty, auditResult, status: 'done' });
      const run = (counts, list) => {
        const recounts = {};
        list.forEach((x, i) => { recounts[x.itemName + '|' + x.zone + '|' + i] = x; });
        const t = getCorrectedTotals({ counts, recounts });
        return { total: t.totalQty, corrections: t.corrections };
      };
      const stony = { Storage: [entry('Stony Hill', STONY, 27)], Down: [entry('Stony Hill', STONY, 4)] };
      const volcan = { Bar: [entry('Volcan', VOLCAN, 23)] };
      return {
        // A-595: the cascade copied a 0/0 snapshot against 31 counted.
        verifiedSame:      run(stony,  [rec('Stony Hill', STONY, 'Storage', 0, 0, 'verified')]),
        // Ace of Spades shape: whole-item 40/40 from a snapshot that summed sizes.
        verifiedSameWhole: run(stony,  [rec('Stony Hill', STONY, '', 40, 40, 'verified')]),
        // P-843: verified with a new number is a correction.
        verifiedNew:       run(volcan, [rec('Volcan', VOLCAN, 'Bar', 23, 6, 'verified')]),
        verifiedNoCount1:  run(volcan, [rec('Volcan', VOLCAN, 'Bar', null, 6, 'verified')]),
        verifiedTextNums:  run(volcan, [rec('Volcan', VOLCAN, 'Bar', '23', 23, 'verified')]),
        corrected:         run(volcan, [rec('Volcan', VOLCAN, 'Bar', 23, 6, 'corrected')]),
        correctedSame:     run(volcan, [rec('Volcan', VOLCAN, 'Bar', 5, 5, 'corrected')]),
        nullResult:        run(volcan, [rec('Volcan', VOLCAN, 'Bar', 23, 6, null)]),
        nullResultSame:    run(volcan, [rec('Volcan', VOLCAN, 'Bar', 5, 5, null)]),
      };
    });
    expect(r.verifiedSame).toEqual({ total: 31, corrections: 0 });
    expect(r.verifiedSameWhole).toEqual({ total: 31, corrections: 0 });
    expect(r.verifiedNew).toEqual({ total: 6, corrections: 1 });
    expect(r.verifiedNoCount1).toEqual({ total: 6, corrections: 1 });
    expect(r.verifiedTextNums).toEqual({ total: 23, corrections: 0 });
    expect(r.corrected).toEqual({ total: 6, corrections: 1 });
    expect(r.correctedSame).toEqual({ total: 5, corrections: 1 });
    expect(r.nullResult).toEqual({ total: 6, corrections: 1 });
    expect(r.nullResultSame).toEqual({ total: 5, corrections: 1 });
  });

  test('a newer repeating row does not hide an older correction', async ({ page }) => {
    const total = await page.evaluate(() => {
      const counts = { Bar: [{ id: 'e1', name: 'Volcan', masterId: 'm-volcan', qty: 23 }] };
      const recounts = {
        a: { itemName: 'Volcan', masterId: 'm-volcan', zone: 'Bar', count1Qty: 23, recountQty: 6, auditResult: 'corrected', status: 'done', createdAt: '2026-10-20T10:00:00Z' },
        b: { itemName: 'Volcan', masterId: 'm-volcan', zone: 'Bar', count1Qty: 23, recountQty: 23, auditResult: 'verified', status: 'done', createdAt: '2026-10-21T10:00:00Z' },
      };
      return getCorrectedTotals({ counts, recounts }).totalQty;
    });
    expect(total).toBe(6);
  });

  test('recorded in the app: verified with a new number corrects, verified with the same number does not', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);

    await recordRecount(page, keyFor('Liquor Room'), { qty: 1, result: 'verified', reason: 'Miscounted' });
    await recordRecount(page, keyFor('Bar'), { qty: 2, result: 'verified', reason: 'matches' });
    await expect.poll(() => (db.t.kount_recounts.find((r) => r.item_name === ITEM && r.zone === 'Liquor Room') || {}).count2_qty).toBe(1);
    const lr = db.t.kount_recounts.find((r) => r.item_name === ITEM && r.zone === 'Liquor Room');
    expect([lr.audit_result, lr.count1_qty, lr.count2_qty]).toEqual(['verified', 3, 1]);

    const totals = await page.evaluate(() => {
      const t = getCorrectedTotals(appState.audit);
      return { total: t.totalQty, corrections: t.corrections, count1: t.count1Qty };
    });
    expect(totals).toEqual({ total: 3, corrections: 1, count1: 5 });

    await page.evaluate(() => showPage('summary'));
    const stats = page.locator('#summaryStats');
    await expect(stats).toContainText('after recount');
    const rows = await stats.locator('.stat-row').allInnerTexts();
    expect(rows.find((t) => /Total quantity/.test(t))).toMatch(/\b3$/);
    expect(rows.find((t) => /Count 1 quantity/.test(t))).toMatch(/\b5$/);
  });

  test('a stale 0/0 snapshot leaves the counted bottles in the totals and the Count 2 CSV', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);

    // What the "Verify all zones" cascade left behind: the Liquor Room row
    // verified with a 0 snapshot copied into its recount qty. Bar: a verified
    // row with a new number.
    await page.evaluate(({ lrKey, barKey }) => {
      Object.assign(appState.audit.recounts[lrKey], { count1Qty: 0, recountQty: 0, auditResult: 'verified', status: 'done', auditReason: 'Verified via Verify all zones' });
      Object.assign(appState.audit.recounts[barKey], { count1Qty: 2, recountQty: 1, auditResult: 'verified', status: 'done', auditReason: 'Miscounted' });
    }, { lrKey: keyFor('Liquor Room'), barKey: keyFor('Bar') });

    const totals = await page.evaluate(() => {
      const t = getCorrectedTotals(appState.audit);
      return { total: t.totalQty, corrections: t.corrections };
    });
    // Liquor Room's 3 counted stand; Bar is corrected to 1. (v2.30: 0 + 1 = 1.)
    expect(totals).toEqual({ total: 4, corrections: 1 });

    const csv = await captureCsv(page, 'exportCountCSV(2)');
    const belv = csv.split('\n').find((l) => l.startsWith('"Delilah LA","Count 2","Belvedere 1L"'));
    expect(belv).toBeTruthy();
    // ... Recount Qty, Status, Issue Type, Issue Notes
    expect(belv.split(',').slice(-4, -2)).toEqual(['4', 'Recounted']);
  });

  test('a zone-less (whole-item) 0/0 confirmation shows the full count in the Count 2 CSV', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);

    // A-595 Stony Hill shape: one whole-item row, zone null, verified 0/0.
    await page.evaluate(({ lrKey, barKey }) => {
      Object.assign(appState.audit.recounts[lrKey], { zone: null, count1Qty: 0, recountQty: 0, auditResult: 'verified', status: 'done', auditReason: 'Verified — recount matches Count 1' });
      appState.audit.recounts[barKey].status = 'dismissed';
    }, { lrKey: keyFor('Liquor Room'), barKey: keyFor('Bar') });

    const totals = await page.evaluate(() => {
      const t = getCorrectedTotals(appState.audit);
      return { total: t.totalQty, corrections: t.corrections };
    });
    expect(totals).toEqual({ total: 5, corrections: 0 });

    const csv = await captureCsv(page, 'exportCountCSV(2)');
    const belv = csv.split('\n').find((l) => l.startsWith('"Delilah LA","Count 2","Belvedere 1L"'));
    expect(belv).toBeTruthy();
    expect(belv.split(',').slice(-4, -2)).toEqual(['5', 'Recounted']);
  });
});

test.describe('v2.31 category spelling variants are in scope', () => {
  const VARIANTS = ['liquor cost', 'wine cost', 'beer cost', 'n/a beverage cost', 'beverage', 'bev', 'bar consumables', 'bar supplies'];
  const EXISTING = ['Wine Cost', 'wine', 'Wine', 'Liquor Cost', 'liquor', 'Liquor', 'Beer Cost', 'beer',
    'N/A Beverage Cost', 'non_alcoholic_beverage', 'Bar Consumables', 'bar_consumable', 'Bar Supplies'];

  test('the list keeps every existing value and quotes each one in the PostgREST filter', async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    const r = await page.evaluate(() => ({ list: IN_SCOPE_CATEGORIES.slice(), filter: IN_SCOPE_FILTER }));
    for (const c of [...EXISTING, ...VARIANTS]) expect(r.list).toContain(c);
    expect(new Set(r.list).size).toBe(r.list.length);
    // category=in.("a","b c","n/a d") — every value double-quoted, so the
    // spaces and slashes can't split or end a value.
    expect(r.filter.startsWith('category=in.(')).toBe(true);
    expect(r.filter.endsWith(')')).toBe(true);
    const inner = r.filter.slice('category=in.('.length, -1);
    const quoted = inner.match(/"(?:[^"\\]|\\.)*"/g) || [];
    expect(quoted.join(',')).toBe(inner);
    expect(quoted.map((q) => q.slice(1, -1))).toEqual(r.list);
    expect(inner).toContain('"n/a beverage cost"');
    expect(inner).toContain('"bar supplies"');
  });

  test('each variant is filed (label, name, colour) like its canonical form', async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    const pairs = [
      ['liquor cost', 'Liquor Cost'], ['wine cost', 'Wine Cost'], ['beer cost', 'Beer Cost'],
      ['n/a beverage cost', 'N/A Beverage Cost'], ['beverage', 'N/A Beverage Cost'], ['bev', 'N/A Beverage Cost'],
      ['bar consumables', 'Bar Consumables'], ['bar supplies', 'Bar Supplies'],
    ];
    const r = await page.evaluate((ps) => ps.map(([v, c]) => {
      const show = (x) => { const g = guessCategory(x); return [g, getCategoryLabel(g), getCategoryName(g), getCategoryColor(g)]; };
      return { v, variant: show(v), canonical: show(c) };
    }), pairs);
    for (const x of r) expect(x.variant, x.v).toEqual(x.canonical);
    expect(r.find((x) => x.v === 'liquor cost').variant.slice(0, 3)).toEqual(['spirits', 'SPR', 'Spirits']);
  });

  test('catalog rows with variant categories reach search; out-of-scope rows still do not', async ({ page, db }) => {
    const row = (n, name, category) => ({
      id: '99999999-9999-4999-8999-9999999944' + String(n).padStart(2, '0'), organization_id: 'org-1', name,
      category, subcategory: null, base_size: 750, base_unit: 'ml', is_active: true,
      created_at: '2026-11-02T00:00:00Z', product_id: null,
    });
    VARIANTS.forEach((c, i) => db.t.master_items.push(row(i, 'Zqprobe ' + c.replace('/', '') + ' 750ml', c)));
    db.t.master_items.push(row(90, 'Zqprobe grocery 750ml', 'Grocery and Dry Goods Cost'));
    db.t.master_items.push(row(91, 'Zqprobe beverages 750ml', 'beverages'));   // near miss: not in the list

    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() =>
      typeof window.searchItemMaster === 'function' ? window.searchItemMaster('zqprobe', 50).length : 0),
    { timeout: 10000 }).toBe(VARIANTS.length);
    const hits = await page.evaluate(() => window.searchItemMaster('zqprobe', 50).map((i) => [i.name, i.category]));
    const byName = Object.fromEntries(hits);
    expect(Object.keys(byName).sort()).toEqual(VARIANTS.map((c) => 'Zqprobe ' + c.replace('/', '') + ' 750ml').sort());
    expect(byName['Zqprobe liquor cost 750ml']).toBe('spirits');
    expect(byName['Zqprobe beverage 750ml']).toBe(byName['Zqprobe na beverage cost 750ml']);
    // The seed catalog is still there.
    expect(await page.evaluate(() => window.searchItemMaster('belvedere', 5).length)).toBeGreaterThan(0);
  });
});
