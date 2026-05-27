const { test, expect, startAuditAs, loginAs, addManual, restInsert, M } = require('../fixtures');

/* These are the tests that would have caught the 13-day outage and the
   readability/RLS issues — they assert the schema constraints + UI invariants
   the app must never regress. */
test.describe('regressions', () => {
  test('REGRESSION: a master id in kount_entries.item_id is rejected by the FK; item_id null is accepted', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await expect.poll(() => db.t.kount_audits.length).toBe(1);
    const auditId = db.t.kount_audits[0].id;

    // The pre-v1.47 buggy payload: master id written into item_id (FK→purchase_items).
    const bad = await restInsert(page, 'kount_entries', {
      audit_id: auditId, item_id: M.belv, master_item_id: M.belv,
      item_name: 'Bug Repro', zone: 'Liquor Room', qty: 1,
      counted_by_email: 'manager@hwood.com', is_recount: false,
    }, 'manager@hwood.com');
    expect(bad.status, 'master id in item_id must be rejected').toBeGreaterThanOrEqual(400);
    expect(String(bad.body && bad.body.code)).toBe('23503');

    // The v1.47 fix: item_id null, real id only in master_item_id → accepted.
    const good = await restInsert(page, 'kount_entries', {
      audit_id: auditId, item_id: null, master_item_id: M.belv,
      item_name: 'Good Repro', zone: 'Liquor Room', qty: 1,
      counted_by_email: 'manager@hwood.com', is_recount: false,
    }, 'manager@hwood.com');
    expect(good.status).toBe(201);
  });

  test('REGRESSION: non-corporate cannot create master_items (RLS 42501)', async ({ page }) => {
    await loginAs(page, 'counter'); // logged in (no audit needed for a direct insert attempt)
    const res = await restInsert(page, 'master_items', { name: 'Sneaky', category: 'Liquor Cost', is_active: true }, 'counter@hwood.com');
    expect(res.status).toBe(403);
    expect(String(res.body && res.body.code)).toBe('42501');
  });

  test('REGRESSION: corporate CAN create master_items', async ({ page, db }) => {
    await loginAs(page, 'corporate');
    const before = db.t.master_items.length;
    const res = await restInsert(page, 'master_items', { name: 'Corp Item', category: 'Liquor Cost', is_active: true }, 'apurandare@hwoodgroup.com');
    expect(res.status).toBe(201);
    expect(db.t.master_items.length).toBe(before + 1);
  });

  test('REGRESSION: count card shows the FULL name and HIDES the UUID', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Don Julio 1942 750ml', 1);
    const cardEl = page.locator('#guidedContent .c-item', { hasText: 'Don Julio 1942 750ml' });
    await expect(cardEl.locator('.c-name')).toHaveText('Don Julio 1942 750ml');
    await expect(cardEl).not.toContainText(M.dj1942); // UUID must not be visible
  });
});
