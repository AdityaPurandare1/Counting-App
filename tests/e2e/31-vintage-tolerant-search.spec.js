/* v2.17 — vintage-tolerant catalog search.

   Little Luck's 2026-10-18 count: a counter scanned
     "Von Winning — Forster Ungeheuer Riesling 2024 750ml"
   while the catalog held the 2023. searchItemMaster required EVERY query word
   to appear, so "2024" killed the match, search came back empty, and the
   bottle was recorded as an unlinked manual entry. Vintage is baked into the
   item name in this catalog, so every new vintage is a product that matches
   nothing.

   Fix: a 4-digit year token is OPTIONAL. Non-year words must still all match.
   An exact vintage still ranks ABOVE a vintage mismatch, and a query that is
   only a year keeps the strict rule (otherwise "2021" matches everything).

   NOTE ON APPROACH: itemMaster is a module-scoped `let`, so a test cannot
   inject a fixture catalog — window.itemMaster is a different binding the
   function never reads. These assertions therefore run against the catalog
   the app really loads from the mock DB, and are written to hold for ANY
   catalog: they compare a plain search against the same search with a year
   appended. That is exactly the invariant the fix introduces.

   FAIL-BEFORE: appending any year returned [] for every query. */
const { test, expect } = require('../fixtures');

const search = (page, q) =>
  page.evaluate((query) => window.searchItemMaster(query, 20).map((i) => i.name), q);

test.describe('v2.17 vintage-tolerant search', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.searchItemMaster)).toBe('function');
    // Wait for the real catalog to finish loading so results are stable.
    await expect.poll(() => page.evaluate(() => window.searchItemMaster('belvedere', 5).length))
      .toBeGreaterThan(0);
  });

  test('appending a vintage the catalog lacks still finds the product', async ({ page }) => {
    const plain = await search(page, 'belvedere');
    expect(plain.length).toBeGreaterThan(0);

    // THE REGRESSION. No Belvedere row carries "2024"; pre-fix this was [].
    const withYear = await search(page, 'belvedere 2024');
    expect(withYear.length).toBeGreaterThan(0);
    expect(withYear).toEqual(plain);
  });

  test('a year is ignored on multi-word queries too', async ({ page }) => {
    const plain = await search(page, 'grey goose');
    test.skip(plain.length === 0, 'catalog has no Grey Goose to exercise');
    expect(await search(page, 'grey goose 2019')).toEqual(plain);
    expect(await search(page, 'grey 1998 goose')).toEqual(plain);
  });

  test('a non-year word that is absent still excludes the row', async ({ page }) => {
    // Vintage tolerance must NOT become "ignore any word we cannot match".
    expect(await search(page, 'belvedere merlotzzz')).toEqual([]);
    expect(await search(page, 'belvedere merlotzzz 2024')).toEqual([]);
  });

  test('a bare year query stays strict — it must not act as a wildcard', async ({ page }) => {
    const bare = await search(page, '2024');
    // Every row it returns must genuinely contain that year.
    expect(bare.every((n) => n.includes('2024'))).toBe(true);
  });

  test('ordering: an exact vintage outranks a vintage mismatch', async ({ page }) => {
    const probe = await page.evaluate(() => {
      const hit = window.searchItemMaster('e', 400).find((i) => /\b(19|20)\d{2}\b/.test(i.name || ''));
      if (!hit) return null;
      const year = hit.name.match(/\b((?:19|20)\d{2})\b/)[1];
      const words = hit.name.toLowerCase().replace(/[^a-z0-9 ]/g, ' ').split(/\s+/)
        .filter((w) => w.length > 3 && !/^(19|20)\d{2}$/.test(w)).slice(0, 2);
      return { name: hit.name, year, q: words.join(' ') };
    });
    test.skip(!probe || !probe.q, 'catalog has no vintaged item to exercise ordering');

    const exact = await search(page, probe.q + ' ' + probe.year);
    expect(exact.length).toBeGreaterThan(0);
    // The row carrying the queried vintage must come first.
    expect(exact[0]).toContain(probe.year);
  });
});
