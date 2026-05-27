/* Playwright base: fresh in-memory mock DB per test, browser stubs for the
   things a headless browser can't do (Supabase client, camera, OCR, vibrate),
   request routing so all Supabase/Edge/CDN traffic hits the mock, and persona
   helpers that drive the REAL login + audit UI like a human. */
const base = require('@playwright/test');
const { MockDB } = require('./mock/mockdb');
const { M } = require('./mock/fixtures');

const SUPA_HOST = 'https://mnraeesscqsaappkaldb.supabase.co';

const PERSONAS = {
  corporate: { email: 'apurandare@hwoodgroup.com', pw: 'pw', name: 'Aditya', role: 'corporate' },
  manager:   { email: 'manager@hwood.com',         pw: 'pw', name: 'Manny',  role: 'manager' },
  counter:   { email: 'counter@hwood.com',          pw: 'pw', name: 'Casey',  role: 'counter' },
};

/* Runs in the page BEFORE any app script. Replaces external deps with stubs.
   window.supabase must be set here so the (routed-to-empty) CDN script can't
   override it. */
function installStubs() {
  // Each navigation starts from a clean slate (no persisted user/audit) so a
  // prior persona isn't auto-restored — important when a test logs in twice
  // (e.g. manager starts, then a counter joins).
  try { localStorage.clear(); } catch (e) {}
  let __session = null;
  let __authCb = null;
  window.supabase = {
    createClient: function () {
      return {
        auth: {
          getSession: async () => ({ data: { session: __session }, error: null }),
          getUser: async () => ({ data: { user: __session ? __session.user : null }, error: null }),
          onAuthStateChange: (cb) => { __authCb = cb; return { data: { subscription: { unsubscribe() {} } } }; },
          signInWithPassword: async ({ email }) => {
            __session = { access_token: 'mocktok.' + encodeURIComponent(email), user: { email: email, id: 'auth-' + email } };
            if (__authCb) try { __authCb('SIGNED_IN', __session); } catch (e) {}
            return { data: { session: __session, user: __session.user }, error: null };
          },
          signInWithOtp: async () => ({ data: {}, error: null }),
          signOut: async () => { __session = null; return { error: null }; },
          resetPasswordForEmail: async () => ({ data: {}, error: null }),
          updateUser: async () => ({ data: {}, error: null }),
        },
        channel: function () { const o = { on: () => o, subscribe: (cb) => { if (cb) setTimeout(() => cb('SUBSCRIBED'), 0); return o; }, unsubscribe() {}, send() {} }; return o; },
        removeChannel: async () => {},
        from: function () { const c = { select: () => c, insert: () => c, update: () => c, delete: () => c, eq: () => c, order: () => c, limit: () => c, single: async () => ({ data: null, error: null }) }; return c; },
      };
    },
  };
  window.Quagga = { init: (cfg, cb) => { if (cb) cb(null); }, start() {}, stop() {}, onDetected() {}, offDetected() {}, decodeSingle(c, cb) { if (cb) cb({}); } };
  window.XLSX = { read: () => ({ SheetNames: [], Sheets: {} }), utils: { sheet_to_json: () => [], book_new: () => ({}), json_to_sheet: () => ({}), book_append_sheet: () => {} }, writeFile: () => {} };
  window.Tesseract = { createWorker: async () => ({ load: async () => {}, loadLanguage: async () => {}, initialize: async () => {}, setParameters: async () => {}, recognize: async () => ({ data: { text: '' } }), terminate: async () => {} }) };
  window.BarcodeDetector = class {
    static async getSupportedFormats() { return ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'code_128', 'code_39', 'code_93', 'codabar', 'itf', 'qr_code']; }
    constructor() {}
    async detect() { return window.__nextBarcode ? [{ rawValue: window.__nextBarcode, format: 'ean_13' }] : []; }
  };
  if (!navigator.mediaDevices) navigator.mediaDevices = {};
  navigator.mediaDevices.getUserMedia = async () => {
    const track = { stop() {}, kind: 'video', getCapabilities: () => ({}), applyConstraints: async () => {}, getSettings: () => ({}) };
    return { getTracks: () => [track], getVideoTracks: () => [track], getAudioTracks: () => [] };
  };
  try { navigator.vibrate = () => true; } catch (e) {}
}

const test = base.test.extend({
  db: async ({}, use) => { await use(new MockDB()); },

  page: async ({ page, db }, use) => {
    await page.addInitScript(installStubs);

    // Stub the CDN libs (we set our own window.supabase/Quagga/etc. above).
    await page.route(/cdnjs\.cloudflare\.com|cdn\.jsdelivr\.net/, (route) =>
      route.fulfill({ status: 200, contentType: 'text/javascript', body: '/* stubbed in tests */' }));

    // All Supabase REST / RPC / Edge traffic → the in-memory mock.
    await page.route(SUPA_HOST + '/**', async (route, req) => {
      const u = new URL(req.url());
      const path = u.pathname;
      const method = req.method();
      const headers = req.headers();
      let body = null; try { body = req.postDataJSON(); } catch (e) { body = null; }
      let r;
      if (path.startsWith('/rest/v1/rpc/')) r = db.handle(method, null, '', headers, body, 'rpc', path.slice('/rest/v1/rpc/'.length));
      else if (path.startsWith('/functions/v1/')) r = db.handle(method, null, '', headers, body, 'edge', path.slice('/functions/v1/'.length));
      else if (path.startsWith('/rest/v1/')) r = db.handle(method, path.slice('/rest/v1/'.length), u.search.slice(1), headers, body);
      else r = { status: 200, body: {} };
      await route.fulfill({ status: r.status, contentType: 'application/json', body: JSON.stringify(r.body === undefined ? null : r.body) });
    });

    await use(page);
  },
});

// ---- human-like helpers ---------------------------------------------------
async function loginAs(page, personaKey) {
  const p = PERSONAS[personaKey];
  await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
  await page.locator('#page-login').waitFor({ state: 'visible' });
  await page.fill('#loginEmail', p.email);
  await page.fill('#loginPassword', p.pw);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.locator('#page-login').waitFor({ state: 'hidden' });
  return p;
}

async function selectVenueAndStart(page) {
  await page.getByText('Delilah LA').first().click();
  await page.locator('#preAuditScreen').waitFor({ state: 'visible' });
  await page.getByRole('button', { name: /^Start audit/i }).click();
  await page.locator('#activeAuditContent').waitFor({ state: 'visible' });
  // The "Audit started — share this code" modal overlays the screen and
  // intercepts taps; dismiss it before counting.
  const gotIt = page.getByRole('button', { name: /^Got it/i });
  if (await gotIt.isVisible().catch(() => false)) await gotIt.click();
  await page.locator('#auditCodeModal').waitFor({ state: 'hidden' }).catch(() => {});
}

async function startAuditAs(page, personaKey) {
  await loginAs(page, personaKey);
  await selectVenueAndStart(page);
}

/* Counters can't START an audit — they join one by code. */
async function joinAuditAs(page, personaKey, code) {
  await loginAs(page, personaKey);
  await page.getByText('Delilah LA').first().click();
  await page.locator('#preAuditScreen').waitFor({ state: 'visible' });
  await page.getByRole('button', { name: /^Join audit/i }).click();
  await page.locator('#joinAuditCodeInput').waitFor({ state: 'visible' });
  await page.fill('#joinAuditCodeInput', code);
  await page.getByRole('button', { name: /^Join$/ }).click();
  await page.locator('#activeAuditContent').waitFor({ state: 'visible' });
}

/* Add an item via the Manual entry modal. An exact catalog name auto-links to
   its master (addCountEntry name-match); a novel name becomes a custom item. */
async function addManual(page, name, qty) {
  await page.getByRole('button', { name: 'Manual' }).click();
  await page.locator('#manualModal').waitFor({ state: 'visible' });
  await page.fill('#manualName', name);
  await page.fill('#manualQty', String(qty));
  await page.locator('#manualModal').getByRole('button', { name: 'Add to count', exact: true }).click();
  await page.locator('#manualModal').waitFor({ state: 'hidden' });
}

async function switchZone(page, zone) {
  await page.locator('.zone-tab[data-zone="' + zone + '"]').click();
}

// Read the app's own counted state (getAllCountedItems is a global function).
async function counted(page) {
  return page.evaluate(() => window.getAllCountedItems());
}

// Locate a count card (unified "This Zone" view) by item name.
function card(page, name) {
  return page.locator('#guidedContent .c-item', { hasText: name });
}
async function tapPlus(page, name) {
  await card(page, name).getByRole('button', { name: '+', exact: true }).click();
}
async function tapMinus(page, name) {
  await card(page, name).getByRole('button', { name: '-', exact: true }).click();
}
async function qtyOf(page, name) {
  const items = await counted(page);
  const hit = items.find((i) => i.name === name);
  return hit ? hit.qty : null;
}

/* Raw REST insert carrying a persona's auth, so the mock applies RLS/FK just
   as it would for the app's own supabaseRest calls. (supabaseRest is a module
   const, not a global, so we hit the endpoint directly — same code path.) */
async function restInsert(page, table, body, asEmail) {
  return page.evaluate(async ({ host, table, body, asEmail }) => {
    const r = await fetch(host + '/rest/v1/' + table, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json', apikey: 'anon',
        Authorization: 'Bearer mocktok.' + encodeURIComponent(asEmail),
        Prefer: 'return=representation',
      },
      body: JSON.stringify(body),
    });
    let j = null; try { j = await r.json(); } catch (e) {}
    return { status: r.status, body: j };
  }, { host: 'https://mnraeesscqsaappkaldb.supabase.co', table, body, asEmail });
}

module.exports = {
  test, expect: base.expect, PERSONAS, M,
  loginAs, selectVenueAndStart, startAuditAs, joinAuditAs, addManual, switchZone, counted,
  card, tapPlus, tapMinus, qtyOf, restInsert,
};
