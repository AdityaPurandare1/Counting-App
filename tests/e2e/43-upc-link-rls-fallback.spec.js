const { test, expect, startAuditAs, M } = require('../fixtures');

/* v2.29: when RLS refuses a non-corporate user's instant (approved) barcode link -- the
   barcode sits on an archived item the phone never loads, or the item already
   has another barcode -- the phone re-sends the same link as 'pending' for
   approval instead of showing a red "couldn't link" error. On 11/2 that error
   fired 24 times on one counter's phone during a live Little Luck count. */
const SUPA = 'https://mnraeesscqsaappkaldb.supabase.co';
const RLS_BODY = '{"code":"42501","details":null,"hint":null,"message":"new row violates row-level security policy for table \\"upc_mappings\\""}';

async function recordToasts(page) {
  await page.evaluate(() => {
    window.__toasts = [];
    const orig = window.showToast;
    window.showToast = function (m, t) { window.__toasts.push({ m: String(m), t: t || '' }); return orig.apply(this, arguments); };
  });
}

test.describe('barcode link RLS fallback (v2.29)', () => {
  test('a refused instant link is re-sent as pending, with no error toast', async ({ page }) => {
    await startAuditAs(page, 'manager');
    const bodies = [];
    await page.route(SUPA + '/rest/v1/upc_mappings*', async (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      const body = JSON.parse(route.request().postData() || '{}');
      bodies.push(body);
      if (body.status === 'approved') {
        return route.fulfill({ status: 403, contentType: 'application/json', body: RLS_BODY });
      }
      return route.fulfill({ status: 201, contentType: 'application/json', body: JSON.stringify([{ id: 'pending-1', ...body }]) });
    });
    await recordToasts(page);
    await page.evaluate((id) => linkUPCToItem('5012345678900', itemMaster.find((i) => i.id === id)), M.belv);

    expect(bodies.map((b) => b.status)).toEqual(['approved', 'pending']);
    expect(bodies[1].barcode_normalized).toBe('5012345678900');
    expect(bodies[1].reviewed_by_email).toBeNull();
    const t = await page.evaluate(() => window.__toasts.slice());
    expect(t.some((x) => /sent for approval/.test(x.m))).toBe(true);
    expect(t.some((x) => x.t === 'error' || /not saved|couldn|row-level|42501/i.test(x.m))).toBe(false);
  });

  test('a refusal of the pending retry still reports the failure', async ({ page }) => {
    await startAuditAs(page, 'manager');
    let posts = 0;
    await page.route(SUPA + '/rest/v1/upc_mappings*', async (route) => {
      if (route.request().method() !== 'POST') return route.continue();
      posts++;
      return route.fulfill({ status: 403, contentType: 'application/json', body: RLS_BODY });
    });
    await recordToasts(page);
    await page.evaluate((id) => linkUPCToItem('5012345678900', itemMaster.find((i) => i.id === id)), M.belv);
    expect(posts).toBe(2);
    const t = await page.evaluate(() => window.__toasts.slice());
    expect(t.some((x) => /sent for approval/.test(x.m))).toBe(false);
    expect(t.some((x) => /not saved/i.test(x.m))).toBe(true);
  });
});
