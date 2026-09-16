/* v1.99 RECOUNT LOCATION FIX.
 *
 * Anna @ Poppy (2026-08-10): "As well as telling you it's in the wrong location
 * we should be able to update it within the recount."
 *
 * Before this change a counter in the recount could pick the "Wrong location"
 * issue chip and type a note, but could not ACT on it — isAuditLocked() is true
 * for count_phase review/count2, so the Count-1 ⇄ move button is not rendered
 * and showMoveMenu() early-returns.
 *
 * THE FIX (counting-app.html):
 *   - A recount-only Location picker (#recountZoneGroup / #recountZoneSelect),
 *     populated by populateRecountZoneSelect() from openRecountEntry().
 *   - moveEntryToZone's body was extracted to performEntryZoneMove(), which
 *     carries no phase lock, so the recount path can relocate Count-1 stock.
 *   - moveRecountLocation(key, toZone) moves the Count-1 entry AND re-keys the
 *     recount row, folding into the target zone's row when one already exists
 *     (kount_recounts has a UNIQUE index on
 *     (audit_id, coalesce(item_id::text, lower(item_name)), coalesce(zone,''))
 *     so a blind zone patch would 23505).
 *   - submitGuidedEntry's recount branch applies it on Confirm and syncs the
 *     key the move returns.
 *
 * Zone is a LOCATION attribute only: compute_avt_for_audit aggregates actuals
 * per ITEM across zones, so a move never changes the variance. The merge test
 * below asserts exactly that (variance is NOT summed across the folded rows).
 *
 * SCOPE NOTE: the merge path's underlying Count-1 delete is silently cancelled
 * on PROD by the _guard_block_active_entry_delete trigger until migration 0050
 * is applied. The mock db has no such trigger, so these tests cover the client
 * contract; 0050's own verification block covers the DB half.
 *
 * The mock's compute_avt_for_audit flags Belvedere 1L as HIGH (actual 1 vs
 * theo 6), which is what produces the recount rows used here.
 */
const { test, expect, startAuditAs, addManual, switchZone, M } = require('../fixtures');

const ITEM = 'Belvedere 1L';

/* addManual + the two settles this seed needs to be deterministic.
   1. The catalog (itemMaster) loads/reloads asynchronously, and if a manual add
      lands mid-reload the exact-name link misses and the "Did you mean?" gate
      opens — an overlay that then intercepts the next zone-tab tap. This is the
      known addManual/catalog harness race (same class as the fixtures'
      waitForCatalog fix), not a product behaviour under test here, so pick the
      exact match and carry on.
   2. Wait for the entry to actually land in the zone before switching away,
      so a slow add can't be attributed to the next zone. */
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

/* Count ITEM in the given zones, close Count 1, and wait for the per-zone
   recount rows to materialize. Leaves the audit in count_phase 'review'. */
async function seedRecount(page, db, perZone) {
  for (const [zone, qty] of perZone) {
    await switchZone(page, zone);
    await addItem(page, zone, ITEM, qty);
  }
  await page.evaluate(() => closeCount1());
  await page.locator('#confirmDialog').waitFor({ state: 'visible' });
  await page.evaluate(() => window.closeConfirm(true));
  await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

  await expect
    .poll(() => page.evaluate((item) =>
      Object.values((appState.audit && appState.audit.recounts) || {})
        .filter((r) => r.itemName === item).length, ITEM), { timeout: 5000 })
    .toBeGreaterThanOrEqual(perZone.length);
}

const rowsFor = (page, item) => page.evaluate((it) =>
  Object.entries(appState.audit.recounts)
    .filter(([, r]) => r.itemName === it)
    .map(([key, r]) => ({
      key, zone: r.zone, count1Qty: r.count1Qty, recountQty: r.recountQty,
      variance: r.variance, auditResult: r.auditResult, status: r.status,
    })), item);

/* Drive the recount modal exactly as a counter does: open, (optionally) change
   the Location, enter qty + the two mandatory fields, tap Confirm. */
async function recordRecount(page, key, { qty, result, reason, zone }) {
  await page.evaluate((k) => openRecountEntry(k), key);
  await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
  await expect(page.locator('#guidedEntryModal')).toHaveAttribute('data-mode', 'recount');
  if (zone) await page.selectOption('#recountZoneSelect', zone);
  await page.fill('#guidedQty', String(qty));
  await page.selectOption('#recountResultSelect', result);
  await page.fill('#recountReasonInput', reason);
  await page.locator('#guidedConfirmBtn').click();
  await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
}

test.describe('v1.99 recount location picker', () => {
  test('picker is recount-only and opens on the row\'s current zone', async ({ page, db }) => {
    await startAuditAs(page, 'manager');

    // A normal count entry must NOT show the Location picker — it is the
    // recount's answer to a lock that does not apply during Count 1.
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await expect(page.locator('#recountZoneGroup')).toBeHidden();
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Skip', exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    await seedRecount(page, db, [['Liquor Room', 3]]);
    const [row] = await rowsFor(page, ITEM);

    await page.evaluate((k) => openRecountEntry(k), row.key);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });

    // Visible, defaulted to where the item currently sits, and offering the
    // venue's other zones as targets.
    await expect(page.locator('#recountZoneGroup')).toBeVisible();
    await expect(page.locator('#recountZoneSelect')).toHaveValue('Liquor Room');
    const opts = await page.locator('#recountZoneSelect option').allTextContents();
    expect(opts).toContain('Liquor Room');
    expect(opts).toContain('Bar');

    // Picking a different zone previews the move rather than applying it.
    await page.selectOption('#recountZoneSelect', 'Bar');
    await expect(page.locator('#recountZoneHint')).toContainText('Liquor Room');
    await expect(page.locator('#recountZoneHint')).toContainText('Bar');
    const stillThere = await rowsFor(page, ITEM);
    expect(stillThere[0].zone, 'preview must not move anything').toBe('Liquor Room');

    // Skip = no move, and the picker resets so it cannot leak into a later open.
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Skip', exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
    const afterSkip = await rowsFor(page, ITEM);
    expect(afterSkip[0].zone).toBe('Liquor Room');
    expect(afterSkip[0].key).toBe(row.key);
    await expect(page.locator('#recountZoneGroup')).toBeHidden();
    expect(await page.evaluate(() =>
      document.getElementById('recountZoneSelect').dataset.originalZone)).toBeUndefined();
  });

  test('move to an empty zone re-keys the row and relocates the Count-1 entry', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3]]);
    const [before] = await rowsFor(page, ITEM);
    expect(before.zone).toBe('Liquor Room');

    // The Count-1 entry backing it is in Liquor Room on the server.
    const entryId = db.t.kount_entries.find(
      (e) => e.item_name === ITEM && e.zone === 'Liquor Room' && !e.is_recount).id;
    expect(entryId).toBeTruthy();

    await recordRecount(page, before.key, {
      qty: 3, result: 'corrected', reason: 'stock actually lives behind the bar', zone: 'Bar',
    });

    // ---- Local: exactly one row, re-keyed onto the new zone.
    const after = await rowsFor(page, ITEM);
    expect(after).toHaveLength(1);
    expect(after[0].zone).toBe('Bar');
    expect(after[0].key).toBe(ITEM + '|Bar');
    expect(after[0].recountQty).toBe(3);
    expect(after[0].auditResult).toBe('corrected');

    // ---- Server: the Count-1 entry moved zone; qty is untouched by a move.
    await expect.poll(() => db.t.kount_entries.find((e) => e.id === entryId).zone).toBe('Bar');
    expect(db.t.kount_entries.find((e) => e.id === entryId).qty).toBe(3);
    expect(db.t.kount_entries.filter(
      (e) => e.item_name === ITEM && e.zone === 'Liquor Room' && !e.is_recount)).toHaveLength(0);

    // ---- Server: the recount row followed (this is what the admin screen reads).
    await expect
      .poll(() => db.t.kount_recounts.filter((r) => r.item_name === ITEM && r.zone === 'Bar').length)
      .toBe(1);
    expect(db.t.kount_recounts.filter(
      (r) => r.item_name === ITEM && r.zone === 'Liquor Room')).toHaveLength(0);
  });

  test('move into an occupied zone folds the rows without multiplying variance', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3], ['Bar', 2]]);

    const before = await rowsFor(page, ITEM);
    expect(before).toHaveLength(2);
    const src = before.find((r) => r.zone === 'Liquor Room');
    const dst = before.find((r) => r.zone === 'Bar');
    expect(src && dst).toBeTruthy();
    // variance/varianceValue are ITEM-level values duplicated onto every zone
    // row — capture it so we can prove the fold does not sum them.
    const itemVariance = dst.variance;
    expect(src.variance).toBe(itemVariance);

    await recordRecount(page, src.key, {
      qty: 3, result: 'corrected', reason: 'all of it is behind the bar', zone: 'Bar',
    });

    // ---- One row survives, holding the summed Count-1 stock.
    const after = await rowsFor(page, ITEM);
    expect(after).toHaveLength(1);
    expect(after[0].zone).toBe('Bar');
    expect(after[0].count1Qty).toBe(src.count1Qty + dst.count1Qty);   // 3 + 2
    // The item-level variance is carried, NOT added to itself.
    expect(after[0].variance).toBe(itemVariance);

    // ---- The Count-1 entries merged into one Bar row carrying the full qty.
    await expect
      .poll(() => db.t.kount_entries.filter(
        (e) => e.item_name === ITEM && !e.is_recount && e.zone === 'Bar').length)
      .toBe(1);
    expect(db.t.kount_entries.find(
      (e) => e.item_name === ITEM && !e.is_recount && e.zone === 'Bar').qty).toBe(5);
    expect(db.t.kount_entries.filter(
      (e) => e.item_name === ITEM && !e.is_recount && e.zone === 'Liquor Room')).toHaveLength(0);

    // ---- The now-stale kount_recounts row is gone, leaving a single Bar row.
    await expect
      .poll(() => db.t.kount_recounts.filter((r) => r.item_name === ITEM).length)
      .toBe(1);
    expect(db.t.kount_recounts.find((r) => r.item_name === ITEM).zone).toBe('Bar');
  });

  test('a relocated row still satisfies the closeCount2 gates', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await seedRecount(page, db, [['Liquor Room', 3]]);
    const [row] = await rowsFor(page, ITEM);

    await recordRecount(page, row.key, {
      qty: 3, result: 'verified', reason: 'found it in the bar, count is right', zone: 'Bar',
    });

    // Every recount row must carry result + reason + a finite qty; the moved
    // row must not slip through re-keyed but un-decided.
    const remaining = await page.evaluate(() =>
      Object.values(appState.audit.recounts).filter((r) => !r.auditResult).length);
    expect(remaining).toBe(0);

    await page.evaluate(() => window.closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
  });
});
