/* v2.23 — a venue on its own catalog (kount_venues.catalog_mode = 'invoiced').

   Alphabet, A-595 (10/26): Robert was offered four Krugs from the GLOBAL
   carried list, picked a twin, and variance read the real Krug as never
   counted. Alphabet now counts from kount_venue_catalog only (migrations
   0109/0110): search, manual suggestions, the List tab and the photo matcher
   see that catalog and nothing else. Every other venue is unchanged, and a
   venue whose catalog cannot be loaded falls back to the normal behaviour
   rather than leaving counters with an empty search. */
const { test, expect, startAuditAs } = require('../fixtures');
const { M } = require('../mock/fixtures');

function useCatalog(db, rows) {
  db.t.kount_venues[0].catalog_mode = 'invoiced';
  db.t.kount_venue_catalog = rows.map((r) => ({ venue_id: 'v-delilah', hidden: false, source: 'test', ...r }));
}

async function catalogReady(page) {
  await expect.poll(() => page.evaluate(() => !!window.activeVenueCatalog()), { timeout: 8000 }).toBe(true);
}

const names = (page, q) => page.evaluate((qq) => window.searchItemMaster(qq, 30).map((i) => i.name), q);

test.describe('v2.23 venue catalog', () => {
  test('search offers only the venue catalog (Belvedere 1L yes, the 1.75L twin no)', async ({ page, db }) => {
    useCatalog(db, [{ master_item_id: M.belv }, { master_item_id: M.cab }, { master_item_id: M.dj1942 }]);
    await startAuditAs(page, 'manager');
    await catalogReady(page);
    expect(await names(page, 'belvedere')).toEqual(['Belvedere 1L']);
    // In the catalog but NOT in the global carried list: still offered.
    expect(await names(page, 'don julio')).toEqual(['Don Julio 1942 750ml']);
    // Carried globally but not in this venue's catalog: not offered.
    expect(await names(page, 'campari')).toEqual([]);
  });

  test('a hidden catalog row (raw invoice twin) is not offered', async ({ page, db }) => {
    useCatalog(db, [{ master_item_id: M.belv }, { master_item_id: M.titos, hidden: true }]);
    await startAuditAs(page, 'manager');
    await catalogReady(page);
    expect(await names(page, 'tito')).toEqual([]);
  });

  test('the List tab shows exactly the catalog, alphabetically', async ({ page, db }) => {
    useCatalog(db, [{ master_item_id: M.cab }, { master_item_id: M.belv }]);
    await startAuditAs(page, 'manager');
    await catalogReady(page);
    const list = await page.evaluate(() => window.getCarriedMasterItems().map((i) => i.name));
    expect(list).toEqual(['Belvedere 1L', 'Rodney Strong Cabernet 2022 750ml']);
  });

  test('no "Not in your inventory list" divider and the search box counts the catalog', async ({ page, db }) => {
    useCatalog(db, [{ master_item_id: M.belv }, { master_item_id: M.dj1942 }]);
    await startAuditAs(page, 'manager');
    await catalogReady(page);
    await page.evaluate(() => window.renderCountPage());
    await expect(page.locator('#guidedSearchInput')).toHaveAttribute('placeholder', /Search 2 items/);
    await page.fill('#guidedSearchInput', 'don julio');
    await expect(page.locator('#guidedSearchResults')).toContainText('Don Julio 1942');
    await expect(page.locator('#guidedSearchResults')).not.toContainText('Not in your inventory list');
  });

  test('the photo matcher is sent only the catalog', async ({ page, db }) => {
    useCatalog(db, [{ master_item_id: M.belv }, { master_item_id: M.cab }]);
    await startAuditAs(page, 'manager');
    await catalogReady(page);
    const bodyP = page.waitForRequest((r) => r.url().includes('/functions/v1/parse-bottle-label'));
    await page.evaluate(() => window.parseLabelWithClaude('data:image/jpeg;base64,AAAA').catch(() => null));
    const body = JSON.parse((await bodyP).postData() || '{}');
    const sent = [...(body.carried || []), ...(body.catalog || [])].map((i) => i.name).sort();
    expect(sent).toEqual(['Belvedere 1L', 'Rodney Strong Cabernet 2022 750ml']);
  });

  test('a venue in normal mode is unchanged (both Belvedere sizes, carried list)', async ({ page, db }) => {
    db.t.kount_venue_catalog = [{ venue_id: 'v-delilah', master_item_id: M.belv, hidden: false, source: 'test' }];
    await startAuditAs(page, 'manager');   // catalog_mode not set = 'all'
    await page.waitForTimeout(500);
    expect(await page.evaluate(() => window.activeVenueCatalog())).toBe(null);
    const hits = await names(page, 'belvedere');
    expect(hits).toContain('Belvedere 1L');
    expect(hits).toContain('Belvedere 1.75L');
  });

  test('catalog mode with an empty/unreadable catalog falls back instead of an empty search', async ({ page, db }) => {
    useCatalog(db, []);
    await startAuditAs(page, 'manager');
    await page.waitForTimeout(500);
    expect(await page.evaluate(() => window.activeVenueCatalog())).toBe(null);
    expect(await names(page, 'belvedere')).toContain('Belvedere 1L');
  });

  test('the catalog is cached for offline use and survives a failed refresh', async ({ page, db }) => {
    useCatalog(db, [{ master_item_id: M.belv }]);
    await startAuditAs(page, 'manager');
    await catalogReady(page);
    const cached = await page.evaluate(() => JSON.parse(localStorage.getItem('hwood_venue_catalog_v1') || '{}'));
    expect(cached['v-delilah']).toEqual([M.belv]);
    // The server now answers nothing (offline / RLS hiccup): the cached list stays in force.
    db.t.kount_venue_catalog = [];
    await page.evaluate(() => window.loadVenueCatalog('v-delilah'));
    expect(await names(page, 'belvedere')).toEqual(['Belvedere 1L']);
  });
});
