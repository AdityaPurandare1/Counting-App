-- =============================================================================
--  0146_kount_ot_item_location   (where a stocked item is kept)
--
--  The user (2026-11-03) sent E&E's current warehouse inventory (Flowspace, 48
--  items) and the stock held at corporate: "5 cases of delilah mints with me at
--  corporate and 1 case of poppy togo bags and 1 case of keys togo bags at
--  corporate as well along with 3 bags of delilah pins". The Warehouse tab now
--  shows stock by where it is kept:
--
--    kount_ot_items.location   'E&E warehouse' (default) | 'Corporate' | another place
--
--  E&E's delivery fee lines draw only from the E&E warehouse's items.
-- =============================================================================
begin;

alter table public.kount_ot_items add column if not exists location text not null default 'E&E warehouse'
  check (length(btrim(location)) > 0);

comment on column public.kount_ot_items.location is
  'Where the stock is kept: E&E warehouse (default), Corporate, ... (0146); E&E deliveries draw only from E&E warehouse items';

commit;
