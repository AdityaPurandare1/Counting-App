// v2.36 - the Order tracker on the phone. The user, 11/17: "in the phone app, i want a section that allows me to
// check the order tracker as well but just for myself and people who have access to order tracker ... for Everyone
// else it should still function the way it is rightnow without the order tracker".
const { test, expect, loginAs } = require('../fixtures');

const MENU_BEFORE = ['Issues Tracker', 'Audit Summary', 'Ask AI', 'Sign Out'];

function seedOrders(db) {
  db.t.kount_ot_orders = [
    { id: 'o-late', order_number: 'OSE-0102', vendor_name: 'EE Mercantile', venue_id: 'v-delilah', deliver_to: 'venue', ordered_on: '2026-10-20',
      expected_on: '2026-01-10', sent_on: '2026-10-21', notes: 'Rush for the opening', completed_at: null, archived_at: null, updated_at: '2026-11-10T10:00:00Z' },
    { id: 'o-ship', order_number: 'CUS-0104', vendor_name: 'Everything Promo', venue_id: 'v-delilah', deliver_to: 'venue', ordered_on: '2026-11-01',
      expected_on: '2099-01-01', sent_on: null, notes: null, completed_at: null, archived_at: null, updated_at: '2026-11-12T10:00:00Z' },
    { id: 'o-done', order_number: 'OSE-0090', vendor_name: 'Libbey', venue_id: null, deliver_to: 'warehouse', ordered_on: '2026-09-01',
      expected_on: null, sent_on: null, notes: null, completed_at: '2026-10-01T10:00:00Z', archived_at: null, updated_at: '2026-10-01T10:00:00Z' },
    { id: 'o-arch', order_number: 'OSE-0001', vendor_name: 'Archived Co', venue_id: 'v-delilah', deliver_to: 'venue', ordered_on: '2026-01-01',
      expected_on: null, sent_on: null, notes: null, completed_at: null, archived_at: '2026-02-01T00:00:00Z', updated_at: '2026-02-01T00:00:00Z' },
  ];
  const line = (o) => Object.assign({ id: 'l-' + Math.random().toString(36).slice(2), sku: null, qty: 6, unit: 'cs', unit_price: 68.84, quote_number: null,
    invoice_number: null, tracking_number: null, expected_on: null, delivered_on: null, venue_id: null, sort: 0 }, o);
  db.t.kount_ot_lines = [
    line({ order_id: 'o-late', description: 'Libbey Collins 10.5 oz', status: 'INVOICED', invoice_number: 'INV-2026-100001' }),
    line({ order_id: 'o-late', description: 'Libbey Rocks 9 oz', status: 'ORDERED', sort: 1 }),
    line({ order_id: 'o-ship', description: 'Custom matchbooks', status: 'SHIPPED', qty: 5000, unit: 'ea', unit_price: 0.31, tracking_number: '1Z999AA10123456784' }),
    line({ order_id: 'o-done', description: 'Steelite plates', status: 'RECEIVED', delivered_on: '2026-09-20' }),
    line({ order_id: 'o-arch', description: 'Never ordered', status: 'REQUESTED' }),
  ];
  db.t.kount_ot_tracking = [];
  db.t.kount_ot_documents = [
    { id: 'd-inv', order_id: 'o-late', kind: 'invoice', doc_number: 'INV-2026-100001', doc_date: '2026-11-09', total: 826.08, file_name: 'INV-2026-100001.pdf',
      storage_path: 'docs/inv-100001.pdf', created_at: '2026-11-09T10:00:00Z' },
  ];
}

async function menuItems(page) {
  await page.locator('#headerMenuBtn').click();
  await expect(page.locator('#headerMenu')).toBeVisible();
  return (await page.locator('#headerMenu button:visible').allInnerTexts()).map((t) => t.trim().replace(/\s+\d+$/, ''));
}

test.describe('v2.36 order tracker on the phone', () => {
  test('a counter and a manager without the permission: no Order tracker, the menu as before', async ({ page, db }) => {
    seedOrders(db);
    await loginAs(page, 'counter');
    await page.waitForTimeout(400);
    expect(await menuItems(page)).toEqual(MENU_BEFORE);
    // the page itself refuses too (the database would return nothing anyway)
    await page.evaluate(() => { closeHeaderMenu(); showPage('orders'); });
    await expect(page.locator('#otList')).toContainText('Order tracker permission');
    await expect(page.locator('.ot-card')).toHaveCount(0);

    await page.evaluate(() => handleLogout());
    await loginAs(page, 'manager');
    await page.waitForTimeout(400);
    expect(await menuItems(page)).toEqual(MENU_BEFORE);
  });

  test('a manager given Order tracker (view): the item shows, labelled view only for their venues', async ({ page, db }) => {
    seedOrders(db);
    db.t.app_users.find((u) => u.email === 'manager@hwood.com').features = ['team:issues', 'admin:approvals', 'phone:count', 'phone:run', 'purchasing:order-tracker-view'];
    await loginAs(page, 'manager');
    await page.locator('#headerMenuBtn').click();
    await expect(page.locator('#headerOrdersBtn')).toBeVisible();
    await page.locator('#headerOrdersBtn').click();
    await expect(page.locator('#page-orders')).toBeVisible();
    await expect(page.locator('#otSubtitle')).toContainText('view only');
    await expect(page.locator('#otSubtitle')).toContainText('venues');
    expect(await page.evaluate(() => orderTrackerAccess())).toBe('view');
  });

  test('corporate: open orders, late / unpaid, search, details, tracking and the invoice', async ({ page, db }) => {
    seedOrders(db);
    await loginAs(page, 'corporate');
    await page.locator('#headerMenuBtn').click();
    await page.locator('#headerOrdersBtn').click();
    await expect(page.locator('.ot-card')).toHaveCount(2);                       // open: the late one and the shipped one
    await expect(page.locator('#otStats')).toContainText('2');
    await expect(page.locator('.ot-card').first()).toContainText('EE Mercantile');  // late first
    await expect(page.locator('.ot-card').first()).toContainText('LATE');
    await expect(page.locator('.ot-card').first()).toContainText('UNPAID');
    await expect(page.locator('.ot-card').first()).toContainText('Ordered');     // headline = the least advanced live line
    await expect(page.locator('[data-order="o-ship"]')).toContainText('UPS 1Z999AA10123456784');
    await expect(page.locator('[data-order="o-ship"] a')).toHaveAttribute('href', 'https://www.ups.com/track?tracknum=1Z999AA10123456784');
    await expect(page.locator('[data-order="o-arch"]')).toHaveCount(0);           // archived never shows

    await page.locator('[data-otf="late"]').click();
    await expect(page.locator('.ot-card')).toHaveCount(1);
    await page.locator('[data-otf="unpaid"]').click();
    await expect(page.locator('.ot-card')).toHaveCount(1);
    await page.locator('[data-otf="all"]').click();
    await expect(page.locator('.ot-card')).toHaveCount(3);                       // + the completed warehouse order
    await expect(page.locator('[data-order="o-done"]')).toContainText('Warehouse');
    await page.fill('#otSearch', 'matchbooks');
    await expect(page.locator('.ot-card')).toHaveCount(1);
    await page.fill('#otSearch', 'INV-2026-100001');
    await expect(page.locator('.ot-card')).toHaveCount(1);

    // details: the lines with their status and invoice, the notes, the invoice document
    await page.locator('[data-order="o-late"] > div').first().click();
    const card = page.locator('[data-order="o-late"]');
    await expect(card).toContainText('Libbey Collins 10.5 oz');
    await expect(card).toContainText('Inv INV-2026-100001');
    await expect(card).toContainText('Rush for the opening');
    // the fixture's catch-all is a PAGE route, so the signing mock is one too (later page routes win); the popup is a new page
    await page.route('**/storage/v1/object/sign/kount-order-docs/docs/inv-100001.pdf', (route) => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ signedURL: '/object/sign/kount-order-docs/docs/inv-100001.pdf?token=t' }) }));
    await page.context().route('**/storage/v1/object/sign/kount-order-docs/docs/inv-100001.pdf?token=t', (route) =>
      route.fulfill({ status: 200, contentType: 'text/plain', body: 'the invoice' }));   // text: a PDF would download, not navigate
    const [popup] = await Promise.all([page.waitForEvent('popup'), card.getByRole('button', { name: /Invoice INV-2026-100001/ }).click()]);
    await popup.waitForURL(/storage\/v1\/object\/sign\/kount-order-docs\/docs\/inv-100001\.pdf\?token=t/);
  });

  test('the permission taken away: the item goes, the page closes', async ({ page, db }) => {
    seedOrders(db);
    await loginAs(page, 'corporate');
    await page.locator('#headerMenuBtn').click();
    await page.locator('#headerOrdersBtn').click();
    await expect(page.locator('.ot-card')).toHaveCount(2);
    db.t.app_users.find((u) => u.email === 'apurandare@hwoodgroup.com').features = ['team:issues', 'phone:count'];
    await page.evaluate(() => refreshOrderTrackerAccess());
    await expect(page.locator('#page-orders')).toBeHidden();
    expect(await menuItems(page)).toEqual(MENU_BEFORE);
  });
});
