const { test, expect, startAuditAs, counted } = require('../fixtures');

test.describe('catalog create + matching', () => {
  test('corporate "Add to catalog" creates a master_items row and links the count', async ({ page, db }) => {
    await startAuditAs(page, 'corporate');
    const before = db.t.master_items.length;

    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.fill('#manualName', 'Brand New Mezcal 750ml');
    await page.fill('#manualQty', '2');
    await page.selectOption('#manualCategory', 'spirits'); // → maps to "Liquor Cost"
    // No catalog match → corporate sees the create button.
    await expect(page.locator('#manualCreateBtn')).toBeVisible();
    await page.locator('#manualCreateBtn').click();

    // A new master_items row was inserted to the (mock) DB.
    await expect.poll(() => db.t.master_items.length).toBe(before + 1);
    const created = db.t.master_items[db.t.master_items.length - 1];
    expect(created.name).toContain('Brand New Mezcal');
    expect(created.category).toBe('Liquor Cost'); // 'spirits' → 'Liquor Cost' (manual default category)

    // Saving the count now links to the freshly created master.
    await page.locator('#manualModal').getByRole('button', { name: 'Add to count', exact: true }).click();
    await page.locator('#manualModal').waitFor({ state: 'hidden' });
    const it = (await counted(page)).find(i => /Brand New Mezcal/.test(i.name));
    expect(it).toBeTruthy();
    expect(it.masterId).toBe(created.id);
  });

  test('non-corporate sees "Suggest", not "Add to catalog"; suggesting writes a pending row', async ({ page, db }) => {
    await startAuditAs(page, 'manager'); // manager = non-corporate, can start + suggest
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.fill('#manualName', 'Another New Thing 1L');
    await expect(page.locator('#manualCreateBtn')).toBeHidden();
    await expect(page.locator('#manualSuggestBtn')).toBeVisible();
    await page.locator('#manualSuggestBtn').click();
    await expect.poll(() => db.t.kount_pending_items.filter(p => /Another New Thing/.test(p.name)).length).toBe(1);
  });

  test('manual search surfaces a non-carried catalog variant under a divider', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.fill('#manualName', 'Don Julio');           // NOT in the carried set
    // The full-catalog fallback shows it under the "Not in your inventory list" divider.
    await expect(page.locator('#manualSuggestions')).toContainText('Don Julio 1942');
    await expect(page.locator('#manualSuggestions')).toContainText(/Not in your inventory list/i);
  });
});
