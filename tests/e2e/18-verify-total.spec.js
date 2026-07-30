/* v1.98 ONE-TAP VERIFY + GROUPED RECOUNT RENDER.
 *
 * verifyItemTotal(itemName) is a manager/corporate cascade: for EVERY per-zone
 * recount row of an item it sets recountQty = that zone's count1Qty, status
 * 'done', auditResult 'verified', and a default auditReason (unless one was
 * already typed), then syncs each row to kount_recounts. This satisfies
 * closeCount2's three hard gates (result + reason + finite qty PER ROW) so the
 * audit can finalize.
 *
 * The recount page (renderRecountPage, v1.98) groups the flat per-(item,zone)
 * rows into one card per item. variance/varianceValue are ITEM-LEVEL values
 * duplicated onto every zone row, so the card must render the bottle figure
 * ONCE from a single row — never summed across zones (which would multiply it).
 *
 * The mock's default compute_avt_for_audit flags Belvedere 1L as HIGH
 * (actual 1 vs theo 6 -> -5 bottles). Counting Belvedere across TWO zones
 * produces two per-zone recount rows for one item — exactly the multi-zone
 * shape these tests need.
 */
const { test, expect, startAuditAs, addManual, switchZone } = require('../fixtures');

/* Count Belvedere in two zones, close Count 1 (compute path), and wait for the
   two per-zone recount rows to materialize. Returns nothing; leaves the page on
   the recount screen with appState.audit.recounts populated. */
async function seedTwoZoneRecount(page, db, qtyA, qtyB) {
  await switchZone(page, 'Liquor Room');                  // pin the first zone
  await addManual(page, 'Belvedere 1L', qtyA);
  await switchZone(page, 'Bar');
  await addManual(page, 'Belvedere 1L', qtyB);            // second zone

  await page.evaluate(() => closeCount1());
  await page.locator('#confirmDialog').waitFor({ state: 'visible' });
  await page.evaluate(() => window.closeConfirm(true));
  await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

  // Two per-zone rows for the one flagged item.
  await expect
    .poll(() => page.evaluate(() =>
      Object.values((appState.audit && appState.audit.recounts) || {})
        .filter((r) => r.itemName === 'Belvedere 1L').length), { timeout: 5000 })
    .toBeGreaterThanOrEqual(2);
}

test.describe('v1.98 verify-total cascade', () => {
  test('verifyItemTotal sets every zone row to its Count-1 qty and finalizes', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db, 3, 2);

    // Sanity: before verifying, the rows are pending with no decision.
    const before = await page.evaluate(() =>
      Object.values(appState.audit.recounts)
        .filter((r) => r.itemName === 'Belvedere 1L')
        .map((r) => ({ status: r.status, recountQty: r.recountQty, auditResult: r.auditResult })));
    expect(before.length).toBeGreaterThanOrEqual(2);
    for (const r of before) {
      expect(r.status).toBe('pending');
      expect(r.recountQty).toBeNull();
      expect(r.auditResult).toBeNull();
    }

    // ---- One-tap verify (direct call). Confirm-gated like other destructive ops.
    await page.evaluate(() => verifyItemTotal('Belvedere 1L'));
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));

    // Every zone row: recountQty === its own count1Qty, verified/done, has reason.
    await expect
      .poll(() => page.evaluate(() =>
        Object.values(appState.audit.recounts)
          .filter((r) => r.itemName === 'Belvedere 1L')
          .every((r) => r.status === 'done')))
      .toBe(true);

    const after = await page.evaluate(() =>
      Object.values(appState.audit.recounts)
        .filter((r) => r.itemName === 'Belvedere 1L')
        .map((r) => ({
          zone: r.zone, count1Qty: r.count1Qty, recountQty: r.recountQty,
          auditResult: r.auditResult, status: r.status, auditReason: r.auditReason,
        })));
    expect(after.length).toBeGreaterThanOrEqual(2);
    // The two zones must carry the distinct per-zone Count-1 quantities (3 and 2),
    // proving the cascade copies each zone's OWN count, not one shared total.
    const c1 = after.map((r) => r.count1Qty).sort((a, b) => a - b);
    expect(c1).toEqual([2, 3]);
    for (const r of after) {
      expect(r.recountQty).toBe(r.count1Qty);          // per-zone, not a shared total
      expect(r.auditResult).toBe('verified');
      expect(r.status).toBe('done');
      expect(String(r.auditReason || '').trim().length).toBeGreaterThan(0);
    }

    // ---- The cascade reached kount_recounts (desktop Recount screen source).
    await expect
      .poll(() => db.t.kount_recounts.filter((r) =>
        r.item_name === 'Belvedere 1L' && r.audit_result === 'verified' && r.status === 'done').length)
      .toBeGreaterThanOrEqual(2);
    const dbRows = db.t.kount_recounts.filter((r) => r.item_name === 'Belvedere 1L');
    for (const r of dbRows) {
      expect(r.audit_result).toBe('verified');
      expect(r.status).toBe('done');
      // recountQty syncs into the count2_qty column and equals that zone's count1.
      expect(r.count2_qty).toBe(r.count1_qty);
      expect(Number.isFinite(Number(r.count2_qty))).toBe(true);
    }

    // ---- Verified rows satisfy closeCount2's gates -> finalize reaches submitted.
    await page.evaluate(() => window.closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
  });

  test('the card Verify-all button (manager) drives the same cascade', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedTwoZoneRecount(page, db, 4, 1);

    // The button is manager/corporate-only and carries data-recount-item.
    const btn = page.locator('button.recount-verify-all[data-recount-item="Belvedere 1L"]');
    await expect(btn).toBeVisible();
    await btn.click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));

    await expect
      .poll(() => page.evaluate(() =>
        Object.values(appState.audit.recounts)
          .filter((r) => r.itemName === 'Belvedere 1L')
          .every((r) => r.status === 'done' && r.auditResult === 'verified'
            && r.recountQty === r.count1Qty)))
      .toBe(true);
  });
});

test.describe('v1.98 grouped recount render — bottle-var guardrail', () => {
  test('a multi-zone card shows the item-level bottle figure ONCE, not multiplied by zones', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    // Mock flags Belvedere as -5 bottles (actual 1 vs theo 6). Both zone rows
    // carry the SAME item-level variance (-5). If the card summed variance across
    // the two zone rows it would read -10 ("10.0 bottles short").
    await seedTwoZoneRecount(page, db, 3, 2);

    const card = page.locator('div.focus-item[data-recount-item="Belvedere 1L"]');
    await expect(card).toBeVisible();
    const text = await card.innerText();

    // Item-level figure appears exactly once and is NOT doubled.
    expect(text).toContain('5.0 bottles short');
    expect(text).not.toContain('10.0 bottles short');
    const occurrences = (text.match(/bottles short/g) || []).length;
    expect(occurrences).toBe(1);

    // The dollar "Var: $…" span was removed in v1.98 — the card is bottles-only.
    expect(text).not.toMatch(/Var:\s*\$/);
    expect(text).not.toMatch(/\$\d/);

    // Per-zone breakdown is still present (two zones, C1 sub-rows).
    const zoneRows = card.locator('div.recount-zone-row');
    await expect(zoneRows).toHaveCount(2);
  });
});
