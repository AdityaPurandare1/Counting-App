const { test, expect, startAuditAs, addManual, counted } = require('../fixtures');

/* v1.72 additions:
   - Task 3: a third count tab, "List", showing the venue's CARRIED items as
     full bottles (one row per carried master), each tappable to start a count.
   - Task 2: the barcode/photo/guided/manual issue chips read "Not in
     inventory" (the data-issue token stays "not-in-craftable" — persisted +
     matched by the admin Issues page — only the label changed), and selecting
     it still records the issue on the entry.
   - Task 4: the "This Zone" view shows a non-empty reference list of expected
     items (prior-audit-by-zone, else the carried fallback) instead of an empty
     state, with already-counted items filtered out. */

test.describe('List tab + zone reference list (v1.72)', () => {
  test.beforeEach(async ({ page }) => { await startAuditAs(page, 'manager'); });

  test('List tab renders the venue carried items and a tap starts a count', async ({ page, db }) => {
    await page.getByRole('button', { name: 'List', exact: true }).click();

    // Carried set = everything except Don Julio 1942 (see mock fixtures).
    const list = page.locator('#guidedContent .c-item');
    await expect(list.filter({ hasText: 'Belvedere 1L' })).toHaveCount(1);
    await expect(list.filter({ hasText: 'Campari 1L' })).toHaveCount(1);
    await expect(list.filter({ hasText: "Tito's Handmade Vodka 750ml" })).toHaveCount(1);
    // NOT-carried item must not appear.
    await expect(list.filter({ hasText: 'Don Julio 1942' })).toHaveCount(0);
    // Sorted alphabetically: Belvedere rows sort before Campari.
    const names = await page.locator('#guidedContent .c-item .c-name').allTextContents();
    const sorted = names.slice().sort((a, b) => a.localeCompare(b));
    expect(names).toEqual(sorted);

    // Tap a carried row → guided entry modal opens for that item; entering a
    // qty records a count in the current zone. The tap target is the inner
    // row (the .c-name bubbles to its onclick), not the outer .c-item.
    await list.filter({ hasText: 'Campari 1L' }).first().locator('.c-name').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.fill('#guidedQty', '4');
    await page.locator('#guidedEntryModal').getByRole("button", { name: "Confirm", exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Campari 1L');
      return it ? it.qty : null;
    }).toBe(4);
    await expect.poll(() => {
      const row = db.t.kount_entries.find(r => r.item_name === 'Campari 1L');
      return row ? row.qty : null;
    }).toBe(4);
  });

  test('issue chip reads "Not in inventory" and selecting it still records the issue', async ({ page, db }) => {
    // The label changed; the underlying token did not.
    await addManual(page, 'Belvedere 1L', 1);

    // Open the guided editor on the counted item and tag the issue.
    await page.locator('#guidedContent .c-item', { hasText: 'Belvedere 1L' })
      .locator('.c-info').first().click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });

    const chip = page.locator('#guidedIssueChips .issue-chip', { hasText: 'Not in inventory' });
    await expect(chip).toHaveCount(1);
    // The visible label changed but the persisted token did not.
    await expect(chip).toHaveAttribute('data-issue', 'not-in-craftable');
    await chip.click();
    await page.locator('#guidedEntryModal').getByRole("button", { name: "Confirm", exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Belvedere 1L');
      return it ? it.issue : null;
    }).toBe('not-in-craftable');
    await expect.poll(() => {
      const row = db.t.kount_entries.find(r => r.item_name === 'Belvedere 1L');
      return row ? row.issue : null;
    }).toBe('not-in-craftable');
  });

  test('This Zone shows a non-empty reference list when nothing is counted', async ({ page }) => {
    // No prior submitted audit exists in the mock (Poppy's reality), so the
    // zone view falls back to the venue carried list as the reference.
    await page.evaluate(() => window.renderGuidedMode());

    const ref = page.locator('#guidedContent .c-item');
    await expect(ref.filter({ hasText: 'Belvedere 1L' }).first()).toBeVisible();
    await expect(page.locator('#guidedContent')).toContainText('Not yet counted');
    // No old empty-state copy.
    await expect(page.locator('#guidedContent')).not.toContainText('Nothing counted in');

    // Counting an item removes it from the reference section (no double-show)
    // but the reference list stays non-empty.
    await addManual(page, 'Campari 1L', 2);
    const refRows = page.locator('#guidedContent .c-item');
    // Campari is now a COUNTED card (has +/- buttons); it should not also be a
    // reference row. Reference section still lists other carried items.
    await expect(page.locator('#guidedContent')).toContainText('Not yet counted');
    await expect(refRows.filter({ hasText: 'Belvedere 1L' }).first()).toBeVisible();

    // Tapping a reference row starts a count for that item in the current zone.
    await refRows.filter({ hasText: 'Belvedere 1L' }).first().locator('.c-name').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.fill('#guidedQty', '5');
    await page.locator('#guidedEntryModal').getByRole("button", { name: "Confirm", exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });
    await expect.poll(async () => {
      const it = (await counted(page)).find(i => i.name === 'Belvedere 1L');
      return it ? it.qty : null;
    }).toBe(5);
  });

  test('This Zone reference uses the most recent prior submitted audit, grouped by zone', async ({ page, db }) => {
    // Seed a prior SUBMITTED audit whose entries were counted in specific
    // zones, so the zone view shows "what was counted here last time" rather
    // than the carried fallback. Don Julio 1942 is NOT carried — its presence
    // here proves the source is the prior audit, not the carried list.
    const priorId = 'prior-audit-1';
    db.t.kount_audits.push({
      id: priorId, venue_id: 'v-delilah', venue_name: 'Delilah LA',
      status: 'submitted', count_phase: 'final',
      started_at: '2026-05-01T00:00:00Z', completed_at: '2026-05-02T00:00:00Z',
    });
    db.t.kount_entries.push(
      { id: 'pe-1', audit_id: priorId, zone: 'Liquor Room', item_name: 'Don Julio 1942 750ml',
        category: 'spirits', qty: 3, master_item_id: '22222222-2222-4222-8222-222222222222',
        item_id: null, counted_by_email: 'manager@hwood.com' },
      { id: 'pe-2', audit_id: priorId, zone: 'Bar', item_name: 'Campari 1L',
        category: 'spirits', qty: 5, master_item_id: '33333333-3333-4333-8333-333333333333',
        item_id: null, counted_by_email: 'manager@hwood.com' },
    );

    // The reference was cached empty at boot (no prior audit then). Clear the
    // cache and re-fetch now that the prior audit exists, then re-render.
    await page.evaluate(async () => {
      appState.priorAuditReference = null;
      await loadPriorAuditReference(appState.currentVenue.id);
      renderGuidedMode();
    });

    // Current zone is "Liquor Room" by default → reference shows the item the
    // prior audit counted THERE (Don Julio 1942), not the carried fallback.
    await expect(page.locator('#guidedContent')).toContainText('Not yet counted');
    await expect.poll(async () =>
      page.locator('#guidedContent .c-item').filter({ hasText: 'Don Julio 1942' }).count()
    ).toBe(1);
    // Campari was counted in "Bar" last time, so it must NOT show under Liquor Room.
    await expect(page.locator('#guidedContent .c-item').filter({ hasText: 'Campari 1L' })).toHaveCount(0);

    // Switch to Bar → its prior-audit reference (Campari) shows instead.
    await page.locator('.zone-tab[data-zone="Bar"]').click();
    await expect.poll(async () =>
      page.locator('#guidedContent .c-item').filter({ hasText: 'Campari 1L' }).count()
    ).toBe(1);
    await expect(page.locator('#guidedContent .c-item').filter({ hasText: 'Don Julio 1942' })).toHaveCount(0);
  });
});
