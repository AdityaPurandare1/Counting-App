/* v1.98 BUG 5 — matchBarcodeToMaster substring match is gated to length-delta
   ≤ 1 (counting-app.html ~11300).

   The includes()/substring arm exists for real UPC drift: a code stored WITHOUT
   its check digit, or with one extra GS1 system digit — both length-delta ≤ 1.
   Unbounded, it resolved a SHORT scan to the WRONG master whenever the scan
   happened to be embedded in a longer, unrelated UPC (e.g. "12345678" inside
   "123456789012"). The fix gates the substring arm to |Δlen| ≤ 1, keeping the
   legitimate drift cases while dropping the embedding false positives. Exact and
   leading-zero-normalized matches are unaffected.

   Unit-style: we swap in a controlled single-item itemMaster per case and call
   matchBarcodeToMaster directly. FAIL-BEFORE: the Δ≥2 embedding cases matched
   (returned the item) before the guard. */
const { test, expect } = require('../fixtures');

test.describe('v1.98 matchBarcodeToMaster length-delta guard', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.matchBarcodeToMaster)).toBe('function');
  });

  test('substring matches gated to |Δlen| ≤ 1; exact & leading-zero still match', async ({ page }) => {
    const r = await page.evaluate(() => {
      const saved = itemMaster;
      // Run one scan against exactly one stored item so a match can only come
      // from that item's UPC (no cross-contamination from the seed catalog).
      const probe = (storedUpc, scan) => {
        itemMaster = [{ id: 'm-probe', name: 'Probe Item', category: 'Liquor Cost', upc: storedUpc }];
        const hit = window.matchBarcodeToMaster(scan);
        return hit ? hit.id : null;
      };
      try {
        return {
          // Exact digits.
          exact:            probe('012345678905', '012345678905'),
          // Leading-zero-normalized (stored with a leading zero, scanned without).
          leadingZero:      probe('05060071510019', '5060071510019'),
          // Legit drift, Δ=1: stored WITHOUT check digit is a substring of the
          // scanned full code → STILL matches.
          deltaOneShorter:  probe('12345678901', '123456789012'),
          // Legit drift, Δ=1: stored with one extra system digit contains the
          // scan → STILL matches.
          deltaOneLonger:   probe('123456789012', '23456789012'),
          // FALSE POSITIVE, Δ=4: short scan embedded in a longer unrelated UPC →
          // NO LONGER matches.
          embedShort:       probe('123456789012', '12345678'),
          // FALSE POSITIVE, Δ=4: long scan wraps a shorter unrelated UPC →
          // NO LONGER matches.
          embedLong:        probe('12345678', '123456789012'),
        };
      } finally {
        itemMaster = saved;
      }
    });

    expect(r.exact).toBe('m-probe');
    expect(r.leadingZero).toBe('m-probe');
    expect(r.deltaOneShorter).toBe('m-probe');
    expect(r.deltaOneLonger).toBe('m-probe');
    expect(r.embedShort).toBeNull();
    expect(r.embedLong).toBeNull();
  });
});
