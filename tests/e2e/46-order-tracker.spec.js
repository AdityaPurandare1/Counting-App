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
    await expect(page.locator('.otx-card')).toHaveCount(0);

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
    await expect(page.locator('#otSubtitle')).toContainText('View only');
    await expect(page.locator('#otSubtitle')).toContainText('Your venues');
    expect(await page.evaluate(() => orderTrackerAccess())).toBe('view');
  });

  // v2.37: the user's design (11/18, "Order tracker - mobile redesign")
  test('corporate: the list - most overdue first, counts, late / unpaid pills, tracking sheet, venue picker, search', async ({ page, db }) => {
    seedOrders(db);
    await loginAs(page, 'corporate');
    await page.locator('#headerMenuBtn').click();
    await page.locator('#headerOrdersBtn').click();
    await expect(page.locator('.otx-card')).toHaveCount(2);                        // open: the late one and the shipped one
    await expect(page.locator('#otVenueTitle')).toHaveText('All venues');
    await expect(page.locator('#otSubtitle')).toContainText('Order tracker');
    await expect(page.locator('[data-otf="open"]')).toContainText('2');
    await expect(page.locator('[data-otf="late"]')).toContainText('1');
    await expect(page.locator('[data-otf="unpaid"]')).toContainText('1');
    await expect(page.locator('#otListTitle')).toHaveText('Open orders');
    const first = page.locator('.otx-card').first();                                 // most overdue first
    await expect(first).toHaveAttribute('data-order', 'o-late');
    await expect(first).toContainText('EE Mercantile');
    await expect(first).toContainText('$826.08');
    await expect(first).toContainText('OSE-0102');
    await expect(first).toContainText('Delilah LA');
    await expect(first).toContainText('2 lines');
    await expect(first.locator('.otx-flag.late')).toContainText(/\d+d late/);
    await expect(first.locator('.otx-pill')).toHaveText('Ordered');                 // headline = the least advanced live line
    await expect(first.locator('.otx-flag.unpaid')).toHaveText('Unpaid');
    await expect(page.locator('[data-order="o-arch"]')).toHaveCount(0);            // archived never shows

    // the truck button: the tracking numbers in a sheet, each once, Copy all, on to the order
    const ship = page.locator('[data-order="o-ship"]');
    await expect(ship.locator('.otx-trackbtn')).toContainText('1');
    await ship.locator('.otx-trackbtn').click();
    const sheet = page.locator('#otSheet');
    await expect(sheet).toBeVisible();
    await expect(sheet).toContainText('Tracking');
    await expect(sheet.locator('a.otx-trackrow')).toHaveAttribute('href', 'https://www.ups.com/track?tracknum=1Z999AA10123456784');
    await expect(sheet.locator('a.otx-trackrow')).toContainText('UPS');
    await sheet.getByRole('button', { name: /Copy all/ }).click();
    await expect(sheet).toContainText('Copied');
    await sheet.getByRole('button', { name: /View order details/ }).click();
    await expect(page.locator('#otDetailView')).toBeVisible();
    await expect(page.locator('#otSheet')).toBeHidden();
    await expect(page.locator('#otDetailView h1')).toHaveText('Everything Promo');
    await page.locator('.otx-back').click();
    await expect(page.locator('#otListView')).toBeVisible();

    // filters
    await page.locator('[data-otf="late"]').click();
    await expect(page.locator('.otx-card')).toHaveCount(1);
    await expect(page.locator('#otListTitle')).toHaveText('Late orders');
    await page.locator('[data-otf="unpaid"]').click();
    await expect(page.locator('.otx-card')).toHaveCount(1);
    await page.locator('[data-otf="all"]').click();
    await expect(page.locator('.otx-card')).toHaveCount(3);                        // + the completed warehouse order
    await expect(page.locator('[data-order="o-done"]')).toContainText('Warehouse');
    await expect(page.locator('[data-order="o-done"]')).toContainText('Completed');

    // the venue picker; a venue with nothing open -> "No orders match", Clear filters
    await page.locator('.otx-venue').click();
    await expect(sheet).toContainText('Venue');
    await sheet.locator('[data-venue="warehouse"]').click();
    await expect(page.locator('#otVenueTitle')).toHaveText('Warehouse');
    await expect(page.locator('.otx-card')).toHaveCount(1);
    await page.locator('[data-otf="open"]').click();
    await expect(page.locator('#otList')).toContainText('No orders match');
    await page.getByRole('button', { name: 'Clear filters' }).click();
    await expect(page.locator('#otVenueTitle')).toHaveText('All venues');
    await expect(page.locator('.otx-card')).toHaveCount(2);

    // search, and its clear button
    await page.fill('#otSearch', 'matchbooks');
    await page.locator('#otSearch').dispatchEvent('input');
    await expect(page.locator('.otx-card')).toHaveCount(1);
    await page.fill('#otSearch', 'INV-2026-100001');
    await page.locator('#otSearch').dispatchEvent('input');
    await expect(page.locator('.otx-card')).toHaveCount(1);
    await page.locator('#otSearchClear').click();
    await expect(page.locator('.otx-card')).toHaveCount(2);
  });

  test('corporate: the order page - summary, late banner, status bar, note, items by status, tracking, invoices', async ({ page, db }) => {
    seedOrders(db);
    await loginAs(page, 'corporate');
    await page.locator('#headerMenuBtn').click();
    await page.locator('#headerOrdersBtn').click();
    await page.locator('[data-order="o-late"] .otx-cardbtn').click();
    const d = page.locator('#otDetailView');
    await expect(d).toBeVisible();
    await expect(d.locator('.otx-dhead')).toContainText('OSE-0102');
    await expect(d.locator('h1')).toHaveText('EE Mercantile');
    await expect(d).toContainText('Delilah LA · 2 lines');
    await expect(d.locator('.otx-big')).toHaveText('$826.08');
    await expect(d.locator('.otx-latebar')).toContainText(/\d+ days late · ETA was 1\/10/);
    await expect(d.locator('.otx-dl')).toContainText('10/20');                      // ordered
    await expect(d.locator('.otx-dl')).toContainText('INV-2026-100001 · covers 1 of 2 lines');
    await expect(d.locator('.otx-legend')).toContainText('1 ordered');
    await expect(d.locator('.otx-legend')).toContainText('1 invoiced');
    await expect(d.locator('.otx-note')).toContainText('Rush for the opening');
    // items: grouped by status, the first group open
    await expect(d.locator('[data-ottab="items"]')).toContainText('2');
    await expect(d.locator('.otx-group')).toHaveCount(2);
    await expect(d).toContainText('Libbey Rocks 9 oz');
    await expect(d).not.toContainText('Libbey Collins 10.5 oz');
    await d.locator('[data-status="INVOICED"]').click();
    await expect(d).toContainText('Libbey Collins 10.5 oz');
    await expect(d).toContainText('6 cs @ $68.84');
    // tracking: none on this order
    await d.locator('[data-ottab="tracking"]').click();
    await expect(d).toContainText('No tracking numbers yet.');
    // invoices: the PDF opens through a signed link
    await page.locator('[data-ottab="invoices"]').click();
    const row = page.locator('#otDetailView .otx-docrow').first();
    await expect(row).toContainText('INV-2026-100001');
    await expect(row).toContainText('1 line · $826.08');
    await page.route('**/storage/v1/object/sign/kount-order-docs/docs/inv-100001.pdf', (route) => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ signedURL: '/object/sign/kount-order-docs/docs/inv-100001.pdf?token=t' }) }));
    await page.context().route('**/storage/v1/object/sign/kount-order-docs/docs/inv-100001.pdf?token=t', (route) =>
      route.fulfill({ status: 200, contentType: 'text/plain', body: 'the invoice' }));   // text: a PDF would download, not navigate
    const [popup] = await Promise.all([page.waitForEvent('popup'), row.click()]);
    await popup.waitForURL(/storage\/v1\/object\/sign\/kount-order-docs\/docs\/inv-100001\.pdf\?token=t/);
    await page.locator('.otx-back').click();
    await expect(page.locator('#otListView')).toBeVisible();
  });

  test('the permission taken away: the item goes, the page closes', async ({ page, db }) => {
    seedOrders(db);
    await loginAs(page, 'corporate');
    await page.locator('#headerMenuBtn').click();
    await page.locator('#headerOrdersBtn').click();
    await expect(page.locator('.otx-card')).toHaveCount(2);
    db.t.app_users.find((u) => u.email === 'apurandare@hwoodgroup.com').features = ['team:issues', 'phone:count'];
    await page.evaluate(() => refreshOrderTrackerAccess());
    await expect(page.locator('#page-orders')).toBeHidden();
    expect(await menuItems(page)).toEqual(MENU_BEFORE);
  });
});
