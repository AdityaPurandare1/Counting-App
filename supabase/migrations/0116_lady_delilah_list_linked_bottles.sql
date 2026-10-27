-- =============================================================================
--  0116_lady_delilah_list_linked_bottles   (DATA)
--
--  0114 priced only the bottles its own links reach. Bottles reached by 0106's
--  links (Fernet Branca, Coke 8oz, San Pellegrino 1L, Acqua Panna 1L) and by
--  the shared Delilah cocktail recipes LD uses (agave, lemon / lime juice,
--  strawberry syrup, Peychaud's, Tosti Cardamaro, Dom Perignon) were still
--  off Lady Delilah's item list. Same proxy rule as 0114: catalog cost, or
--  other venues' median when the catalog is missing or >2x off it;
--  is_manual = false, price_date 2026-08-01 so the first LD invoice replaces
--  it. In-scope (bar) categories only -- the caviar garnish is not counted.
--  ROLLBACK: delete from kount_venue_cost_overrides where venue_id = 'v14' and set_by = 'ld-proxy-costing-2026-10-27b';
-- =============================================================================
begin;

insert into public.kount_venue_cost_overrides
  (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v14', b.mid, round((case when b.use_cat then b.cat_cost else b.ven_cost end)::numeric, 4),
       case when b.use_cat
            then 'PROXY catalog cost (company-wide purchase_items.avg_cost) as of 2026-10-27; replaced by the first Lady Delilah invoice'
            else 'PROXY median of other venues'' prices as of 2026-10-27; replaced by the first Lady Delilah invoice' end,
       'ld-proxy-costing-2026-10-27b', false, date '2026-08-01', now()
  from (
    select c.*, c.cat_cost is not null and (c.ven_cost is null or c.cat_cost between c.ven_cost / 2 and c.ven_cost * 2) as use_cat
      from (
        select d.mid,
               (select p.avg_cost from public.purchase_items p where p.master_item_id = d.mid and p.avg_cost > 0
                 order by p.updated_at desc nulls last, p.id desc limit 1) as cat_cost,
               (select percentile_cont(0.5) within group (order by o.cost_per_unit)
                  from public.kount_venue_cost_overrides o where o.master_item_id = d.mid and o.venue_id <> 'v14'
                   and o.cost_per_unit > 0) as ven_cost
          from (select distinct nm.master_item_id as mid
                  from public.new_recipe_pos_skus s
                  join public.new_recipe_ingredients ri on ri.recipe_id = s.recipe_id and coalesce(ri.is_sub_recipe, false) = false
                  join public.new_recipe_ingredient_master_map nm on nm.ingredient_name = ri.ingredient_name
                  join public.master_items mi on mi.id = nm.master_item_id and mi.is_active
                 where s.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'
                   and mi.category in ('Wine Cost','wine','Wine','Liquor Cost','liquor','Liquor','Beer Cost','beer',
                                       'N/A Beverage Cost','non_alcoholic_beverage','Bar Consumables','bar_consumable','Bar Supplies')) d
         where not exists (select 1 from public.kount_venue_cost_overrides o where o.venue_id = 'v14' and o.master_item_id = d.mid)
      ) c
  ) b
 where coalesce(case when b.use_cat then b.cat_cost else b.ven_cost end, 0) > 0;

select mi.name, o.cost_per_unit::text cost
  from public.kount_venue_cost_overrides o join public.master_items mi on mi.id = o.master_item_id
 where o.venue_id = 'v14' and o.set_by = 'ld-proxy-costing-2026-10-27b' order by 1;
commit;
