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

test.describe('instant scan: known barcode counts without the modal', () => {
  test.beforeEach(async ({ page }) => { await startAuditAs(page, 'manager'); });

  test('a KNOWN UPC counts +1 in the current zone, no modal, scanner stays open', async ({ page, db }) => {
    await mapKnownUpc(page);
    await openScanner(page);
    await scan(page, KNOWN_UPC);

    // Counted +1 against the master (merge-key item, not a custom row).
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(1);
    const items = await counted(page);
    expect(items.find(i => i.name === 'Belvedere 1L').masterId).toBe(M.belv);

    // The FK invariant still holds via the reused addCountEntry path.
    await expect.poll(() => db.t.kount_entries.filter(r => r.item_name === 'Belvedere 1L').length).toBe(1);
    const row = db.t.kount_entries.find(r => r.item_name === 'Belvedere 1L');
    expect(row.item_id).toBeNull();
    expect(row.master_item_id).toBe(M.belv);

    // The result modal must NOT have opened, and the scanner stays open.
    await expect(page.locator('#barcodeEntryModal')).toHaveClass(/hide/);
    await expect(page.locator('#barcodeModal')).not.toHaveClass(/hide/);

    // In-scanner confirmation overlay shows the item + running qty.
    await expect(page.locator('#instantScanFeedback')).toContainText('Belvedere 1L');
  });

  test('the same KNOWN UPC fired again within the cooldown counts once', async ({ page }) => {
    await mapKnownUpc(page);
    await openScanner(page);
    await scan(page, KNOWN_UPC);
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(1);

    // Immediately re-fire the SAME code (lingering bottle) — blocked by the
    // per-barcode cooldown, so the qty must stay at 1.
    await scan(page, KNOWN_UPC);
    await scan(page, KNOWN_UPC);
    await page.waitForTimeout(200);
    expect(await qtyOf(page, 'Belvedere 1L')).toBe(1);
  });

  test('interleaved A,B,A within the cooldown counts A once (FIX 1)', async ({ page }) => {
    // PRE-FIX: the cooldown remembered only the SINGLE last code. Scanning A
    // set lastScannedCode=A; scanning B overwrote it with B; scanning A again
    // then passed the guard (last code was B, not A) and double-counted A.
    // POST-FIX: every recently-locked code is remembered in recentlyScanned,
    // so the second A is blocked while still inside the window.
    await mapKnownUpc(page);
    await mapKnownUpcB(page);
    await openScanner(page);

    await scan(page, KNOWN_UPC);   // A
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(1);
    await scan(page, KNOWN_UPC_B); // B
    await expect.poll(() => qtyOf(page, 'Belvedere 1.75L')).toBe(1);
    await scan(page, KNOWN_UPC);   // A again, still within the 2.5s window
    await page.waitForTimeout(200);

    // A must NOT have double-counted; B counted once.
    expect(await qtyOf(page, 'Belvedere 1L')).toBe(1);
    expect(await qtyOf(page, 'Belvedere 1.75L')).toBe(1);
    // Each is a single merged row.
    expect((await counted(page)).filter(i => i.name === 'Belvedere 1L').length).toBe(1);
    expect((await counted(page)).filter(i => i.name === 'Belvedere 1.75L').length).toBe(1);
  });

  test('after the cooldown elapses the same KNOWN UPC merges (+1)', async ({ page }) => {
    await mapKnownUpc(page);
    await openScanner(page);
    await scan(page, KNOWN_UPC);
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(1);

    // Advance past the 2.5s cooldown, then scan the same bottle again.
    // v1.74: the cooldown is governed by the recentlyScanned MAP (per-code
    // timestamps), so clear it as well as the legacy single-code vars.
    await page.evaluate(() => { lastScanTime = 0; lastScannedCode = ''; recentlyScanned.clear(); });
    await scan(page, KNOWN_UPC);
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(2);
    // Still a single merged entry, not two rows.
    const items = (await counted(page)).filter(i => i.name === 'Belvedere 1L');
    expect(items.length).toBe(1);
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
