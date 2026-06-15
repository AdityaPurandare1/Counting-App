/* Seed data for the in-memory Supabase mock. UUID-format ids are deliberate:
   the catalog maps master_items.id → itemMaster.sku, and the app hides
   UUID-shaped skus (visibleSku), so UUID ids let us assert that hiding. */

const M = {
  belv:    '11111111-1111-4111-8111-111111111111', // Belvedere 1L (carried)
  belv175: '77777777-7777-4777-8777-777777777777', // Belvedere 1.75L (carried) — size sibling for Fix B tests
  dj1942:  '22222222-2222-4222-8222-222222222222', // Don Julio 1942 750ml (NOT carried)
  campari: '33333333-3333-4333-8333-333333333333', // Campari 1L (carried)
  titos:   '44444444-4444-4444-8444-444444444444', // Tito's 750ml (carried)
  cab:     '55555555-5555-4555-8555-555555555555', // Rodney Strong Cab (carried)
  redbull: '66666666-6666-4666-8666-666666666666', // Red Bull 8.4oz (carried)
};

const PURCHASE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; // a legacy purchase_items id

function masterItem(id, name, category, base_size, base_unit) {
  return { id, organization_id: 'org-1', name, category, subcategory: null,
           base_size: base_size || null, base_unit: base_unit || null,
           is_active: true, created_at: '2026-01-01T00:00:00Z', product_id: null };
}

function seed() {
  return {
    kount_venues: [
      { id: 'v-delilah', name: 'Delilah LA', address: 'LA', ordinal: 1, is_active: true,
        default_zones: ['Liquor Room', 'Bar', 'Service Well'], store_aliases: [] },
    ],
    app_users: [
      { id: 'u-corp', email: 'apurandare@hwoodgroup.com', name: 'Aditya', role: 'corporate', is_active: true, venue_ids: null },
      { id: 'u-mgr',  email: 'manager@hwood.com', name: 'Manny', role: 'manager', is_active: true, venue_ids: ['v-delilah'] },
      { id: 'u-cnt',  email: 'counter@hwood.com', name: 'Casey', role: 'counter', is_active: true, venue_ids: ['v-delilah'] },
    ],
    purchase_items: [
      { id: PURCHASE, name: 'Legacy Purchase Item', master_item_id: M.belv },
    ],
    master_items: [
      masterItem(M.belv,    'Belvedere 1L',                       'Liquor Cost', 1,    'L'),
      masterItem(M.belv175, 'Belvedere 1.75L',                    'Liquor Cost', 1.75, 'L'),
      masterItem(M.dj1942,  'Don Julio 1942 750ml',               'Liquor Cost', 750,  'ml'),
      masterItem(M.campari, 'Campari 1L',                         'Liquor Cost', 1,    'L'),
      masterItem(M.titos,   "Tito's Handmade Vodka 750ml",        'Liquor Cost', 750,  'ml'),
      masterItem(M.cab,     'Rodney Strong Cabernet 2022 750ml',  'Wine Cost',   750,  'ml'),
      masterItem(M.redbull, 'Red Bull 8.4oz',                     'N/A Beverage Cost', 250, 'ml'),
    ],
    // Carried subset: everything EXCEPT Don Julio 1942 — so a manual search for
    // "Don Julio" must fall through to the full-catalog ("Not in your
    // inventory list") path that v1.48 added.
    kount_carried_items: [
      { master_item_id: M.belv }, { master_item_id: M.belv175 },
      { master_item_id: M.campari },
      { master_item_id: M.titos }, { master_item_id: M.cab }, { master_item_id: M.redbull },
    ],
    master_item_upcs: [
      { id: 'upc-1', master_item_id: M.belv, upc_raw: '5060071510019', upc_normalized: '5060071510019', source: 'seed' },
    ],
    upc_mappings: [],
    kount_audits: [],
    kount_members: [],
    kount_entries: [],
    kount_recounts: [],
    kount_pending_items: [],
    kount_venue_zones: [],
    // v1.70: compute_avt_for_audit (called at count-1 close now) inserts here.
    kount_avt_reports: [],
    kount_avt_rows: [],
  };
}

module.exports = { seed, M, PURCHASE };
