const { test, expect, startAuditAs, counted } = require('../fixtures');
const { M } = require('../mock/fixtures');

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

  test('Fuzzy gate: typing a near-name shows "Did you mean?" instead of silently creating a dup (Anna @ Poppy 2026-06)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const masterBefore = db.t.master_items.length;

    // Type "Belveder" (typo) — Belvedere 1L is in the catalog. Skip past the
    // suggestion list (which is what a counter who's used Craftable would do
    // by reflex) and submit. The fuzzy gate should catch it.
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.fill('#manualName', 'Belveder');
    await page.fill('#manualQty', '3');
    await page.locator('#manualModal').getByRole('button', { name: 'Add to count', exact: true }).click();

    // The "Did you mean?" picker appears with Belvedere 1L as a candidate.
    await page.locator('#fuzzyMatchPickerModal').waitFor({ state: 'visible' });
    await expect(page.locator('#fuzzyMatchPickerModal')).toContainText('Did you mean');
    await expect(page.locator('#fuzzyMatchPickerModal')).toContainText('Belvedere 1L');
    // Pick the top suggestion.
    await page.locator('#fuzzyMatchPickerModal .fuzzy-pick').first().click();
    await page.locator('#fuzzyMatchPickerModal').waitFor({ state: 'hidden' });

    // The 3 are recorded against the EXISTING Belvedere 1L. No new master_items.
    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.masterId === M.belv);
      return it ? it.qty : null;
    }).toBe(3);
    expect(db.t.master_items.length).toBe(masterBefore);
  });

  test('Fuzzy gate: "Add as new" still creates the custom item when there is no plausible existing match', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const masterBefore = db.t.master_items.length;

    // Type something genuinely new (no plausible bigram overlap with any seed item).
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.fill('#manualName', 'Zibibbo Late Harvest');
    await page.fill('#manualQty', '2');
    await page.locator('#manualModal').getByRole('button', { name: 'Add to count', exact: true }).click();
    // No fuzzy candidates → no picker → straight to custom-item creation.
    // (Manager path: addCustomItem is local, no master_items DB write.)
    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Zibibbo Late Harvest');
      return it ? it.qty : null;
    }).toBe(2);
    expect(db.t.master_items.length).toBe(masterBefore);
  });
});
