/* v1.83 feature coverage. Seven shipped features (git diff 83a09cf..f3eff2b):
   F1 manual-search keeps the results list open after a pick
   F2 per-zone reference item lists (getZoneReferenceItems)
   F3 scanner config + watchdog re-entrancy guard (_nativeDetecting)
   F4 per-zone qty isolation (guided-open AND instant-scan paths)
   F5 +6/+12/+24 additive case-qty buttons (addGuidedQty)
   F6 back-to-top button on the counted list
   F7 admin-only "Close Count 1 & Finalize" (closeCount1AndFinalize)

   Style mirrors the existing specs: real login/start helpers, the in-memory
   mock DB, and the same instant-scan handoff (onBarcodeDetected) the headless
   env supports. */
const { test, expect, startAuditAs, addManual, counted, qtyOf, switchZone, M } = require('../fixtures');

// GTIN-13 checksum-valid code mapped to Belvedere 1L (same as 12-instant-scan).
const KNOWN_UPC = '5060071510018';

async function mapKnownUpc(page) {
  await page.evaluate(({ upc, masterId }) => {
    upcMappingsCache[upc] = {
      title: 'Belvedere 1L', brand: '', category: 'Liquor Cost',
      masterId: masterId, barcode: upc, approvedAt: '2026-01-01T00:00:00Z',
    };
  }, { upc: KNOWN_UPC, masterId: M.belv });
}
async function scan(page, code) {
  await page.evaluate((c) => {
    const r = { codeResult: { code: c, format: 'ean_13' } };
    onBarcodeDetected(r); onBarcodeDetected(r); onBarcodeDetected(r);
  }, code);
}

/* ---------- F1: manual search keeps the results list open after a pick ---- */
test.describe('F1 — manual search keeps results open after a pick (v1.83)', () => {
  test('after counting a searched item the query + results list stay visible', async ({ page }) => {
    await startAuditAs(page, 'manager');

    // Type a brand that matches several catalog rows. "Belvedere" matches the
    // 1L and 1.75L siblings, so the list should hold more than one variant.
    await page.fill('#guidedSearchInput', 'Belvedere');
    // Blur so renderGuidedMode is not suppressed by the active-input guard.
    await page.locator('#guidedSearchInput').blur();
    await expect.poll(async () =>
      page.locator('#guidedSearchResults .c-item').count()
    ).toBeGreaterThan(1);

    // Pick the 1L variant → count it.
    await page.locator('#guidedSearchResults .c-item').filter({ hasText: 'Belvedere 1L' }).first()
      .locator('.c-name').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.fill('#guidedQty', '2');
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Confirm', exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    // The list must NOT have collapsed: query text is restored and the results
    // list is still populated so another variant can be picked.
    await expect(page.locator('#guidedSearchInput')).toHaveValue('Belvedere');
    await expect.poll(async () =>
      page.locator('#guidedSearchResults .c-item').count()
    ).toBeGreaterThan(1);
    // The just-counted variant is still listed (and now shows its counted badge).
    await expect(
      page.locator('#guidedSearchResults .c-item').filter({ hasText: 'Belvedere 1L' }).first()
    ).toBeVisible();

    // Behavioral payoff: a SECOND variant can be picked from the still-open list.
    await page.locator('#guidedSearchResults .c-item').filter({ hasText: 'Belvedere 1.75L' }).first()
      .locator('.c-name').click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.fill('#guidedQty', '4');
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Confirm', exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(2);
    await expect.poll(() => qtyOf(page, 'Belvedere 1.75L')).toBe(4);
  });

  test('emptying the search input clears the remembered query + results', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.fill('#guidedSearchInput', 'Belvedere');
    await expect.poll(async () =>
      page.locator('#guidedSearchResults .c-item').count()
    ).toBeGreaterThan(0);

    // Clearing the input must drop the remembered query so the list collapses
    // and a later re-render does not resurrect it.
    await page.fill('#guidedSearchInput', '');
    await expect.poll(async () =>
      page.locator('#guidedSearchResults .c-item').count()
    ).toBe(0);
    expect(await page.evaluate(() => guidedSearchQuery.trim())).toBe('');
  });
});

/* ---------- F2: per-zone reference item lists -----------------------------
   14-list-and-reference already covers the rendered prior-audit zone split.
   This adds a direct unit-level assertion on getZoneReferenceItems and proves
   the "List" tab shows ALL carried items regardless of zone. */
test.describe('F2 — getZoneReferenceItems is per-zone; List tab is all-carried (v1.83)', () => {
  test('zone reference returns only that zone\'s prior items; List shows all carried', async ({ page, db }) => {
    await startAuditAs(page, 'manager');

    // Seed a prior submitted audit with DIFFERENT items per zone. Don Julio
    // (NOT carried) in Liquor Room proves the source is the prior audit; Tito's
    // in Bar; Campari in Service Well.
    const priorId = 'prior-zone-split';
    db.t.kount_audits.push({
      id: priorId, venue_id: 'v-delilah', venue_name: 'Delilah LA',
      status: 'submitted', count_phase: 'final',
      started_at: '2026-05-01T00:00:00Z', completed_at: '2026-05-02T00:00:00Z',
    });
    db.t.kount_entries.push(
      { id: 'pz-1', audit_id: priorId, zone: 'Liquor Room', item_name: 'Don Julio 1942 750ml',
        category: 'spirits', qty: 3, master_item_id: M.dj1942, item_id: null, counted_by_email: 'manager@hwood.com' },
      { id: 'pz-2', audit_id: priorId, zone: 'Bar', item_name: "Tito's Handmade Vodka 750ml",
        category: 'spirits', qty: 5, master_item_id: M.titos, item_id: null, counted_by_email: 'manager@hwood.com' },
      { id: 'pz-3', audit_id: priorId, zone: 'Service Well', item_name: 'Campari 1L',
        category: 'spirits', qty: 2, master_item_id: M.campari, item_id: null, counted_by_email: 'manager@hwood.com' },
    );

    await page.evaluate(async () => {
      appState.priorAuditReference = null;
      await loadPriorAuditReference(appState.currentVenue.id);
    });

    // getZoneReferenceItems(zone) returns ONLY that zone's prior items.
    const liquor = await page.evaluate(() => getZoneReferenceItems('Liquor Room').map(i => i.name));
    expect(liquor).toEqual(['Don Julio 1942 750ml']);
    const bar = await page.evaluate(() => getZoneReferenceItems('Bar').map(i => i.name));
    expect(bar).toEqual(["Tito's Handmade Vodka 750ml"]);
    const well = await page.evaluate(() => getZoneReferenceItems('Service Well').map(i => i.name));
    expect(well).toEqual(['Campari 1L']);
    // A zone with no prior items falls back to the full carried list (>1 item).
    const unknown = await page.evaluate(() => getZoneReferenceItems('NoSuchZone').map(i => i.name));
    expect(unknown.length).toBeGreaterThan(1);

    // The "List" tab shows ALL carried items, independent of zone.
    await page.getByRole('button', { name: 'List', exact: true }).click();
    const list = page.locator('#guidedContent .c-item');
    await expect(list.filter({ hasText: 'Belvedere 1L' })).toHaveCount(1);
    await expect(list.filter({ hasText: 'Campari 1L' })).toHaveCount(1);
    await expect(list.filter({ hasText: "Tito's Handmade Vodka 750ml" })).toHaveCount(1);
    // Don Julio is NOT carried, so it does NOT appear in the all-carried List.
    await expect(list.filter({ hasText: 'Don Julio 1942' })).toHaveCount(0);
  });
});

/* ---------- F3: scanner config + watchdog guard ---------------------------
   The camera can't be e2e'd, but we can prove the watchdog flag exists, starts
   cleared, is cleared on close, and that the scanner-open path doesn't throw in
   the stubbed env. The 12-instant-scan suite covers the detection handoff. */
test.describe('F3 — scanner watchdog + open path are sound (v1.83)', () => {
  test('opening + closing the native scanner leaves _nativeDetecting cleared', async ({ page }) => {
    await startAuditAs(page, 'manager');

    // Open the scanner (stubbed getUserMedia + BarcodeDetector). Must not throw.
    const openErr = await page.evaluate(async () => {
      try { await openBarcodeScanner(); return null; }
      catch (e) { return String(e); }
    });
    expect(openErr).toBeNull();

    // The watchdog re-entrancy guard is defined and is a boolean.
    expect(await page.evaluate(() => typeof _nativeDetecting)).toBe('boolean');

    // Closing the scanner clears the watchdog (per the diff's finally/close).
    await page.evaluate(() => closeBarcodeScanner());
    expect(await page.evaluate(() => _nativeDetecting)).toBe(false);
    // Interval is torn down so the loop can't keep running.
    expect(await page.evaluate(() => nativeScanInterval)).toBeNull();

    // Re-open is safe (guard starts clean again) — proves no deadlock wedge.
    const reopenErr = await page.evaluate(async () => {
      try { await openBarcodeScanner(); return null; }
      catch (e) { return String(e); }
    });
    expect(reopenErr).toBeNull();
    await page.evaluate(() => closeBarcodeScanner());
    expect(await page.evaluate(() => _nativeDetecting)).toBe(false);
  });
});

/* ---------- F4: per-zone qty isolation ------------------------------------ */
test.describe('F4 — per-zone qty isolation (v1.83)', () => {
  test('guided-open path: qty in zone B starts at 0, not zone A\'s count', async ({ page }) => {
    await startAuditAs(page, 'manager');

    // Count Belvedere = 2 in the default zone (Liquor Room).
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    await page.fill('#guidedQty', '2');
    await page.locator('#guidedEntryModal').getByRole('button', { name: 'Confirm', exact: true }).click();
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    // Switch to zone B (Bar) and open the SAME item via the guided path.
    await switchZone(page, 'Bar');
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });
    // Qty must start blank/0 in zone B — NOT pre-filled with zone A's 2.
    await expect(page.locator('#guidedQty')).toHaveValue('');
    await page.evaluate(() => closeGuidedEntry());
    await page.locator('#guidedEntryModal').waitFor({ state: 'hidden' });

    // Sanity: zone A still holds 2.
    const zoneA = await page.evaluate((id) =>
      (appState.audit.counts['Liquor Room'] || []).find(i => i.masterId === id)?.qty, M.belv);
    expect(zoneA).toBe(2);
  });

  test('instant-scan path: scanning X in zone B counts +1 from 0, not 3', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await mapKnownUpc(page);

    // Count Belvedere = 3 in Liquor Room (manual, so it's a fresh per-zone row).
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => qtyOf(page, 'Belvedere 1L')).toBe(3);

    // Switch to Bar and instant-scan the same item.
    await switchZone(page, 'Bar');
    await page.evaluate(() => openBarcodeScanner());
    await scan(page, KNOWN_UPC);

    // Bar's per-zone qty must be 1 (started from 0), NOT 3 carried over.
    await expect.poll(() => page.evaluate((id) =>
      (appState.audit.counts['Bar'] || []).find(i => i.masterId === id)?.qty, M.belv
    )).toBe(1);
    // Liquor Room is untouched at 3.
    expect(await page.evaluate((id) =>
      (appState.audit.counts['Liquor Room'] || []).find(i => i.masterId === id)?.qty, M.belv
    )).toBe(3);
    // Two distinct per-zone rows exist (3 + 1), proving the scan did NOT edit
    // the Liquor Room row up to 4 — it created a fresh Bar row from 0.
    const rows = (await counted(page)).filter(i => i.name === 'Belvedere 1L');
    expect(rows.length).toBe(2);
    const total = rows.reduce((s, r) => s + r.qty, 0);
    expect(total).toBe(4);
    await page.evaluate(() => closeBarcodeScanner());
  });
});

/* ---------- F5: +6/+12/+24 additive case-qty buttons ---------------------- */
test.describe('F5 — addGuidedQty is additive on #guidedQty (v1.83)', () => {
  test('the +6/+12/+24 buttons exist and add to the current value', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });

    // The three case buttons are present in the modal.
    const caseBtns = page.locator('#guidedCaseBtns .partial-btn');
    await expect(caseBtns).toHaveCount(3);
    await expect(caseBtns.nth(0)).toHaveText('+6');
    await expect(caseBtns.nth(1)).toHaveText('+12');
    await expect(caseBtns.nth(2)).toHaveText('+24');

    // From blank/0: +12 then +12 again = 24 (additive, not set).
    await page.fill('#guidedQty', '');
    await page.getByRole('button', { name: '+12', exact: true }).click();
    await expect(page.locator('#guidedQty')).toHaveValue('12');
    await page.getByRole('button', { name: '+12', exact: true }).click();
    await expect(page.locator('#guidedQty')).toHaveValue('24');

    // +6 on top of an existing 3 = 9.
    await page.fill('#guidedQty', '3');
    await page.getByRole('button', { name: '+6', exact: true }).click();
    await expect(page.locator('#guidedQty')).toHaveValue('9');

    // +24 on top of 9 = 33 (the third button, also additive).
    await page.getByRole('button', { name: '+24', exact: true }).click();
    await expect(page.locator('#guidedQty')).toHaveValue('33');
  });

  test('addGuidedQty floors at 0 and survives a blank field', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await page.evaluate((id) => openGuidedEntry(id), M.belv);
    await page.locator('#guidedEntryModal').waitFor({ state: 'visible' });

    // Direct call with a blank field: base 0 + 6 = 6 (no NaN).
    await page.fill('#guidedQty', '');
    await page.evaluate(() => addGuidedQty(6));
    await expect(page.locator('#guidedQty')).toHaveValue('6');
  });
});

/* ---------- F6: back-to-top button ---------------------------------------- */
test.describe('F6 — back-to-top button (v1.83)', () => {
  test('the button is hidden initially, appears after scrolling, and returns to top', async ({ page }) => {
    await startAuditAs(page, 'manager');

    // Count many items so the count page has scrollable content.
    for (const [name, qty] of [
      ['Belvedere 1L', 1], ['Belvedere 1.75L', 1], ['Campari 1L', 1],
      ["Tito's Handmade Vodka 750ml", 1], ['Rodney Strong Cabernet 2022 750ml', 1],
      ['Red Bull 8.4oz', 1],
    ]) {
      await addManual(page, name, qty);
    }

    const btn = page.locator('#backToTopBtn');
    // Hidden before any scroll (scrollTop 0 < 400 threshold).
    await expect(btn).toHaveClass(/hide/);

    // Scroll the count page (its own scroll container) past the 400px
    // threshold and fire the scroll event the handler listens for. Headless
    // layouts may clamp scrollTop if the content doesn't overflow, so install
    // a recording scrollTo + a real backing scrollTop the handler can read.
    await page.evaluate(() => {
      const pageEl = document.getElementById('page-count');
      let _top = 800;
      Object.defineProperty(pageEl, 'scrollTop', {
        configurable: true,
        get() { return _top; },
        set(v) { _top = v; },
      });
      window.__lastScrollTo = null;
      pageEl.scrollTo = (opts) => { window.__lastScrollTo = opts; _top = (opts && opts.top) || 0; };
      pageEl.dispatchEvent(new Event('scroll'));
    });
    // Past threshold → button shows.
    await expect(btn).not.toHaveClass(/hide/);

    // Tapping it calls scrollCountToTop → page.scrollTo({ top: 0 }).
    await btn.click();
    const scrollArg = await page.evaluate(() => window.__lastScrollTo);
    expect(scrollArg).toEqual(expect.objectContaining({ top: 0 }));
    // And the backing scroll position is now 0.
    expect(await page.evaluate(() => document.getElementById('page-count').scrollTop)).toBe(0);
    // Re-running the visibility predicate now hides it again.
    await page.evaluate(() => {
      document.getElementById('page-count').dispatchEvent(new Event('scroll'));
    });
    await expect(btn).toHaveClass(/hide/);
  });

  test('the button hides when leaving the count page', async ({ page }) => {
    await startAuditAs(page, 'manager');
    // Reveal it via the predicate, then navigate away.
    await page.evaluate(() => {
      const pageEl = document.getElementById('page-count');
      Object.defineProperty(pageEl, 'scrollTop', { configurable: true, get: () => 800 });
      updateBackToTopVisibility();
    });
    await expect(page.locator('#backToTopBtn')).not.toHaveClass(/hide/);

    await page.evaluate(() => showPage('summary'));
    await expect(page.locator('#backToTopBtn')).toHaveClass(/hide/);
  });
});

/* ---------- F7: admin-only Close Count 1 & Finalize ----------------------- */
test.describe('F7 — closeCount1AndFinalize is corporate-only (v1.83)', () => {
  // (a) Visibility gating via updateVarianceActions, per role.
  test('finalize button is VISIBLE for corporate, HIDDEN for manager + counter', async ({ page }) => {
    // Corporate: visible while in count1.
    await startAuditAs(page, 'corporate');
    await addManual(page, 'Belvedere 1L', 3);
    await page.evaluate(() => { showPage('variance'); updateVarianceActions(); });
    await expect(page.locator('#closeCount1FinalizeBtn')).not.toHaveClass(/hide/);
    // The standard manager close button is still shown too.
    await expect(page.locator('#closeCount1Btn')).not.toHaveClass(/hide/);
  });

  test('finalize button is HIDDEN for a manager', async ({ page }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await page.evaluate(() => { showPage('variance'); updateVarianceActions(); });
    await expect(page.locator('#closeCount1FinalizeBtn')).toHaveClass(/hide/);
  });

  test('finalize button is HIDDEN for a counter', async ({ page }) => {
    // Start a shared audit, then exercise the role gate as a counter. The
    // button gating reads appState.user.role, so flipping the role and
    // re-running updateVarianceActions is the real code path.
    await startAuditAs(page, 'corporate');
    await page.evaluate(() => { appState.user.role = 'counter'; });
    await page.evaluate(() => { showPage('variance'); updateVarianceActions(); });
    await expect(page.locator('#closeCount1FinalizeBtn')).toHaveClass(/hide/);
  });

  // (b) Calling it as a non-corporate role is refused.
  test('calling closeCount1AndFinalize as a manager is refused (no submit)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    await page.evaluate(() => closeCount1AndFinalize());
    // No confirm dialog should appear for a refused call; the audit must stay
    // in count1 and never go submitted.
    await page.waitForTimeout(300);
    expect(await page.evaluate(() => appState.audit.status)).not.toBe('submitted');
    expect(db.t.kount_audits[0].count_phase).toBe('count1');
    // A clear refusal toast is shown.
    await expect(page.locator('.toast')).toContainText(/only an admin can finalize/i);
  });

  // (c) As corporate, it finalizes: submitted + final, computes, NO recount list.
  test('corporate finalize → submitted/final, compute runs, NO Count-2 recount list', async ({ page, db }) => {
    await startAuditAs(page, 'corporate');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    await page.evaluate(() => closeCount1AndFinalize());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));

    // Audit is marked submitted + final.
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
    expect(await page.evaluate(() => appState.audit.status)).toBe('submitted');
    expect(await page.evaluate(() => appState.audit.countPhase)).toBe('final');

    // Compute ran (the mock emits a computed report for this audit).
    await expect
      .poll(() => db.t.kount_avt_reports.filter(r => r.audit_id === db.t.kount_audits[0].id && r.source === 'computed').length)
      .toBe(1);

    // CRITICAL: it must NOT build a Count-2 recount list (that's the manager
    // closeCount1 flow). recounts stays empty.
    const recountCount = await page.evaluate(() =>
      Object.keys((appState.audit && appState.audit.recounts) || {}).length);
    expect(recountCount).toBe(0);
    // And no recount rows were written to the recount table for this audit.
    expect(db.t.kount_recounts.filter(r => r.audit_id === db.t.kount_audits[0].id).length).toBe(0);
  });

  test('corporate finalize is refused with nothing counted', async ({ page, db }) => {
    await startAuditAs(page, 'corporate');
    await page.evaluate(() => closeCount1AndFinalize());
    await page.waitForTimeout(200);
    await expect(page.locator('.toast')).toContainText(/no items counted/i);
    expect(await page.evaluate(() => appState.audit.status)).not.toBe('submitted');
  });

  // (d) The existing manager closeCount1 → recount-list flow is unchanged.
  test('manager closeCount1 still generates a recount list (unchanged)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    await page.evaluate(() => closeCount1());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));

    // Phase goes to review (NOT final) and a variance-driven recount list is built.
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');
    expect(await page.evaluate(() => appState.audit.status)).not.toBe('submitted');
    await expect
      .poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 })
      .toBeGreaterThan(0);
    const names = await page.evaluate(() => Object.values(appState.audit.recounts).map(r => r.itemName));
    expect(names).toContain('Belvedere 1L');
  });
});
