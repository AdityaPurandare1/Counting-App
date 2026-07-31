/* v1.98 BUG 3 — mergeRemoteEntryIntoLocal phantom-duplicate-card fix
   (counting-app.html ~6722).

   A repeat-count DELTA (addCountEntry duplicate path) syncs with a FRESH
   clientEntryId that is never stamped on the local running-total entry. If that
   delta's insert wins the race and creates the server row, its realtime INSERT
   echo matches neither supabaseId nor client_entry_id → the old code unshifted
   a PHANTOM duplicate card that even the reconcile poll couldn't collapse (both
   cards ended up carrying the same supabaseId).

   The fix: an otherwise-unmatched INSERT echo that lines up with an existing
   local entry on (masterId OR lower(name)) + is_recount MUST be that same
   logical item (server merge index + addCountEntry both guarantee one row/entry
   per key), so ADOPT it instead of duplicating.

   Unit-style: we drive mergeRemoteEntryIntoLocal directly with a hand-built
   appState.audit. FAIL-BEFORE: without the adopt branch the echo is unshifted →
   TWO cards for one item.

   Belvedere 1L master uuid from the seed fixture. */
const { test, expect } = require('../fixtures');

const BELV = '11111111-1111-4111-8111-111111111111';
const CAMPARI = '33333333-3333-4333-8333-333333333333';

test.describe('v1.98 realtime echo adopts existing local card', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/counting-app.html', { waitUntil: 'domcontentloaded' });
    await expect.poll(() => page.evaluate(() => typeof window.mergeRemoteEntryIntoLocal)).toBe('function');
  });

  test('unmatched INSERT echo matching (masterId + is_recount) adopts, not duplicates', async ({ page }) => {
    const result = await page.evaluate(({ BELV }) => {
      appState.audit = {
        supabaseId: 'AUD1',
        counts: { Bar: [
          // Local running-total entry — no supabaseId yet, its own clientEntryId.
          { id: 'E_local', clientEntryId: 'E_local', name: 'Belvedere 1L',
            masterId: BELV, qty: 2, isRecount: false, issue: 'none' },
        ] },
      };
      // Server echo of a repeat-count delta: brand-new id + a fresh
      // client_entry_id that was never stored on the local entry.
      const row = {
        id: 'SRV_belv', audit_id: 'AUD1', zone: 'Bar', item_name: 'Belvedere 1L',
        master_item_id: BELV, qty: 5, is_recount: false, issue: 'none',
        issue_notes: null, timestamp: '2026-07-30T00:00:00Z',
        client_entry_id: 'E_freshDelta',
      };
      window.mergeRemoteEntryIntoLocal(row, 'INSERT');
      const zone = appState.audit.counts.Bar;
      return { len: zone.length, supId: zone[0] && zone[0].supabaseId, qty: zone[0] && zone[0].qty };
    }, { BELV });

    expect(result.len).toBe(1);            // exactly ONE card, not two
    expect(result.supId).toBe('SRV_belv'); // the local card adopted the server row
    expect(result.qty).toBe(5);            // authoritative server qty
  });

  test('unmatched echo for a master-less item adopts on lower(name) + is_recount', async ({ page }) => {
    const result = await page.evaluate(() => {
      appState.audit = {
        supabaseId: 'AUD1',
        counts: { Bar: [
          { id: 'E_custom', clientEntryId: 'E_custom', name: 'House Bitters',
            masterId: null, qty: 1, isRecount: false, issue: 'none' },
        ] },
      };
      const row = {
        id: 'SRV_bitters', audit_id: 'AUD1', zone: 'Bar', item_name: 'house bitters',
        master_item_id: null, item_id: null, qty: 3, is_recount: false, issue: 'none',
        issue_notes: null, timestamp: '2026-07-30T00:00:00Z', client_entry_id: 'E_freshDelta2',
      };
      window.mergeRemoteEntryIntoLocal(row, 'INSERT');
      const zone = appState.audit.counts.Bar;
      return { len: zone.length, supId: zone[0] && zone[0].supabaseId };
    });
    expect(result.len).toBe(1);
    expect(result.supId).toBe('SRV_bitters');
  });

  test('does NOT over-adopt: a different master stays a separate card', async ({ page }) => {
    const len = await page.evaluate(({ BELV, CAMPARI }) => {
      appState.audit = {
        supabaseId: 'AUD1',
        counts: { Bar: [
          { id: 'E_local', clientEntryId: 'E_local', name: 'Belvedere 1L',
            masterId: BELV, qty: 2, isRecount: false, issue: 'none' },
        ] },
      };
      // A genuinely different item (Campari) — must become its own card.
      const row = {
        id: 'SRV_campari', audit_id: 'AUD1', zone: 'Bar', item_name: 'Campari 1L',
        master_item_id: CAMPARI, qty: 4, is_recount: false, issue: 'none',
        issue_notes: null, timestamp: '2026-07-30T00:00:00Z', client_entry_id: 'E_x',
      };
      window.mergeRemoteEntryIntoLocal(row, 'INSERT');
      return appState.audit.counts.Bar.length;
    }, { BELV, CAMPARI });
    expect(len).toBe(2);
  });

  test('is_recount mismatch does not adopt (recount echo stays separate from count-1)', async ({ page }) => {
    const out = await page.evaluate(({ BELV }) => {
      appState.audit = {
        supabaseId: 'AUD1',
        counts: { Bar: [
          { id: 'E_local', clientEntryId: 'E_local', name: 'Belvedere 1L',
            masterId: BELV, qty: 2, isRecount: false, issue: 'none' },
        ] },
      };
      // Same item + master, but this is a RECOUNT row — a distinct logical entry.
      const row = {
        id: 'SRV_belv_recount', audit_id: 'AUD1', zone: 'Bar', item_name: 'Belvedere 1L',
        master_item_id: BELV, qty: 6, is_recount: true, issue: 'none',
        issue_notes: null, timestamp: '2026-07-30T00:00:00Z', client_entry_id: 'E_rc',
      };
      window.mergeRemoteEntryIntoLocal(row, 'INSERT');
      const zone = appState.audit.counts.Bar;
      return { len: zone.length, orig: zone.find((e) => e.id === 'E_local').supabaseId };
    }, { BELV });
    expect(out.len).toBe(2);            // two cards: count-1 entry + recount entry
    expect(out.orig).toBeUndefined();  // the original count-1 card was left untouched
  });
});
