/* v2.10 — the two remaining hursh-dev data-integrity fixes (branch commit 19a0600).

   1) variance% NULL preservation (_mapAvtRow).
      compute_avt_for_audit emits `case when fr.theo = 0 then null else ... end`
      because a percentage variance is undefined with no theoretical baseline.
      theo is 0 for EVERY row of a first count (no prior audit → start,
      purchases and depletions are all 0), so this is the common case, not an
      edge case. `Number(r.variance_pct || 0)` turned that NULL into 0 and the
      CSV reported a confident "0.0%" for rows that have no basis for a
      percentage at all.

      NOTE the mock DB does NOT reproduce this: mockdb.js computes
      `theo ? (variance/theo)*100 : 0`, i.e. it sends 0 where the real server
      sends NULL. So these assertions drive _mapAvtRow directly with the real
      server's shape rather than going through the mock.

   2) detectCategory delegation.
      It kept a second, independently-drifted keyword list that had lost
      aperol/campari/vermouth/liqueur/mezcal/brandy/whisky, so the SAME bottle
      categorised differently depending on whether it arrived via barcode
      lookup (detectCategory) or photo OCR (detectCategoryFromText).

   Both are pure functions — called directly via page.evaluate.

   FAIL-BEFORE: (1) variancePct came back 0 for null/undefined and the CSV cell
   rendered "0.0%"; (2) detectCategory('Aperol') returned 'other'. */
const { test, expect } = require('../fixtures');

test.describe('v2.10 AVT null-% + single category list', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window._mapAvtRow)).toBe('function');
  });

  test('a NULL variance_pct survives as null, while a genuine 0 stays 0', async ({ page }) => {
    const r = await page.evaluate(() => {
      const f = window._mapAvtRow;
      const base = { item_name: 'Probe', venue_id: 'v1' };
      return {
        nullPct:  f({ ...base, variance_pct: null }).variancePct,
        undefPct: f({ ...base }).variancePct,
        zeroPct:  f({ ...base, variance_pct: 0 }).variancePct,
        realPct:  f({ ...base, variance_pct: -20 }).variancePct,
        strPct:   f({ ...base, variance_pct: '12.5' }).variancePct,
      };
    });
    // The whole point: null and 0 must stay distinguishable.
    expect(r.nullPct).toBeNull();
    expect(r.undefPct).toBeNull();
    expect(r.zeroPct).toBe(0);
    expect(r.realPct).toBe(-20);
    expect(r.strPct).toBe(12.5);
  });

  test('other AVT numerics still coerce to 0 (the null rule is scoped to variance_pct)', async ({ page }) => {
    const r = await page.evaluate(() => window._mapAvtRow({ item_name: 'Probe' }));
    expect(r.actual).toBe(0);
    expect(r.theo).toBe(0);
    expect(r.variance).toBe(0);
    expect(r.varianceValue).toBe(0);
    expect(r.cuPrice).toBe(0);
  });

  test('severity is unchanged by a null variancePct (no crash, same verdict as 0)', async ({ page }) => {
    const r = await page.evaluate(() => {
      const item = { varianceValue: -600, variance: -9, category: 'Liquor Cost', weeksActive: 0 };
      return {
        withNull: window.scoreSeverity({ ...item, variancePct: null }),
        withZero: window.scoreSeverity({ ...item, variancePct: 0 }),
        // The only pct band is `absPct >= 25`; a real percentage still reaches it.
        smallDollarsBigPct: window.scoreSeverity({
          varianceValue: -1, variance: -1, category: 'Liquor Cost', weeksActive: 0, variancePct: -80,
        }),
        smallDollarsNullPct: window.scoreSeverity({
          varianceValue: -1, variance: -1, category: 'Liquor Cost', weeksActive: 0, variancePct: null,
        }),
      };
    });
    expect(r.withNull).toBe(r.withZero);
    expect(r.smallDollarsBigPct).toBe('MEDIUM');
    // A null can never satisfy `absPct >= 25`, so it must NOT be promoted.
    expect(r.smallDollarsNullPct).not.toBe('MEDIUM');
  });

  test('the CSV Variance % cell says n/a for a null, not a confident 0.0%', async ({ page }) => {
    // Mirror the exact expression exportCountCSV uses for that column.
    const cell = await page.evaluate(() => {
      const render = (avt) => (avt.variancePct == null ? 'n/a' : Number(avt.variancePct).toFixed(1) + '%');
      return {
        nul:  render({ variancePct: null }),
        zero: render({ variancePct: 0 }),
        real: render({ variancePct: -12.34 }),
      };
    });
    expect(cell.nul).toBe('n/a');
    expect(cell.zero).toBe('0.0%');
    expect(cell.real).toBe('-12.3%');
    // And the shipped source really does use that expression (not `|| 0`).
    const src = await page.evaluate(() => window.exportCountCSV.toString());
    expect(src).toContain("'n/a'");
    expect(src).not.toContain('(avt.variancePct || 0)');
  });

  test('detectCategory agrees with detectCategoryFromText on the words it used to miss', async ({ page }) => {
    const r = await page.evaluate(() => {
      const missed = ['Aperol', 'Campari', 'Sweet Vermouth', 'Elderflower Liqueur',
                      'Del Maguey Mezcal', 'St-Remy Brandy', 'Japanese Whisky'];
      const out = {};
      missed.forEach((n) => { out[n] = window.detectCategory(n, ''); });
      return {
        out,
        // The two paths must now agree for every one of them.
        agree: missed.every((n) => window.detectCategory(n, '') === window.detectCategoryFromText(n)),
        // Regression guard: the categories it always got right still work.
        wine: window.detectCategory('Caymus Cabernet', ''),
        beer: window.detectCategory('Modelo Especial', ''),
        other: window.detectCategory('Cocktail Napkins', ''),
        // description is still considered, and joins without fusing words.
        viaDescription: window.detectCategory('Bottle 750ml', 'A smoky mezcal'),
      };
    });
    Object.entries(r.out).forEach(([name, cat]) => {
      expect(cat, name + ' should classify as spirits').toBe('spirits');
    });
    expect(r.agree).toBe(true);
    expect(r.wine).toBe('wine');
    expect(r.beer).toBe('beer');
    expect(r.other).toBe('other');
    expect(r.viaDescription).toBe('spirits');
  });
});
