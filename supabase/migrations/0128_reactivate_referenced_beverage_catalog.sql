-- =============================================================================
--  0128_reactivate_referenced_beverage_catalog   (DATA, shared catalog)
--
--  2026-11-02, at Aditya's request ("I want everything in and showing").
--  131 of the 397 items Little Luck counted on 10/25 were archived on 11/1
--  (a merge that archived both sides: merged_into_id chains loop or dead-end),
--  and across the catalog 7,620 archived items are referenced somewhere with
--  no live replacement. User chose: bring back every BEVERAGE one.
--
--  1. Reactivates archived items that are referenced (counted, on a purchase
--     line, barcoded, priced or POS-linked), whose merged_into_id chain never
--     reaches a live item, in a beverage category (any spelling). Clears
--     merged_into_id, fills base_size/unit from the name where missing.
--  2. Normalises odd category spellings ('liquor cost', 'wine cost',
--     'beverage', ...) on ACTIVE items to the values the phone, the admin and
--     compute_avt already recognise, so they show in search and count in
--     the variance. Nothing in the apps changes.
--  3. Files the liquor barcodes that purchase lines carry but
--     master_item_upcs lacks (unambiguous ones only).
--  Originals in _mig0128_items. Items whose chain reaches a live item (true
--  merges, 70) stay archived.
--  ROLLBACK: 0128_ROLLBACK_reactivate_referenced_beverage_catalog.sql
-- =============================================================================
begin;

create table if not exists public._mig0128_items (
  id uuid primary key, prev_is_active boolean not null, prev_merged_into uuid, prev_category text,
  prev_base_size numeric, prev_base_unit text, prev_updated_at timestamptz, action text not null);
alter table public._mig0128_items enable row level security;
revoke all on public._mig0128_items from anon, authenticated;

create temp table _bev_cat (raw text primary key, canon text) on commit drop;
insert into _bev_cat values
  ('Liquor Cost','Liquor Cost'), ('liquor','liquor'), ('Liquor','Liquor'), ('liquor cost','Liquor Cost'),
  ('Wine Cost','Wine Cost'), ('wine','wine'), ('Wine','Wine'), ('wine cost','Wine Cost'),
  ('Beer Cost','Beer Cost'), ('beer','beer'), ('beer cost','Beer Cost'),
  ('N/A Beverage Cost','N/A Beverage Cost'), ('non_alcoholic_beverage','non_alcoholic_beverage'),
  ('n/a beverage cost','N/A Beverage Cost'), ('beverage','N/A Beverage Cost'), ('bev','N/A Beverage Cost'),
  ('Bar Consumables','Bar Consumables'), ('bar_consumable','bar_consumable'), ('bar consumables','Bar Consumables'),
  ('Bar Supplies','Bar Supplies');

-- Spelling twins: the same product under an old lowercase category and the
-- newer "... Cost" one. The newer row is the one to keep.
create temp table _twin (raw text primary key, canon text) on commit drop;
insert into _twin values
  ('liquor','Liquor Cost'), ('Liquor','Liquor Cost'), ('liquor cost','Liquor Cost'),
  ('wine','Wine Cost'), ('Wine','Wine Cost'), ('wine cost','Wine Cost'),
  ('beer','Beer Cost'), ('beer cost','Beer Cost'),
  ('non_alcoholic_beverage','N/A Beverage Cost'), ('n/a beverage cost','N/A Beverage Cost'), ('beverage','N/A Beverage Cost'), ('bev','N/A Beverage Cost'),
  ('bar_consumable','Bar Consumables'), ('bar consumables','Bar Consumables');

-- Indexed snapshot of the catalog as it stands before this migration, so the
-- name/category lookups below don't scan master_items per row.
create temp table _mi on commit drop as
  select id, organization_id, lower(name) as lname, category, is_active, merged_into_id from public.master_items;
create index on _mi (organization_id, lname, category);
create index on _mi (id);
analyze _mi;

-- 1. Which archived items come back.
with recursive refd as (
  select m.id from public.master_items m join _bev_cat b on b.raw = m.category
   where not m.is_active
     -- an old-spelling row whose newer twin exists is a duplicate: leave it archived
     and not exists (select 1 from _twin w join _mi t on t.organization_id = m.organization_id
                        and t.lname = lower(m.name) and t.category = w.canon and t.id <> m.id
                      where w.raw = m.category)
     and (exists (select 1 from public.kount_entries e where e.master_item_id = m.id)
       or exists (select 1 from public.purchase_items p where p.master_item_id = m.id)
       or exists (select 1 from public.master_item_upcs x where x.master_item_id = m.id)
       or exists (select 1 from public.kount_venue_cost_overrides c where c.master_item_id = m.id)
       or exists (select 1 from public.new_recipe_ingredient_master_map r where r.master_item_id = m.id))
),
hop as (
  select r.id start_id, r.id cur, false act, m.merged_into_id nxt, 0 d, array[r.id] path
    from refd r join _mi m on m.id = r.id
  union all
  select h.start_id, n.id, n.is_active, n.merged_into_id, h.d + 1, h.path || n.id
    from hop h join _mi n on n.id = h.nxt
   where not h.act and h.d < 8 and not (n.id = any(h.path))
),
chain as (select start_id, bool_or(act) reaches_live from hop group by start_id)
insert into public._mig0128_items (id, prev_is_active, prev_merged_into, prev_category, prev_base_size, prev_base_unit, prev_updated_at, action)
select m.id, m.is_active, m.merged_into_id, m.category, m.base_size, m.base_unit, m.updated_at, 'reactivated'
  from chain c join public.master_items m on m.id = c.start_id
 where not c.reaches_live
on conflict (id) do nothing;

update public.master_items m
   set is_active = true, merged_into_id = null, updated_at = now(),
       base_size = coalesce(m.base_size,
                     case when m.name ~* '(\d+(\.\d+)?)\s*ml\M' then (substring(m.name from '(?i)(\d+(?:\.\d+)?)\s*ml\M'))::numeric
                          when m.name ~* '(\d+(\.\d+)?)\s*l\M'  then (substring(m.name from '(?i)(\d+(?:\.\d+)?)\s*l\M'))::numeric * 1000
                          else null end),
       base_unit = coalesce(m.base_unit, case when m.name ~* '\d\s*(ml|l)\M' then 'ml' else null end)
  from public._mig0128_items r
 where r.id = m.id and r.action = 'reactivated';

-- 1b. Spelling twins where the OLD lowercase row is live (39 of them from
--     0127) and the newer canonical row ("Liquor Cost" etc., what Little Luck
--     counted on 10/25) is archived: bring the canonical row back and fold the
--     old twin into it, so each product is live exactly once and last week's
--     and this week's counts land on the same item.
create table if not exists public._mig0128_merges (low_id uuid primary key, canon_id uuid not null);
create table if not exists public._mig0128_repoints (id bigserial primary key, table_name text, row_id text, old_master uuid, new_master uuid);
create table if not exists public._mig0128_deleted (id bigserial primary key, table_name text, row jsonb);
alter table public._mig0128_merges enable row level security;
alter table public._mig0128_repoints enable row level security;
alter table public._mig0128_deleted enable row level security;
revoke all on public._mig0128_merges, public._mig0128_repoints, public._mig0128_deleted from anon, authenticated;

insert into public._mig0128_merges (low_id, canon_id)
select l.id, c.id
  from _mi c join _twin k on k.canon = c.category
  join _mi l on l.organization_id = c.organization_id and l.lname = c.lname and l.category = k.raw and l.id <> c.id
 where l.is_active and not c.is_active
on conflict (low_id) do nothing;

insert into public._mig0128_items (id, prev_is_active, prev_merged_into, prev_category, prev_base_size, prev_base_unit, prev_updated_at, action)
select m.id, m.is_active, m.merged_into_id, m.category, m.base_size, m.base_unit, m.updated_at, 'reactivated (twin folded in)'
  from public._mig0128_merges g join public.master_items m on m.id = g.canon_id
on conflict (id) do nothing;
insert into public._mig0128_items (id, prev_is_active, prev_merged_into, prev_category, prev_base_size, prev_base_unit, prev_updated_at, action)
select m.id, m.is_active, m.merged_into_id, m.category, m.base_size, m.base_unit, m.updated_at, 'folded into twin'
  from public._mig0128_merges g join public.master_items m on m.id = g.low_id
on conflict (id) do nothing;

update public.master_items c
   set is_active = true, merged_into_id = null, updated_at = now(),
       base_size = coalesce(c.base_size, l.base_size), base_unit = coalesce(c.base_unit, l.base_unit)
  from public._mig0128_merges g join public.master_items l on l.id = g.low_id
 where c.id = g.canon_id;

-- Rows that may simply move to the canonical item.
insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'master_item_upcs', x.id::text, g.low_id, g.canon_id from public.master_item_upcs x join public._mig0128_merges g on g.low_id = x.master_item_id;
update public.master_item_upcs x set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = x.master_item_id;

insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'kount_entries', e.id::text, g.low_id, g.canon_id from public.kount_entries e join public._mig0128_merges g on g.low_id = e.master_item_id;
update public.kount_entries e set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = e.master_item_id;

insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'kount_recounts', r.id::text, g.low_id, g.canon_id from public.kount_recounts r join public._mig0128_merges g on g.low_id = r.master_item_id;
update public.kount_recounts r set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = r.master_item_id;

insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'purchase_items', p.id::text, g.low_id, g.canon_id from public.purchase_items p join public._mig0128_merges g on g.low_id = p.master_item_id;
update public.purchase_items p set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = p.master_item_id;

insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'new_recipe_ingredient_master_map', r.ingredient_name, g.low_id, g.canon_id from public.new_recipe_ingredient_master_map r join public._mig0128_merges g on g.low_id = r.master_item_id;
update public.new_recipe_ingredient_master_map r set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = r.master_item_id;

-- Rows keyed by (venue, item): move when the canonical item has none, else drop the twin's.
insert into public._mig0128_deleted (table_name, row)
select 'kount_venue_cost_overrides', to_jsonb(o) from public.kount_venue_cost_overrides o join public._mig0128_merges g on g.low_id = o.master_item_id
 where exists (select 1 from public.kount_venue_cost_overrides k where k.venue_id = o.venue_id and k.master_item_id = g.canon_id);
delete from public.kount_venue_cost_overrides o using public._mig0128_merges g where g.low_id = o.master_item_id
   and exists (select 1 from public.kount_venue_cost_overrides k where k.venue_id = o.venue_id and k.master_item_id = g.canon_id);
insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'kount_venue_cost_overrides', o.venue_id, g.low_id, g.canon_id from public.kount_venue_cost_overrides o join public._mig0128_merges g on g.low_id = o.master_item_id;
update public.kount_venue_cost_overrides o set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = o.master_item_id;

insert into public._mig0128_deleted (table_name, row)
select 'venue_item_settings', to_jsonb(s) from public.venue_item_settings s join public._mig0128_merges g on g.low_id = s.master_item_id
 where exists (select 1 from public.venue_item_settings k where k.venue_id = s.venue_id and k.master_item_id = g.canon_id);
delete from public.venue_item_settings s using public._mig0128_merges g where g.low_id = s.master_item_id
   and exists (select 1 from public.venue_item_settings k where k.venue_id = s.venue_id and k.master_item_id = g.canon_id);
insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'venue_item_settings', s.id::text, g.low_id, g.canon_id from public.venue_item_settings s join public._mig0128_merges g on g.low_id = s.master_item_id;
update public.venue_item_settings s set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = s.master_item_id;

insert into public._mig0128_deleted (table_name, row)
select 'kount_venue_catalog', to_jsonb(v) from public.kount_venue_catalog v join public._mig0128_merges g on g.low_id = v.master_item_id
 where exists (select 1 from public.kount_venue_catalog k where k.venue_id = v.venue_id and k.master_item_id = g.canon_id);
delete from public.kount_venue_catalog v using public._mig0128_merges g where g.low_id = v.master_item_id
   and exists (select 1 from public.kount_venue_catalog k where k.venue_id = v.venue_id and k.master_item_id = g.canon_id);
insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'kount_venue_catalog', v.venue_id, g.low_id, g.canon_id from public.kount_venue_catalog v join public._mig0128_merges g on g.low_id = v.master_item_id;
update public.kount_venue_catalog v set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = v.master_item_id;

insert into public._mig0128_deleted (table_name, row)
select 'kount_carried_items', to_jsonb(ci) from public.kount_carried_items ci join public._mig0128_merges g on g.low_id = ci.master_item_id
 where exists (select 1 from public.kount_carried_items k where k.master_item_id = g.canon_id);
delete from public.kount_carried_items ci using public._mig0128_merges g where g.low_id = ci.master_item_id
   and exists (select 1 from public.kount_carried_items k where k.master_item_id = g.canon_id);
insert into public._mig0128_repoints (table_name, row_id, old_master, new_master)
select 'kount_carried_items', ci.id::text, g.low_id, g.canon_id from public.kount_carried_items ci join public._mig0128_merges g on g.low_id = ci.master_item_id;
update public.kount_carried_items ci set master_item_id = g.canon_id from public._mig0128_merges g where g.low_id = ci.master_item_id;

-- Archive the old twin, pointing at the row that replaced it.
update public.master_items l
   set is_active = false, merged_into_id = g.canon_id, updated_at = now()
  from public._mig0128_merges g where l.id = g.low_id;

-- 2. Category spellings the apps don't recognise, on active items.
insert into public._mig0128_items (id, prev_is_active, prev_merged_into, prev_category, prev_base_size, prev_base_unit, prev_updated_at, action)
select m.id, m.is_active, m.merged_into_id, m.category, m.base_size, m.base_unit, m.updated_at, 'recategorised'
  from public.master_items m join _bev_cat b on b.raw = m.category
 where m.is_active and b.raw <> b.canon
   and not exists (select 1 from public.master_items t where t.organization_id = m.organization_id
                     and t.name = m.name and t.category = b.canon and t.id <> m.id)
on conflict (id) do update set action = 'reactivated+recategorised';

update public.master_items m
   set category = b.canon, updated_at = now()
  from _bev_cat b
 where b.raw = m.category and m.is_active and b.raw <> b.canon
   and not exists (select 1 from public.master_items t where t.organization_id = m.organization_id
                     and t.name = m.name and t.category = b.canon and t.id <> m.id);

-- 3. Liquor barcodes on purchase lines that master_item_upcs lacks.
with pi as (
  select regexp_replace(regexp_replace(p.upc, '\D', '', 'g'), '^0+', '') norm, min(p.upc) raw, min(p.master_item_id::text)::uuid master_item_id,
         count(distinct p.master_item_id) masters
    from public.purchase_items p join public.master_items m on m.id = p.master_item_id and m.is_active
   where m.category in ('Liquor Cost','liquor','Liquor','Wine Cost','wine','Wine','Beer Cost','beer','N/A Beverage Cost','non_alcoholic_beverage','Bar Consumables','bar_consumable')
     and coalesce(p.upc,'') ~ '^\D*\d{6,14}\D*$'
   group by 1
)
insert into public.master_item_upcs (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
select pi.master_item_id, pi.raw, pi.norm, 'purchase_items_backfill_0128', 'Barcode carried on the item''s purchase lines (0128)', 'apurandare@hwoodgroup.com'
  from pi
 where pi.masters = 1 and length(pi.norm) between 6 and 14
   and not exists (select 1 from public.master_item_upcs x where x.upc_normalized = pi.norm)
   and not exists (select 1 from public.master_item_upcs x where x.master_item_id = pi.master_item_id);

do $$
declare react int; recat int; bc int; lw int;
begin
  select count(*) into react from public._mig0128_items where action like 'reactivated%';
  select count(*) into recat from public._mig0128_items where action like '%recategorised';
  select count(*) into bc from public.master_item_upcs where source = 'purchase_items_backfill_0128';
  select count(distinct e.master_item_id) into lw from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
    join public.master_items m on m.id = e.master_item_id
   where a.join_code in ('LL-043','LL-038') and not m.is_active;
  raise notice '0128: reactivated %, recategorised %, barcodes filed %, last-week LL items still archived %', react, recat, bc, lw;
  if react < 2500 or react > 4800 or lw > 0 then
    raise exception '0128: outside expectations (reactivated %, last-week items still archived %)', react, lw;
  end if;
end $$;

select 'summary' as what, action as item, count(*)::text as detail from public._mig0128_items group by action
union all
select 'twins folded', table_name, count(*)::text from public._mig0128_repoints group by table_name
union all
select 'twin rows dropped', table_name, count(*)::text from public._mig0128_deleted group by table_name
union all
select 'folded sample', l.name || ' [' || l.category || '] -> [' || c.category || ']', null
  from (select * from public._mig0128_merges order by low_id limit 8) g join public.master_items l on l.id = g.low_id join public.master_items c on c.id = g.canon_id
union all
select 'category', prev_category || ' -> ' || m.category, count(*)::text
  from public._mig0128_items r join public.master_items m on m.id = r.id where r.action like '%recategorised' group by 1, 2
union all
select 'beverage->', m.name, m.category from public._mig0128_items r join public.master_items m on m.id = r.id where r.prev_category in ('beverage','bev')
union all
select 'barcodes filed', (select count(*)::text from public.master_item_upcs where source = 'purchase_items_backfill_0128'), null
union all
select 'liquor coverage', 'active liquor items with a barcode / active liquor items',
       (select count(*) filter (where exists (select 1 from public.master_item_upcs x where x.master_item_id = m.id)) || ' / ' || count(*)
          from public.master_items m where m.is_active and m.category in ('Liquor Cost','liquor','Liquor'))
order by 1, 2;
commit;
