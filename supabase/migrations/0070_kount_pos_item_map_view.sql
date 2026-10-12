-- =============================================================================
--  0070_kount_pos_item_map_view
--
--  The POS -> counted-item mapping, visible from the counting side.
--
--  WHY (2026-10-08)
--  A venue's POS depletion is mapped in KevaOS: menu_item_recipe_map (one sale
--  = one whole bottle/can) and new_recipe_pos_skus -> new_recipes ->
--  new_recipe_ingredients (one sale = N fl.oz of a bottle). compute_avt_for_audit
--  reads exactly those tables. Aditya: the mapping should be present in BOTH
--  places so either side can work from it. A second, hand-kept copy would drift
--  and -- if the variance read both -- count a sale twice. So the counting side
--  gets a READ-ONLY VIEW over the KevaOS rows: always identical, nothing to sync.
--
--  WHAT
--  v_kount_pos_item_map: one row per (counting venue, POS item, counted item),
--    mapping = 'direct'    -> qty_per_sale whole units (menu_item_recipe_map, bottle service)
--              'recipe'    -> qty_per_sale in `unit` (fl.oz, each, ...) via a recipe
--              'covered_by_recipe' -> an old non-depleting link whose POS item now
--                             depletes through a 'recipe' row (shown for traceability)
--              'link_only' -> linked to an item but NOT depleting (not bottle service,
--                             or no item) and no recipe either -- the gap list
--              'excluded'  -> deliberately excluded (fees, notes, open items)
--  Venues are bridged through kount_venues.ops_venue_id (0056).
--
--  ACCESS
--  The view runs with its owner's rights (counting staff have no KevaOS org
--  membership, so an invoker view would read nothing -- the 2026-09 outage), and
--  gates every row itself on kount_is_corporate() / kount_can_see_venue(), the
--  0055 helpers. security_barrier keeps that gate ahead of caller predicates.
--  SELECT only: authenticated + service_role. anon: nothing.
--
--  CHANGES NO DATA. No table, row, or function is altered; the variance is unchanged.
--  ROLLBACK: drop view if exists public.v_kount_pos_item_map;
-- =============================================================================

begin;

create or replace view public.v_kount_pos_item_map
with (security_barrier = true) as
with kv as (
  select k.id as kount_venue_id, k.ops_venue_id
    from public.kount_venues k
   where k.ops_venue_id is not null
)
select kv.kount_venue_id,
       kv.ops_venue_id,
       m.menu_item_name                         as pos_item_name,
       case
         when coalesce(m.is_excluded, false)                              then 'excluded'
         when coalesce(m.is_bottle_service, false) and m.master_item_id is not null then 'direct'
         when exists (select 1 from public.new_recipe_pos_skus p2
                       where p2.venue_id = m.venue_id
                         and lower(trim(p2.pos_sku)) = lower(trim(m.menu_item_name))) then 'covered_by_recipe'
         else 'link_only'
       end                                      as mapping,
       m.master_item_id,
       mi.name                                  as master_item_name,
       case when coalesce(m.is_bottle_service, false) and m.master_item_id is not null
             and not coalesce(m.is_excluded, false) then 1::numeric end as qty_per_sale,
       'each'::text                             as unit,
       null::uuid                               as recipe_id,
       null::text                               as recipe_name,
       m.exclude_reason                         as note,
       'menu_item_recipe_map'::text             as source_table,
       m.id                                     as source_row_id,
       m.updated_at
  from kv
  join public.menu_item_recipe_map m on m.venue_id = kv.ops_venue_id
  left join public.master_items mi on mi.id = m.master_item_id
 where m.is_active
   and (public.kount_is_corporate() or public.kount_can_see_venue(kv.kount_venue_id))
union all
select kv.kount_venue_id,
       kv.ops_venue_id,
       p.pos_sku                                as pos_item_name,
       'recipe'::text                           as mapping,
       nrimm.master_item_id,
       mi.name                                  as master_item_name,
       i.quantity                               as qty_per_sale,
       i.unit,
       r.id                                     as recipe_id,
       r.name                                   as recipe_name,
       null::text                               as note,
       'new_recipe_pos_skus'::text              as source_table,
       null::uuid                               as source_row_id,
       r.updated_at
  from kv
  join public.new_recipe_pos_skus p on p.venue_id = kv.ops_venue_id
  join public.new_recipes r on r.id = p.recipe_id
  join public.new_recipe_ingredients i on i.recipe_id = r.id and coalesce(i.is_sub_recipe, false) = false
  left join public.new_recipe_ingredient_master_map nrimm on nrimm.ingredient_name = i.ingredient_name
  left join public.master_items mi on mi.id = nrimm.master_item_id
 where (public.kount_is_corporate() or public.kount_can_see_venue(kv.kount_venue_id));

comment on view public.v_kount_pos_item_map is
  'Read-only counting-side view of each venue''s POS -> counted-item mapping, built live from the KevaOS '
  'tables compute_avt_for_audit depletes from (menu_item_recipe_map, new_recipe_pos_skus/new_recipes). '
  'mapping: direct | recipe | covered_by_recipe | link_only (does not deplete) | excluded. Edit the mapping in KevaOS; '
  'this view always reflects it. Rows gated by kount_is_corporate() / kount_can_see_venue().';

revoke all on public.v_kount_pos_item_map from anon, public;
grant select on public.v_kount_pos_item_map to authenticated, service_role;

-- Post-check: view exists and anon cannot read it.
do $$ begin
  if to_regclass('public.v_kount_pos_item_map') is null then
    raise exception '0070: view missing';
  end if;
  if has_table_privilege('anon', 'public.v_kount_pos_item_map', 'select') then
    raise exception '0070: anon can read v_kount_pos_item_map';
  end if;
end $$;

commit;
