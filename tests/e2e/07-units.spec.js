const { test, expect } = require('../fixtures');

/* Pure load-bearing helpers, called directly (they're globals). The page is
   loaded so the catalog/carried set are available for searchItemMaster. */
test.describe('unit: load-bearing helpers', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.visibleSku)).toBe('function');
  });

  test('visibleSku hides UUIDs, keeps real UPCs', async ({ page }) => {
    expect(await page.evaluate(() => window.visibleSku('11111111-1111-4111-8111-111111111111'))).toBe('');
    expect(await page.evaluate(() => window.visibleSku('0195893031092'))).toBe('0195893031092');
    expect(await page.evaluate(() => window.visibleSku(''))).toBe('');
    expect(await page.evaluate(() => window.isValidUuid('22222222-2222-4222-8222-222222222222'))).toBe(true);
  });

  test('masterCategoryForCreate maps to the catalog convention', async ({ page }) => {
    const m = await page.evaluate(() => ({
      wine: window.masterCategoryForCreate('wine'),
      spirits: window.masterCategoryForCreate('spirits'),
      beer: window.masterCategoryForCreate('beer'),
      other: window.masterCategoryForCreate('other'),
    }));
    expect(m).toEqual({ wine: 'Wine Cost', spirits: 'Liquor Cost', beer: 'Beer Cost', other: 'Bar Consumables' });
  });

  test('parseBottleSize parses sizes and normalizes cl→ml', async ({ page }) => {
    expect(await page.evaluate(() => window.parseBottleSize('750ml'))).toEqual({ size: 750, unit: 'ml' });
    expect(await page.evaluate(() => window.parseBottleSize('70cl'))).toEqual({ size: 700, unit: 'ml' });
    expect(await page.evaluate(() => window.parseBottleSize('nope'))).toEqual({ size: null, unit: null });
  });

  test('searchItemMaster ranks carried first, then falls through to full catalog', async ({ page }) => {
    await expect.poll(() => page.evaluate(() => window.searchItemMaster('Belvedere', 5).length)).toBeGreaterThan(0);
    // "Don Julio 1942" is NOT carried in the seed → only reachable via fallback.
    const names = await page.evaluate(() => window.searchItemMaster('Don Julio', 8).map(i => i.name));
    expect(names.join(' | ')).toContain('Don Julio 1942');
  });

  test('stripSizeTokens collapses size-only variants to the same base key', async ({ page }) => {
    // Used by findSizeSiblings (Fix B) to detect that Belvedere 1L and
    // Belvedere 1.75L are the same product in different sizes.
    const r = await page.evaluate(() => ({
      ml:       window.stripSizeTokens('Belvedere 750ml'),
      l:        window.stripSizeTokens('Belvedere 1L'),
      bigL:     window.stripSizeTokens('Belvedere 1.75L'),
      mlBase:   window.stripSizeTokens('Belvedere'),
      oz:       window.stripSizeTokens('Red Bull 8.4oz'),
      flOz:     window.stripSizeTokens('Stella 12fl.oz'),
      cl:       window.stripSizeTokens('Whisky 70cl'),
      gal:      window.stripSizeTokens('Beer Keg 15.5gal'),
      compound: window.stripSizeTokens('  Belvedere 1.75 L  '),
    }));
    expect(r.ml).toBe('belvedere');
    expect(r.l).toBe('belvedere');
    expect(r.bigL).toBe('belvedere');
    expect(r.mlBase).toBe('belvedere');
    expect(r.oz).toBe('red bull');
    expect(r.flOz).toBe('stella');
    expect(r.cl).toBe('whisky');
    expect(r.gal).toBe('beer keg');
    expect(r.compound).toBe('belvedere');
  });

  test('isDoNotCountName flags poisoned-row name conventions (Jonathan @ Poppy 2026-06)', async ({ page }) => {
    // Inventory convention: master_items prefixed/marked "DO NOT USE",
    // "DNC", or with a "(Do not Use-...)" parenthetical are kept for
    // legacy references but must never receive counts. There's no flag
    // column; the helper is the single source of truth and is used at
    // itemMaster load, in searchItemMaster's match predicate, and in
    // the upc_mappings cache loader.
    const cases = await page.evaluate(() => ({
      // Real examples pulled from master_items 2026-06:
      doNotUseDashed:      window.isDoNotCountName('DO NOT USE - Aqua Panna Still Water 300ml 330ml'),
      stars:               window.isDoNotCountName('***Do NOT USE! Use 11.2oz Stella Liberte 12fl.oz'),
      bangs:               window.isDoNotCountName('DO NOT USE!!! Hoegaarden 12fl.oz'),
      starsSuffix:         window.isDoNotCountName('DO NOT USE*** MICHELOB ULTRA 12fl.oz'),
      paren:               window.isDoNotCountName('Aqua Panna (Do NOT Use- Use Acqua Panna) 1L'),
      dnc:                 window.isDoNotCountName('DNC Legacy Cordial'),
      // Must NOT trip on these regular names:
      donJulio:            window.isDoNotCountName('Don Julio 1942 750ml'),
      donut:               window.isDoNotCountName('Donut Glaze Syrup'),
      indonesian:          window.isDoNotCountName('Indonesian Coffee Beans'),
      empty:               window.isDoNotCountName(''),
      nullName:            window.isDoNotCountName(null),
    }));
    expect(cases).toEqual({
      doNotUseDashed: true,
      stars:          true,
      bangs:          true,
      starsSuffix:    true,
      paren:          true,
      dnc:            true,
      donJulio:       false,
      donut:          false,
      indonesian:     false,
      empty:          false,
      nullName:       false,
    });
  });
});
