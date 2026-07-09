/* INSTANT SCAN (v1.69): a detected barcode that resolves to a known catalog
   item counts +1 in the current zone WITHOUT opening the result modal, and
   keeps the scanner open for the next bottle. Unknown barcodes keep today's
   modal flow. A per-barcode cooldown stops a lingering bottle double-counting.

   Headless note: the native BarcodeDetector interval is gated on
   video.readyState >= 2, which never advances under a mocked getUserMedia
   stream. So we drive detection through the real handoff entry point
   (onBarcodeDetected → processDetection → instantScanCount) which BOTH the
   native and Quagga paths funnel through. processDetection needs 2 confirming
   frames for a GTIN (ean_13) checksum-valid code, so each "scan" fires twice. */
const { test, expect, startAuditAs, counted, qtyOf, M } = require('../fixtures');

// GTIN-13 checksum-valid codes (validateBarcode rejects bad check digits).
const KNOWN_UPC   = '5060071510018'; // mapped to Belvedere 1L below
const KNOWN_UPC_B = '5060071510025'; // mapped to Belvedere 1.75L (the "B" bottle)
const UNKNOWN_UPC = '9998887776662'; // no mapping, no master inline UPC

// Inject a learned mapping into the live upcMappingsCache so resolveInstantScan
// (via lookupLearnedUPC) resolves KNOWN_UPC → Belvedere's master id. Mirrors
// what loadApprovedUpcMappings would have populated from master_item_upcs.
async function mapKnownUpc(page) {
  // upcMappingsCache is a top-level `let` (global lexical binding, not a window
  // property), so reference it by bare name inside the page context.
  await page.evaluate(({ upc, masterId }) => {
    upcMappingsCache[upc] = {
      title: 'Belvedere 1L', brand: '', category: 'Liquor Cost',
      masterId: masterId, barcode: upc, approvedAt: '2026-01-01T00:00:00Z',
    };
  }, { upc: KNOWN_UPC, masterId: M.belv });
}

// Map a SECOND known UPC (the "B" bottle) → Belvedere 1.75L for the
// interleaved A,B,A double-count regression (FIX 1, v1.74).
async function mapKnownUpcB(page) {
  await page.evaluate(({ upc, masterId }) => {
    upcMappingsCache[upc] = {
      title: 'Belvedere 1.75L', brand: '', category: 'Liquor Cost',
      masterId: masterId, barcode: upc, approvedAt: '2026-01-01T00:00:00Z',
    };
  }, { upc: KNOWN_UPC_B, masterId: M.belv175 });
}

// Fire enough confirming frames through the real detect handoff to lock.
async function scan(page, code) {
  await page.evaluate((c) => {
    const r = { codeResult: { code: c, format: 'ean_13' } };
    // 3 frames > the 2-frame high-confidence requirement; processDetection
    // debounces the lock so extra frames are harmless.
    onBarcodeDetected(r);
    onBarcodeDetected(r);
    onBarcodeDetected(r);
  }, code);
}

async function openScanner(page) {
  await page.evaluate(() => openBarcodeScanner());
}

// Clear the per-barcode cooldown + re-arm so an immediate re-scan of the same
// code isn't blocked (simulates time passing / a different bottle).
async function clearScanCooldown(page) {
  await page.evaluate(() => { lastScanTime = 0; lastScannedCode = ''; recentlyScanned.clear(); });
}

test.describe('instant scan: known barcode opens the entry sheet (v1.97)', () => {
  test.beforeEach(async ({ page }) => { await startAuditAs(page, 'manager'); });

  test('a KNOWN UPC closes the scanner and opens the entry sheet — nothing counted until Confirm', async ({ page }) => {
    await mapKnownUpc(page);
    await openScanner(page);
    await scan(page, KNOWN_UPC);

    // New behavior: the scanner closes and the guided entry sheet opens for the
    // RESOLVED variant, so a wrong mapping is visible before anything is counted.
    await expect(page.locator('#barcodeModal')).toHaveClass(/hide/);
    await expect(page.locator('#guidedEntryModal')).not.toHaveClass(/hide/);
    await expect(page.locator('#guidedHeroTitle')).toHaveText('Belvedere 1L');
    // Fresh item → empty qty (Set mode), and NOTHING counted yet.
    await expect(page.locator('#guidedQty')).toHaveValue('');
    await expect(page.locator('#guidedAddHint')).toBeHidden();
    expect((await counted(page)).length).toBe(0);
  });

  test('completing the scanned entry counts the typed qty (FK invariant) and re-opens the scanner', async ({ page, db }) => {
    await mapKnownUpc(page);
    await openScanner(page);
    await scan(page, KNOWN_UPC);

    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.fill('#guidedQty', '4');
    await page.locator('#guidedEntryModal').getByRole('button', { name: /^Confirm/ }).click();

    // The typed qty (not a hard-coded 1) is recorded against the master.
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(4);
    const items = await counted(page);
    expect(items.find(i => i.name === 'Belvedere 1L').masterId).toBe(M.belv);

    // FK invariant preserved via the reused addCountEntry path.
    await expect.poll(() => db.t.kount_entries.filter(r => r.item_name === 'Belvedere 1L').length).toBe(1);
    const row = db.t.kount_entries.find(r => r.item_name === 'Belvedere 1L');
    expect(row.item_id).toBeNull();
    expect(row.master_item_id).toBe(M.belv);

    // Auto-resume: the scanner re-opens after Confirm for the next bottle.
    await expect(page.locator('#barcodeModal')).not.toHaveClass(/hide/);
  });

  test('re-scanning an already-counted item opens in Add mode and adds (does not overwrite)', async ({ page }) => {
    await mapKnownUpc(page);
    await openScanner(page);

    // First scan+confirm establishes a count of 3 in the current zone.
    await scan(page, KNOWN_UPC);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.fill('#guidedQty', '3');
    await page.locator('#guidedEntryModal').getByRole('button', { name: /^Confirm/ }).click();
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(3);

    // Scanner auto-resumed; clear the cooldown and scan the same item again.
    await clearScanCooldown(page);
    await scan(page, KNOWN_UPC);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    // Add mode: hint shown, field empty — the existing 3 must not be overwritten.
    await expect(page.locator('#guidedAddHint')).toBeVisible();
    await expect(page.locator('#guidedQty')).toHaveValue('');

    // Add 7 → total 10 (not replaced by 7). Single merged row.
    await page.fill('#guidedQty', '7');
    await page.locator('#guidedEntryModal').getByRole('button', { name: /^Confirm/ }).click();
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(10);
    expect((await counted(page)).filter(i => i.name === 'Belvedere 1L').length).toBe(1);
  });

  test('scanning a DIFFERENT known bottle opens its own entry sheet', async ({ page }) => {
    // The interleaved-double-count risk is gone (each scan opens a discrete
    // entry), so this just confirms the second bottle resolves independently.
    await mapKnownUpc(page);
    await mapKnownUpcB(page);
    await openScanner(page);

    await scan(page, KNOWN_UPC);   // A
    await expect(page.locator('#guidedHeroTitle')).toHaveText('Belvedere 1L');
    await page.fill('#guidedQty', '1');
    await page.locator('#guidedEntryModal').getByRole('button', { name: /^Confirm/ }).click();
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(1);

    await clearScanCooldown(page);
    await scan(page, KNOWN_UPC_B); // B → its own sheet
    await expect(page.locator('#guidedHeroTitle')).toHaveText('Belvedere 1.75L');
    await page.fill('#guidedQty', '1');
    await page.locator('#guidedEntryModal').getByRole('button', { name: /^Confirm/ }).click();
    await expect.poll(() => qtyOf(page, 'Belvedere 1.75L')).toBe(1);

    expect((await counted(page)).filter(i => i.name === 'Belvedere 1L').length).toBe(1);
    expect((await counted(page)).filter(i => i.name === 'Belvedere 1.75L').length).toBe(1);
  });

  test('flagging a wrong-variant scan queues a barcode→correct-item fix', async ({ page, db }) => {
    // KNOWN_UPC resolves to Belvedere 1L; pretend that's the WRONG bottle.
    await mapKnownUpc(page);
    await openScanner(page);
    await scan(page, KNOWN_UPC);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });

    // A scan-opened entry offers the "Wrong bottle?" fix.
    await expect(page.locator('#guidedWrongBarcodeBtn')).toBeVisible();
    await page.locator('#guidedWrongBarcodeBtn').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    // Tap the CORRECT bottle from search → opens its entry AND queues the fix.
    await page.fill('#guidedSearchInput', 'Campari');
    await page.locator('#guidedSearchResults .c-item').filter({ hasText: 'Campari 1L' }).first()
      .locator('.c-name').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });

    // A pending barcode→Campari correction landed in the admin queue.
    await expect.poll(() => db.t.upc_mappings.filter(r => r.barcode_raw === KNOWN_UPC).length).toBeGreaterThan(0);
    const row = db.t.upc_mappings.find(r => r.barcode_raw === KNOWN_UPC);
    expect(row.item_name).toBe('Campari 1L');
    expect(row.status).toBe('pending');
  });

  test('an UNKNOWN UPC opens the result modal (today\'s flow), no count', async ({ page }) => {
    await openScanner(page);
    await scan(page, UNKNOWN_UPC);

    // The barcode entry modal opens for link/search/suggest.
    await expect(page.locator('#barcodeEntryModal')).not.toHaveClass(/hide/);
    await expect(page.locator('#barcodeUpc')).toHaveText(UNKNOWN_UPC);
    // Nothing counted yet — the counter still has to resolve + save.
    expect((await counted(page)).length).toBe(0);
  });
});
