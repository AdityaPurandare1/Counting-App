const { test, expect, startAuditAs } = require('../fixtures');

/* Floating calculator: edge-docked FAB (fully visible, a small gap inside
   the snapped edge) + compact panel that shares state with the Calculator
   page. Covers: overlap-proofing on every page (the docked button must
   never sit on another tap target), tap-to-open / outside-tap-minimize,
   drag + snap + localStorage persistence, and the hide-while-camera-is-live
   requirement. */

/* Runs in the page. Compares the docked FAB's box (viewport-clamped)
   against every visible leaf interactive element. [onclick] containers
   (modal backdrops, sheet wrappers) are skipped — their leaf controls are
   what we measure; a backdrop "under" the FAB is fine because the FAB
   out-stacks it (the elementFromPoint assertion proves that). */
function overlapAudit() {
  const fab = document.getElementById('calcFab');
  const panel = document.getElementById('calcFabPanel');
  if (!fab || fab.classList.contains('hide')) return { error: 'FAB not visible' };
  const vw = window.innerWidth, vh = window.innerHeight;
  const clamp = (r) => ({
    left: Math.max(0, r.left), top: Math.max(0, r.top),
    right: Math.min(vw, r.right), bottom: Math.min(vh, r.bottom),
  });
  const f = clamp(fab.getBoundingClientRect());
  const SEL = 'button, a, input, select, textarea, [onclick]';
  const isNativeControl = (el) => /^(BUTTON|A|INPUT|SELECT|TEXTAREA)$/.test(el.tagName);
  const hits = [];
  document.querySelectorAll(SEL).forEach((el) => {
    if (el === fab || fab.contains(el)) return;
    if (panel && (el === panel || panel.contains(el))) return;
    // Skip [onclick] containers that host other controls (overlay/sheet).
    if (!isNativeControl(el) && el.querySelector(SEL)) return;
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.pointerEvents === 'none') return;
    const raw = el.getBoundingClientRect();
    if (raw.width === 0 || raw.height === 0) return; // display:none ancestor etc.
    const c = clamp(raw);
    if (c.right <= c.left || c.bottom <= c.top) return; // fully offscreen
    const overlaps = c.left < f.right && c.right > f.left && c.top < f.bottom && c.bottom > f.top;
    if (overlaps) {
      hits.push(el.tagName + (el.id ? '#' + el.id : '') +
        ' "' + (el.textContent || el.value || '').trim().slice(0, 30) + '"');
    }
  });
  // Hit-test: the visual center of the docked strip must resolve to the FAB.
  const at = document.elementFromPoint((f.left + f.right) / 2, (f.top + f.bottom) / 2);
  return { hits, hitTestOk: at === fab || fab.contains(at) };
}

async function fabVisible(page) {
  return page.evaluate(() => {
    const fab = document.getElementById('calcFab');
    return !!fab && !fab.classList.contains('hide');
  });
}

async function panelVisible(page) {
  return page.evaluate(() => {
    const p = document.getElementById('calcFabPanel');
    return !!p && !p.classList.contains('hide');
  });
}

/* The docked button is fully on-screen, so a plain center click works. */
async function tapFab(page) {
  await page.locator('#calcFab').click();
}

test.describe('floating calculator', () => {
  test.beforeEach(async ({ page }) => { await startAuditAs(page, 'manager'); });

  test('overlap-proof walk: docked FAB never covers an interactive element', async ({ page }) => {
    const pages = ['count', 'venues', 'variance', 'summary', 'issues', 'recount'];
    for (const p of pages) {
      await page.evaluate((pg) => window.showPage(pg), p);
      const audit = await page.evaluate(overlapAudit);
      expect(audit.error, p + ': ' + (audit.error || '')).toBeUndefined();
      expect(audit.hits, p + ' overlaps: ' + JSON.stringify(audit.hits)).toEqual([]);
      expect(audit.hitTestOk, p + ': FAB must win elementFromPoint').toBe(true);
    }

    // Redundant on the calculator page itself — must be hidden there.
    await page.evaluate(() => window.showPage('calculator'));
    expect(await fabVisible(page)).toBe(false);
    await page.evaluate(() => window.showPage('count'));
    expect(await fabVisible(page)).toBe(true);

    // With the add-item (Manual entry) modal open.
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    const audit = await page.evaluate(overlapAudit);
    expect(audit.hits, 'manual modal overlaps: ' + JSON.stringify(audit.hits)).toEqual([]);
    expect(audit.hitTestOk).toBe(true);
    await page.locator('#manualModal .close-x').click();
    await page.locator('#manualModal').waitFor({ state: 'hidden' });
  });

  test('tap opens panel, calcInput works, outside tap minimizes', async ({ page }) => {
    expect(await fabVisible(page)).toBe(true);
    expect(await panelVisible(page)).toBe(false);

    await tapFab(page);
    expect(await panelVisible(page)).toBe(true);

    // 2 + 3 = 5, rendered in the PANEL display.
    const panel = page.locator('#calcFabPanel');
    await panel.getByRole('button', { name: '2', exact: true }).click();
    await panel.getByRole('button', { name: '+', exact: true }).click();
    await panel.getByRole('button', { name: '3', exact: true }).click();
    await panel.getByRole('button', { name: '=', exact: true }).click();
    await expect(page.locator('#calcFabResult')).toHaveText('5');
    // Shared state: the page display mirrors the panel.
    await expect(page.locator('#calcResult')).toHaveText('5', { useInnerText: true });

    // Outside tap minimizes back to the tab (and is swallowed — no side
    // effects on the underlying page are asserted here by design). The
    // point must be outside the panel, which opens anchored to the right
    // dock (~x 109+ on a 393px viewport), so tap the upper-left content.
    await page.mouse.click(40, 150);
    expect(await panelVisible(page)).toBe(false);
    expect(await fabVisible(page)).toBe(true);
  });

  test('drag snaps to the left edge and persists; drag never opens the panel', async ({ page }) => {
    const box = await page.locator('#calcFab').boundingBox();
    await page.mouse.move(box.x + 22, box.y + 22);
    await page.mouse.down();
    await page.mouse.move(200, box.y + 80, { steps: 6 });
    await page.mouse.move(40, box.y + 120, { steps: 6 });
    await page.mouse.up();

    expect(await panelVisible(page), 'drag must not open the panel').toBe(false);

    // Snapped to the left edge: fully visible, a small gap inside it.
    await expect.poll(() =>
      page.evaluate(() => document.getElementById('calcFab').getBoundingClientRect().left)
    ).toBeLessThan(20);
    expect(await page.evaluate(() =>
      document.getElementById('calcFab').getBoundingClientRect().left
    ), 'docked button must be fully on-screen').toBeGreaterThanOrEqual(0);

    // Persisted dock (localStorage is wiped on navigation by the test
    // harness, so we assert the stored value instead of reloading).
    const saved = await page.evaluate(() =>
      JSON.parse(localStorage.getItem('hwood_calc_fab_pos_v1')));
    expect(saved.side).toBe('left');
    expect(typeof saved.top).toBe('number');

    // Still tappable on its new dock.
    await tapFab(page);
    expect(await panelVisible(page)).toBe(true);
  });

  test('forced hide with the panel open resets it: no auto-reopen, next tap lands', async ({ page }) => {
    // Open the panel, then navigate away programmatically while it's open —
    // the SIGNED_OUT → showPage('login') path. updateCalcFabVisibility must
    // reset the open flag on a forced hide, not just hide the elements.
    await tapFab(page);
    expect(await panelVisible(page)).toBe(true);
    await page.evaluate(() => window.showPage('login'));
    expect(await fabVisible(page)).toBe(false);
    expect(await panelVisible(page)).toBe(false);

    // Back on an allowed page: the panel must stay minimized…
    await page.evaluate(() => window.showPage('count'));
    expect(await fabVisible(page)).toBe(true);
    expect(await panelVisible(page), 'panel must not auto-reopen').toBe(false);

    // …and the first tap must land on the page instead of being swallowed
    // by the outside-tap handler (which gates on that same flag).
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.locator('#manualModal .close-x').click();
    await page.locator('#manualModal').waitFor({ state: 'hidden' });
  });

  test('cancelled outside gesture (no click) does not eat the next real click', async ({ page }) => {
    await tapFab(page);
    expect(await panelVisible(page)).toBe(true);

    // pointerdown outside the open panel arms the click swallower; a touch
    // scroll / OS interruption then ends in pointercancel — no click ever
    // fires for this gesture, so only the disarm path can clear the flag.
    await page.evaluate(() => {
      const t = document.querySelector('.header') || document.body;
      const opts = { bubbles: true, cancelable: true, pointerId: 7, pointerType: 'touch' };
      t.dispatchEvent(new PointerEvent('pointerdown', opts));
      t.dispatchEvent(new PointerEvent('pointercancel', opts));
    });
    expect(await panelVisible(page), 'gesture still minimizes the panel').toBe(false);

    // The 0-ms disarm timer must have cleared the swallow flag by now, so
    // the next REAL click goes through instead of being silently eaten.
    await page.waitForTimeout(50);
    await page.getByRole('button', { name: 'Manual' }).click();
    await page.locator('#manualModal').waitFor({ state: 'visible' });
    await page.locator('#manualModal .close-x').click();
    await page.locator('#manualModal').waitFor({ state: 'hidden' });
  });

  test('camera in use hides the FAB and panel completely; close restores the docked tab', async ({ page }) => {
    // Open the panel first to prove camera-close restores DOCKED state,
    // not the open panel.
    await tapFab(page);
    expect(await panelVisible(page)).toBe(true);

    // Barcode scanner (mock BarcodeDetector/getUserMedia from fixtures).
    await page.evaluate(() => window.openBarcodeScanner());
    expect(await fabVisible(page)).toBe(false);
    expect(await panelVisible(page)).toBe(false);
    await page.evaluate(() => window.closeBarcodeScanner());
    expect(await fabVisible(page)).toBe(true);
    expect(await panelVisible(page), 'panel must not auto-reopen').toBe(false);

    // Photo capture path uses the same hooks. The mocked getUserMedia
    // stream makes the <video>.srcObject assignment throw, which routes
    // into closePhotoCapture (the error path we also want covered) — so
    // the hidden state must be read synchronously, before that microtask.
    const hiddenDuringPhoto = await page.evaluate(() => {
      window.openPhotoCapture();
      return document.getElementById('calcFab').classList.contains('hide');
    });
    expect(hiddenDuringPhoto).toBe(true);
    await page.evaluate(() => window.closePhotoCapture());
    expect(await fabVisible(page)).toBe(true);
  });
});
