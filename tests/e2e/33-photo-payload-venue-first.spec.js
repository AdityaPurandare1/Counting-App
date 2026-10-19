/* v2.19 — the photo matcher sees THIS venue's items first.

   Little Luck 2026-10-18: parseLabelWithClaude sends Claude a catalog snapshot
   capped at 250 items per list, sorted alphabetically, drawn from
   kount_carried_items -- which is GLOBAL (~5.7k rows, every venue's stock).
   Only 4 of the 143 wine/sake items Little Luck had just loaded fell inside
   that window, so Claude was never shown the bottles it was asked to
   recognise.

   Fix: items this venue has priced (kount_venue_cost_overrides) or counted
   (kount_entries of its recent audits) lead the payload; the rest follows.

   The mock only carries ~10 items, so the 250 cap never bites here. These
   tests therefore assert ORDER: a venue item that sorts LAST alphabetically
   must arrive FIRST. FAIL-BEFORE (v2.18): it arrived last. */
const { test, expect, startAuditAs } = require('../fixtures');

const VENUE_ITEM = '99999999-9999-4999-8999-99999999aa01';
const VENUE_NAME = 'Zzz Venue Sake 720ml';   // deliberately sorts last

async function addCarriedMaster(page, db) {
  db.t.master_items.push({
    id: VENUE_ITEM, organization_id: 'org-1', name: VENUE_NAME,
    category: 'Wine Cost', subcategory: null, base_size: 720, base_unit: 'ml',
    is_active: true, created_at: '2026-10-19T00:00:00Z', product_id: null,
  });
  db.t.kount_carried_items.push({ master_item_id: VENUE_ITEM });
  // v2.18 top-up pulls it into the already-loaded catalog.
  await page.evaluate(() => window.loadCarriedItemsFromSupabase());
  await expect.poll(() => page.evaluate(() => window.searchItemMaster('zzz venue', 5).length),
    { timeout: 8000 }).toBe(1);
}

// Call the real photo path and capture exactly what is sent to the Edge Function.
async function capturePhotoPayload(page) {
  const bodyP = page.waitForRequest((r) => r.url().includes('/functions/v1/parse-bottle-label'));
  await page.evaluate(() => window.parseLabelWithClaude('data:image/jpeg;base64,AAAA').catch(() => null));
  const req = await bodyP;
  return JSON.parse(req.postData() || '{}');
}

test.describe('v2.19 photo payload is venue-first', () => {
  test('an item this venue has PRICED leads the payload even though it sorts last', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const venueId = db.t.kount_audits[0].venue_id;
    await addCarriedMaster(page, db);

    db.t.kount_venue_cost_overrides = [
      { venue_id: venueId, master_item_id: VENUE_ITEM, cost_per_unit: 42 },
    ];

    const body = await capturePhotoPayload(page);
    expect(Array.isArray(body.carried)).toBe(true);
    expect(body.carried[0].name).toBe(VENUE_NAME);
  });

  test('an item this venue has COUNTED leads the payload too', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    const audit = db.t.kount_audits[0];
    await addCarriedMaster(page, db);

    db.t.kount_entries.push({
      id: 'e-venue-1', audit_id: audit.id, item_name: VENUE_NAME, master_item_id: VENUE_ITEM,
      qty: 2, zone: 'Bar', counted_by_email: 'manager@hwood.com', is_recount: false,
    });

    const body = await capturePhotoPayload(page);
    expect(body.carried[0].name).toBe(VENUE_NAME);
  });

  test('with no venue signal the payload is plain alphabetical, as before', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addCarriedMaster(page, db);   // carried, but neither priced nor counted here

    const body = await capturePhotoPayload(page);
    const names = body.carried.map((c) => c.name);
    expect(names).toEqual([...names].sort((a, b) => a.localeCompare(b)));
    // So the alphabetically-last item stays last.
    expect(names[names.length - 1]).toBe(VENUE_NAME);
  });

  test('another venue\'s prices do not leak into this venue\'s ordering', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addCarriedMaster(page, db);
    db.t.kount_venue_cost_overrides = [
      { venue_id: 'some-other-venue', master_item_id: VENUE_ITEM, cost_per_unit: 42 },
    ];
    const body = await capturePhotoPayload(page);
    const names = body.carried.map((c) => c.name);
    expect(names[names.length - 1]).toBe(VENUE_NAME);
  });
});
