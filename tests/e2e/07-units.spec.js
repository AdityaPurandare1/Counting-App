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
});
