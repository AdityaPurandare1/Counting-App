const { test, expect, startAuditAs, addManual } = require('../fixtures');

test.describe('Count 1 → Count 2 lifecycle', () => {
  test('manager closes Count 1 (→ review) then closes Count 2 (→ submitted)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    // Close Count 1 → confirm.
    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // v1.70: closing Count 1 on a networked audit COMPUTES variance (the mock
    // compute_avt_for_audit stub emits a HIGH-variance Belvedere row), so the
    // recount list is variance-driven, not all-items. The Belvedere row is
    // present; the zero-variance Tito's row is NOT flagged.
    await expect.poll(() => db.t.kount_avt_reports.filter(r => r.audit_id === db.t.kount_audits[0].id && r.source === 'computed').length).toBe(1);
    await expect.poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 }).toBeGreaterThan(0);
    const recountNames = await page.evaluate(() =>
      Object.values(appState.audit.recounts).map((r) => r.itemName));
    expect(recountNames).toContain('Belvedere 1L');
    expect(recountNames).not.toContain("Tito's Handmade Vodka 750ml");

    // v1.62: the strict close gate is RESTORED — every recount row needs a
    // manager decision + reason + numeric recountQty before Count 2 can
    // close (the 2026-05-27 relaxed bypass is gone). Complete the rows the
    // way the recount modal would, then close. Audit finalizes as submitted.
    await page.evaluate(() => {
      Object.values(appState.audit.recounts).forEach((r) => {
        r.auditResult = 'verified';
        r.auditReason = 'robot QA: count verified against shelf';
        r.recountQty = r.count1Qty != null ? r.count1Qty : 0;
        r.status = 'done';
      });
    });
    await page.evaluate(() => window.closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
    // v1.62: finalize also mirrors count2_closed_at to the audit row.
    await expect.poll(() => db.t.kount_audits[0].count2_closed_at).toBeTruthy();
  });

  // v1.75: recount targeting on the Variance tab is gated to the RECOUNT
  // STAGE (count_phase 'review' / 'count2'). During Count 1 the tab shows
  // variance as a preview but must NOT present any item "for recount" — no
  // per-row RECOUNT badge, no "Flagged for recount" stat, and the Flagged
  // filter chip is hidden. Once Count 1 closes the framing returns.
  test('Variance tab hides recount framing during Count 1, shows it at recount stage', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 1);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    // Seed a high-variance AVT row for the current venue so the Variance tab
    // has something to render in BOTH phases. A -$500 variance scores HIGH →
    // needsRecount() would be true if the stage allowed it.
    await page.evaluate(() => {
      const vid = appState.currentVenue.id;
      appState.avtData = [{
        store: 'Delilah LA', venueId: vid, venueName: 'Delilah LA',
        itemName: 'Belvedere 1L', category: 'Liquor Cost',
        actual: 1, theo: 10, variance: -9, varianceValue: -500, variancePct: -90,
        cuPrice: 50, start: 10, purchases: 0, depletions: 9,
      }];
    });

    // --- Count 1: variance preview WITHOUT recount framing ---
    await page.locator('.nav-item[data-page="variance"]').click();
    await page.locator('#page-variance').waitFor({ state: 'visible' });
    await page.evaluate(() => window.renderVariancePage());

    // Variance row IS shown (tab is useful as a preview).
    await expect(page.locator('#varianceList')).toContainText('Belvedere 1L');
    // But no recount framing: no RECOUNT badge, no "Flagged for recount" stat,
    // and the Flagged filter chip is hidden.
    await expect(page.locator('#varianceList')).not.toContainText('RECOUNT');
    await expect(page.locator('#varianceStats')).not.toContainText('Flagged for recount');
    await expect(page.locator('.mode-toggle [data-vf="flagged"]')).toBeHidden();
    // Other useful stats remain.
    await expect(page.locator('#varianceStats')).toContainText('AVT items');
    await expect(page.locator('#varianceStats')).toContainText('Total variance value');

    // Even if state is forced onto the 'flagged' filter, leaving the recount
    // stage falls back to 'all' rather than rendering an empty unexplained list.
    await page.evaluate(() => { appState.varianceFilter = 'flagged'; window.renderVariancePage(); });
    await expect.poll(() => page.evaluate(() => appState.varianceFilter)).toBe('all');
    await expect(page.locator('#varianceList')).toContainText('Belvedere 1L');

    // --- Close Count 1 → recount stage (review) ---
    // The Close Count 1 bar lives on the count page; return there to click it.
    await page.evaluate(() => window.showPage('count'));
    await page.locator('#activeAuditContent').waitFor({ state: 'visible' });
    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // Navigate to the Variance tab via the real nav, then re-seed avtData
    // (closeCount1 reloads the computed report) and re-render so the
    // assertions reflect the recount-stage UI on a visible page.
    await page.locator('.nav-item[data-page="variance"]').click();
    await page.locator('#page-variance').waitFor({ state: 'visible' });
    await page.evaluate(() => {
      const vid = appState.currentVenue.id;
      appState.avtData = [{
        store: 'Delilah LA', venueId: vid, venueName: 'Delilah LA',
        itemName: 'Belvedere 1L', category: 'Liquor Cost',
        actual: 1, theo: 10, variance: -9, varianceValue: -500, variancePct: -90,
        cuPrice: 50, start: 10, purchases: 0, depletions: 9,
      }];
      window.renderVariancePage();
    });

    // Now the recount framing returns: RECOUNT badge, the stat, and the chip.
    await expect(page.locator('#varianceList')).toContainText('RECOUNT');
    await expect(page.locator('#varianceStats')).toContainText('Flagged for recount');
    await expect(page.locator('.mode-toggle [data-vf="flagged"]')).toBeVisible();
  });
});
