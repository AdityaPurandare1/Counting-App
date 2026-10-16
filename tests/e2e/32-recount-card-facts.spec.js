/* v2.19 RECOUNT CARD FACTS ON EVERY PHONE.
 *
 * The recount list is created on the manager's phone, but counters' phones load
 * it from kount_recounts, which stores no theo / start / purchases / depletions /
 * weeks and (at creation) no variance_qty. Hydrated rows came back with
 * variance 0 and theo 0, so v2.15/v2.16 told counters "No change this count" and
 * "System expects 0" for an item that was 5 bottles short, and before that the
 * card showed no over/short at all (Poppy, P-843).
 *
 * Rows are written straight into the mock's kount_recounts and the page pulls
 * them through the real refreshRecountsFromSupabase, i.e. the second-phone path.
 * Nothing is typed into the Manual modal, so these don't depend on its timing.
 */
const { test, expect, startAuditAs } = require('../fixtures');

const card = (page) => page.locator('div.focus-item[data-recount-item="Belvedere 1L"]');

const AVT = (over) => Object.assign({
  store: '', itemName: 'Belvedere 1L', category: 'Liquor Cost', actual: 3, theo: 8,
  variance: -5, varianceValue: -150, variancePct: -62.5, cuPrice: 30,
  start: 8, purchases: 0, depletions: 0,
}, over || {});

/* Second-phone path: DB row only, no local recounts, then render. */
async function secondPhone(page, db, avtRow) {
  db.t.kount_recounts = [{
    id: 'rc-1', audit_id: db.t.kount_audits[0].id, item_id: null, master_item_id: null,
    item_name: 'Belvedere 1L', severity: 'HIGH', variance_value: -150, count1_qty: 3,
    count2_qty: null, status: 'pending', zone: 'Liquor Room', category: 'Liquor Cost',
  }];
  await page.evaluate(async (row) => {
    appState.audit.countPhase = 'review';
    appState.audit.recounts = {};
    appState.avtData = row ? [Object.assign({ venueId: appState.currentVenue.id, venueName: appState.currentVenue.name }, row)] : [];
    await refreshRecountsFromSupabase();
    renderRecountPage();
  }, avtRow);
  await card(page).waitFor({ state: 'attached' });
}

test.describe('v2.19 recount card on a phone that loaded the list from the database', () => {
  test('shows the real over/short and where the expected number comes from', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await secondPhone(page, db, AVT({ theo: 6, variance: -5, start: 8, purchases: 0, depletions: 2 }));
    const text = await card(page).innerText();
    expect(text).toContain('5.0 bottles short');
    expect(text).toContain('System expects 6');
    expect(text).toContain('(8 at last count + 0 received − 2 used)');
    expect(text).not.toContain('No change this count');
    expect(text).not.toContain('expects 0');
  });

  test('a genuinely unchanged item still says so', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await secondPhone(page, db, AVT({ actual: 6, theo: 6, variance: 0, varianceValue: 0, start: 6, purchases: 0, depletions: 0 }));
    const text = await card(page).innerText();
    expect(text).toContain('No change this count');
    expect(text).toContain('System expects 6');
  });

  test('no AVT row for the item: says nothing false (no zero variance, no "expects 0")', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await secondPhone(page, db, null);
    const text = await card(page).innerText();
    expect(text).not.toContain('No change this count');
    expect(text).not.toContain('System expects');
    expect(text).not.toContain('bottle');
    expect(text).toContain('Count 1 total: 3'); // the card still works
  });

  test('first count (no baseline): no meaningless "expects 0"', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await secondPhone(page, db, AVT({ theo: 0, variance: 3, start: 0, purchases: 0, depletions: 0 }));
    const text = await card(page).innerText();
    expect(text).not.toContain('System expects');
  });

  test('parts that do not add up are not shown (expected still is)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await secondPhone(page, db, AVT({ theo: 6, variance: -5, start: 9, purchases: 0, depletions: 2 }));
    const text = await card(page).innerText();
    expect(text).toContain('System expects 6');
    expect(text).not.toContain('at last count');
  });
});

test.describe('v2.19 recount card on the phone that created the list', () => {
  test('uses the stored facts, including the breakdown', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    db.t.kount_recounts = [];
    await page.evaluate(() => {
      appState.audit.countPhase = 'review';
      appState.avtData = [];
      appState.audit.recounts = { 'Belvedere 1L|Liquor Room': {
        itemName: 'Belvedere 1L', avtItem: { itemName: 'Belvedere 1L' }, severity: 'HIGH',
        varianceValue: -150, variance: -5, weeksActive: 0, actual: 3, theo: 8,
        start: 10, purchases: 0, depletions: 2, count1Qty: 3, recountQty: null,
        status: 'pending', notes: '', zone: 'Liquor Room', category: 'Liquor Cost',
        auditResult: null, auditReason: '', counterInitials: '' } };
      renderRecountPage();
    });
    const text = await card(page).innerText();
    expect(text).toContain('5.0 bottles short');
    expect(text).toContain('System expects 8 (10 at last count + 0 received − 2 used)');
  });

  test('closeCount1 stores start / purchases / depletions on every zone row', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const src = await page.evaluate(() => closeCount1.toString());
    expect(src).toContain('start: item.avt.start');
    expect(src).toContain('purchases: item.avt.purchases');
    expect(src).toContain('depletions: item.avt.depletions');
  });
});

test.describe('v2.19 expected 0 that is explained', () => {
  test('5 at last count - 5 used = 0 is shown with its parts', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await secondPhone(page, db, AVT({ theo: 0, variance: 3, start: 5, purchases: 0, depletions: 5 }));
    const text = await card(page).innerText();
    expect(text).toContain('System expects 0 (5 at last count + 0 received − 5 used)');
  });
});
