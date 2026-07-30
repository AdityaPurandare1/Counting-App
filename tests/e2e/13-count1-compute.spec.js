/* v1.70: Count 1 close now COMPUTES variance (computed AVT is the product;
   Craftable pre-loads are gone). Migration 0038 makes compute_avt_for_audit
   work at count-1 close too. These specs cover:
     - networked Count 1 close → compute runs → variance-driven recount list
     - compute returns zero variance → empty recount list, finalize still works
   The mock's compute_avt_for_audit stub (mockdb.computeAvtForAudit) emits a
   HIGH-variance Belvedere row by default; the zero-variance case monkeypatches
   it on the shared db instance before the close. */
const { test, expect, startAuditAs, addManual } = require('../fixtures');

test.describe('v1.70 Count 1 compute', () => {
  test('closing Count 1 on a networked audit computes variance and drives the recount list', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('count1');

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // compute_avt_for_audit produced exactly one computed report for THIS audit.
    await expect
      .poll(() => db.t.kount_avt_reports.filter((r) => r.audit_id === db.t.kount_audits[0].id && r.source === 'computed').length)
      .toBe(1);

    // The recount list is variance-driven: Belvedere (high variance) is flagged,
    // Tito's (zero variance) is not.
    await expect
      .poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 })
      .toBeGreaterThan(0);
    const names = await page.evaluate(() => Object.values(appState.audit.recounts).map((r) => r.itemName));
    expect(names).toContain('Belvedere 1L');
    expect(names).not.toContain("Tito's Handmade Vodka 750ml");

    // appState.avtData reflects the freshly computed report.
    const avtLen = await page.evaluate(() => (appState.avtData || []).length);
    expect(avtLen).toBeGreaterThan(0);
  });

  test('zero-variance compute → empty recount list, but finalize is still reachable', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);

    // Make compute emit a report with NO significant variance for this run.
    const rid = () => 'rrrrrrrr-rrrr-4rrr-8rrr-' + Date.now().toString(16).padStart(12, '0').slice(-12);
    db.computeAvtForAudit = function (args) {
      const uuid = rid;
      const auditId = args.p_audit_id;
      const audit = this.t.kount_audits.find((a) => a.id === auditId);
      const venueId = audit ? audit.venue_id : null;
      const reportId = uuid();
      const now = new Date().toISOString();
      if (!this.t.kount_avt_reports) this.t.kount_avt_reports = [];
      if (!this.t.kount_avt_rows) this.t.kount_avt_rows = [];
      this.t.kount_avt_reports.push({
        id: reportId, audit_id: auditId, venue_ids: [venueId],
        source: 'computed', uploaded_at: now, computed_at: now,
      });
      // A perfectly-matched row: zero variance → never flagged for recount.
      this.t.kount_avt_rows.push({
        id: uuid(), report_id: reportId, venue_id: venueId, venue_name: '',
        store: '', item_name: 'Belvedere 1L', category: 'Liquor Cost',
        actual: 3, theo: 3, variance: 0, variance_value: 0, variance_pct: 0,
        cu_price: 30, start_qty: 0, purchases: 0, depletions: 0,
      });
      return { status: 200, body: reportId };
    };

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    // Computed cleanly with no significant variance → empty recount list and a
    // reassuring toast (not a confusing blank page).
    await expect(page.locator('.toast')).toContainText(/no significant variance/i);
    const count = await page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length);
    expect(count).toBe(0);

    // Finalize is still reachable with zero recount rows: closeCount2's gates
    // short-circuit on an empty entries list, so the confirm appears and the
    // audit submits.
    await page.evaluate(() => window.closeCount2());
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].status).toBe('submitted');
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('final');
  });

  /* v1.98 MATERIALITY FILTER (generateRecountFromAvt).
     A recountable item is flagged only when severity is CRITICAL/HIGH, OR it is
     needsRecount()-eligible AND material by dollars (|$|>=250) OR bottles
     (|bottles|>=3) OR percentage (|pct|>=25). The pct arm catches
     cheap-but-very-off items (theft/spill) that slip under the $/bottle floors.
     This trims the long tail of tiny MEDIUM variances.

     We monkeypatch compute to emit deterministic rows exercising every branch
     (weeksActive is 0 in tests, so severity is driven purely by the variance
     math against SEVERITY_THRESHOLDS: liquor $50 base / $150 HIGH, wine $200
     base). variance_pct is set as (variance/theo)*100 so avt.variancePct
     (via _mapAvtRow: Number(r.variance_pct)) is the exact % the gate reads:
       - Don Julio (liquor, 0/2 @ $100 = -$200, -100%): absVar 200 >= 150 -> HIGH.
         KEPT unconditionally even though it is IMMATERIAL by the $/bottle
         thresholds ($200<250 and 2 bottles<3) -> proves HIGH bypasses the gate.
       - Campari (liquor, 8/10 @ $40 = -$80, -20%): MEDIUM (|$|>=50), under ALL
         THREE material arms ($80<250, 2<3, 20%<25) -> DROPPED. This is the
         control that proves the pct arm is a real filter, not always-on.
       - Aperol (liquor, 0.2/1.0 @ $30 = -$24, -80%): cheap-but-very-off.
         MEDIUM only because |pct|>=25 (absVar $24<$50 would otherwise be WATCH).
         Under the $ floor ($24<250) AND bottle floor (0.8<3) -> KEPT SOLELY by
         the pct arm. This is the new v1.98 case.
       - Tito's (liquor, 2/5 @ $10 = -$30, -60%): MEDIUM (3 bottles), material at
         the EXACT bottle boundary (|bottles|>=3) -> KEPT.
       - Rodney Strong Cab (wine, 4/5 @ $250 = -$250, -20%): MEDIUM (wine,
         |$|>=200, not HIGH until $500/$600), material at the EXACT dollar
         boundary (|$|>=250) -> KEPT. Its pct is only 20% (<25), so it proves the
         dollar arm still stands on its own without help from the pct arm. */
  test('materiality filter (top-offenders): HIGH kept, only $-material mid-tier kept, bottle/pct-only dropped', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    // Non-empty audit so closeCount1 proceeds. This counted item is irrelevant
    // to the recount list (generateRecountFromAvt reads avtData, not counts).
    await addManual(page, 'Belvedere 1L', 3);

    // Deterministic AVT: one HIGH, one immaterial MEDIUM, and two boundary MEDIUMs.
    db.computeAvtForAudit = function (args) {
      const rid = () => 'mmmmmmmm-mmmm-4mmm-8mmm-' + Date.now().toString(16).padStart(12, '0').slice(-12);
      const auditId = args.p_audit_id;
      const audit = this.t.kount_audits.find((a) => a.id === auditId);
      const venueId = audit ? audit.venue_id : null;
      const venue = this.t.kount_venues.find((v) => v.id === venueId);
      const venueName = venue ? venue.name : '';
      const reportId = rid();
      const now = new Date().toISOString();
      if (!this.t.kount_avt_reports) this.t.kount_avt_reports = [];
      if (!this.t.kount_avt_rows) this.t.kount_avt_rows = [];
      // Drop any prior computed report for this audit (mirror the real upsert).
      const self = this;
      this.t.kount_avt_reports = this.t.kount_avt_reports.filter((r) => {
        if (r.audit_id === auditId && r.source === 'computed') {
          self.t.kount_avt_rows = self.t.kount_avt_rows.filter((row) => row.report_id !== r.id);
          return false;
        }
        return true;
      });
      this.t.kount_avt_reports.push({
        id: reportId, audit_id: auditId, venue_ids: [venueId],
        source: 'computed', uploaded_at: now, computed_at: now,
      });
      const mkRow = (name, category, actual, theo, cuPrice) => {
        const variance = actual - theo;
        return {
          id: rid() + Math.random().toString(16).slice(2, 6), report_id: reportId,
          venue_id: venueId, venue_name: venueName, store: venueName,
          item_name: name, category: category, actual: actual, theo: theo,
          variance: variance, variance_value: variance * cuPrice,
          variance_pct: theo ? (variance / theo) * 100 : 0, cu_price: cuPrice,
          start_qty: 0, purchases: 0, depletions: 0,
        };
      };
      this.t.kount_avt_rows.push(mkRow('Don Julio 1942 750ml', 'Liquor Cost', 0, 2, 100)); // HIGH -> KEEP
      this.t.kount_avt_rows.push(mkRow('Campari 1L', 'Liquor Cost', 8, 10, 40));           // MEDIUM under ALL three arms ($80,-2bt,-20%) -> DROP
      this.t.kount_avt_rows.push(mkRow('Aperol 750ml', 'Liquor Cost', 0.2, 1.0, 30));      // cheap-but-very-off: -$24,-0.8bt,-80% -> DROP (pct arm retired)
      this.t.kount_avt_rows.push(mkRow("Tito's Handmade Vodka 750ml", 'Liquor Cost', 2, 5, 10)); // 3-bottle boundary, only -$30 -> DROP (bottle arm retired)
      this.t.kount_avt_rows.push(mkRow('Rodney Strong Cabernet 2022 750ml', 'Wine Cost', 4, 5, 250)); // $250 boundary, pct only -20% -> KEEP
      return { status: 200, body: reportId };
    };

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    await expect
      .poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 })
      .toBeGreaterThan(0);

    const names = await page.evaluate(() =>
      Array.from(new Set(Object.values(appState.audit.recounts).map((r) => r.itemName))));

    // HIGH is kept even though it is immaterial by dollars.
    expect(names).toContain('Don Julio 1942 750ml');
    // MEDIUM under the $ floor ($80<250) is trimmed.
    expect(names).not.toContain('Campari 1L');
    // TOP-OFFENDERS rule: the pct arm is retired, so a cheap-but-very-off item
    // (-$24) under the $250 floor is now DROPPED.
    expect(names).not.toContain('Aperol 750ml');
    // The bottle arm is retired, so a 3-bottle / -$30 item is now DROPPED.
    expect(names).not.toContain("Tito's Handmade Vodka 750ml");
    // Exact dollar boundary ($250) -> kept by the dollar arm.
    expect(names).toContain('Rodney Strong Cabernet 2022 750ml');
  });

  test('recount list is capped at maxRecountItems (top offenders by |$ variance|)', async ({ page, db }) => {
    await startAuditAs(page, 'manager');
    await addManual(page, 'Belvedere 1L', 3);

    // 50 material MEDIUM wine rows ($300..$349 each). All clear the $250 floor
    // and are MEDIUM (wine: >=200 and <500), so all are eligible — but the cap
    // must trim them to the top 40 by |$|, dropping the 10 smallest.
    db.computeAvtForAudit = function (args) {
      const rid = () => 'cccccccc-cccc-4ccc-8ccc-' + Date.now().toString(16).padStart(12, '0').slice(-12) + Math.random().toString(16).slice(2, 6);
      const auditId = args.p_audit_id;
      const audit = this.t.kount_audits.find((a) => a.id === auditId);
      const venueId = audit ? audit.venue_id : null;
      const venue = this.t.kount_venues.find((v) => v.id === venueId);
      const venueName = venue ? venue.name : '';
      const reportId = rid();
      const now = new Date().toISOString();
      if (!this.t.kount_avt_reports) this.t.kount_avt_reports = [];
      if (!this.t.kount_avt_rows) this.t.kount_avt_rows = [];
      const self = this;
      this.t.kount_avt_reports = this.t.kount_avt_reports.filter((r) => {
        if (r.audit_id === auditId && r.source === 'computed') {
          self.t.kount_avt_rows = self.t.kount_avt_rows.filter((row) => row.report_id !== r.id);
          return false;
        }
        return true;
      });
      this.t.kount_avt_reports.push({ id: reportId, audit_id: auditId, venue_ids: [venueId], source: 'computed', uploaded_at: now, computed_at: now });
      for (let i = 0; i < 50; i++) {
        const cu = 300 + i; // |$ var| = cu (variance -1 * cu)
        this.t.kount_avt_rows.push({
          id: rid(), report_id: reportId, venue_id: venueId, venue_name: venueName, store: venueName,
          item_name: 'Test Wine ' + String(i).padStart(2, '0') + ' 750ml', category: 'Wine Cost',
          actual: 4, theo: 5, variance: -1, variance_value: -cu, variance_pct: -20, cu_price: cu,
          start_qty: 0, purchases: 0, depletions: 0,
        });
      }
      return { status: 200, body: reportId };
    };

    await page.locator('#closeCount1Bar').getByRole('button', { name: /Close Count 1/i }).click();
    await page.locator('#confirmDialog').waitFor({ state: 'visible' });
    await page.evaluate(() => window.closeConfirm(true));
    await expect.poll(() => db.t.kount_audits[0].count_phase).toBe('review');

    await expect
      .poll(() => page.evaluate(() => Object.keys((appState.audit && appState.audit.recounts) || {}).length), { timeout: 5000 })
      .toBeGreaterThan(0);
    const names = await page.evaluate(() =>
      Array.from(new Set(Object.values(appState.audit.recounts).map((r) => r.itemName))));

    // Capped to 40 (maxRecountItems), not all 50.
    expect(names.length).toBe(40);
    // The largest-$ item ($349) is kept; the smallest ($300) is trimmed.
    expect(names).toContain('Test Wine 49 750ml');
    expect(names).not.toContain('Test Wine 00 750ml');
  });
});
