-- =============================================================================
--  0155_kount_food_matching   (FUNCTIONS + TABLE + RPC change, admin v1.03)
--
--  The user (2026-11-05): "we need to build matches so that regardless of how
--  chef inputs it we can match it with the correct item" + a screen where the
--  chef just types quantities.
--
--  Until now kount_import_food_count matched an uploaded name to the catalog by
--  EXACT name across the whole catalog, archived rows included, and switched an
--  archived match back on. "Unsalted Butter" vs "Butter, Unsalted" became a new
--  product; a name that hit a merged twin re-activated it while still merged
--  (26 of Little Luck's 10/30 food lines sit on such rows).
--
--    kount_food_key(text)       spelling-proof key: lower case, accents, pack /
--                               size text ("(4/1 gal)", "5lb", "20/24", "40%")
--                               and punctuation gone, simple plurals singular,
--                               words sorted -> "Unsalted Butter" = "Butter,
--                               Unsalted" = "Butter Unsalted 1 lb". Same rules as
--                               Counting-Admin src/lib/foodMatch.ts foodKey (a test
--                               compares the verification cases below).
--    kount_live_item(uuid)      the item itself if live, else the first live item
--                               down its merge chain; null for a dead end / loop
--    kount_food_aliases         per venue: a name someone confirmed -> its item
--    kount_food_alias_save(venue, alias, item)   remember a confirmed match
--    kount_import_food_count    resolves each row: (a) an item picked on screen
--                               (row.master_item_id), (b) a confirmed alias,
--                               (c) the venue's food list by exact name, (d) the
--                               venue's list by key (only when one item has it),
--                               (e) a LIVE catalog item by exact name; on commit
--                               (f) an archived, NOT merged, same-name item is
--                               switched back on (the venue stocks it); (g) new
--                               items only when no row of that name+category
--                               exists. Never re-activates a merged row. Returns
--                               how each row matched.
--    units_per_case backfill    from the pack Little Luck types into the unit:
--                               "cs (12/12 oz)" -> 12, "pk (50 ct)" -> 50.
-- =============================================================================
begin;

-- ── the spelling-proof key ──────────────────────────────────────────────────
create or replace function public.kount_food_key(p_name text)
returns text language sql immutable parallel safe set search_path to 'pg_catalog' as $fn$
  with s0 as (
    select translate(lower(coalesce(p_name, '')), 'áàâäãåéèêëíìîïóòôöõúùûüçñ', 'aaaaaaeeeeiiiiooooouuuucn') as s
  ), s1 as (
    select regexp_replace(s, '\([^)]*\)', ' ', 'g') as s from s0                                     -- "(4/1 gal)", "(Margaret River)"
  ), s2 as (
    select regexp_replace(replace(s, '&', ' and '),
             '\d+(\.\d+)?\s*(lbs?|#|oz|g|kg|ml|l|gal|ct|pcs?|pk|cs|ea|qt|pt|dz|in|cm|mm|%)(?![a-z])', ' ', 'g') as s from s1   -- "5lb", "1.8L", "40%"
  ), s3 as (
    select regexp_replace(regexp_replace(s, '\d+(\.\d+)?(/\d+(\.\d+)?)*', ' ', 'g'), '[^a-z0-9]+', ' ', 'g') as s from s2  -- "20/24", "10", punctuation
  ), w as (
    select distinct case
             when length(t) > 3 and t ~ '(ss|us|is)$' then t
             when length(t) > 4 and t ~ 'ies$' then left(t, -3) || 'y'
             when length(t) > 4 and t ~ '(ch|sh|x|z)es$' then left(t, -2)
             when length(t) > 4 and t ~ 'oes$' then left(t, -2)
             when length(t) > 3 and t ~ 's$' then left(t, -1)
             else t end as t
      from s3, regexp_split_to_table(s3.s, ' ') as t
     where t <> '' and t not in ('and', 'the', 'of', 'a', 'w', 'with', 'for', 'in', 'x')
  )
  select coalesce(string_agg(t, ' ' order by t), '') from w;
$fn$;

-- ── the live end of a merge chain ──────────────────────────────────────────
create or replace function public.kount_live_item(p_id uuid)
returns uuid language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $fn$
declare
  v_cur uuid := p_id; v_active boolean; v_next uuid; v_hops int := 0;
begin
  while v_cur is not null and v_hops <= 12 loop
    select m.is_active, m.merged_into_id into v_active, v_next from public.master_items m where m.id = v_cur;
    if not found then return null; end if;
    if v_active then return v_cur; end if;   -- live (an active row that still points somewhere is treated as live)
    v_cur := v_next; v_hops := v_hops + 1;
    if v_cur = p_id then return null; end if; -- a loop
  end loop;
  return null;
end
$fn$;

-- ── remembered matches, per venue ──────────────────────────────────────────
create table if not exists public.kount_food_aliases (
  venue_id        text not null,
  alias_key       text not null,
  alias_text      text not null,
  master_item_id  uuid not null references public.master_items (id) on delete cascade,
  source          text not null default 'confirmed',
  created_by      text,
  created_at      timestamptz not null default now(),
  primary key (venue_id, alias_key)
);
comment on table public.kount_food_aliases is 'Food names a person confirmed for a venue -> the catalog item (0155); matched by kount_food_key';
alter table public.kount_food_aliases enable row level security;
revoke all on table public.kount_food_aliases from public, anon, authenticated;
grant select on table public.kount_food_aliases to authenticated;
drop policy if exists kount_food_aliases_read on public.kount_food_aliases;
create policy kount_food_aliases_read on public.kount_food_aliases for select to authenticated
  using (public.kount_has_feature('admin:food-count'));

create or replace function public.kount_food_alias_save(p_venue_id text, p_alias text, p_master_item_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_key   text := public.kount_food_key(p_alias);
  v_live  uuid := public.kount_live_item(p_master_item_id);
begin
  if not exists (select 1 from public.app_users u where lower(u.email) = v_email and u.is_active = true
                   and 'admin:food-count' = any (u.features)
                   and ('access:all-venues' = any (u.features) or p_venue_id = any (u.venue_ids))) then
    raise exception 'not authorized to set food matches for %', p_venue_id using errcode = '42501';
  end if;
  if v_key = '' then raise exception 'empty name' using errcode = '22023'; end if;
  if v_live is null then raise exception 'that item is archived with no live replacement' using errcode = '22023'; end if;
  insert into public.kount_food_aliases (venue_id, alias_key, alias_text, master_item_id, source, created_by)
  values (p_venue_id, v_key, left(btrim(p_alias), 200), v_live, 'confirmed', v_email)
  on conflict (venue_id, alias_key) do update
     set master_item_id = excluded.master_item_id, alias_text = excluded.alias_text, source = 'confirmed',
         created_by = excluded.created_by, created_at = now();
  return jsonb_build_object('venue_id', p_venue_id, 'alias_key', v_key, 'master_item_id', v_live);
end
$fn$;
revoke all on function public.kount_food_alias_save(text, text, uuid) from public, anon;
grant execute on function public.kount_food_alias_save(text, text, uuid) to authenticated;

-- ── the import: resolve by venue first, never re-activate a merged row ──────
CREATE OR REPLACE FUNCTION public.kount_import_food_count(p_venue_id text, p_rows jsonb, p_counted_at timestamp with time zone DEFAULT now(), p_commit boolean DEFAULT false, p_create_missing boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email        text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_name         text;
  v_venue_name   text;
  v_audit_id     uuid;
  v_created      int := 0;
  v_entries      int := 0;
  v_costs        int := 0;
  v_unmatched    jsonb := '[]'::jsonb;
  v_total_value  numeric := 0;
  v_has_counts   boolean := false;
  v_how          jsonb;
begin
  -- 0. Authorization. Corporate/admin anywhere; manager only at their venue.
  --    Reads the VERIFIED JWT claim, never a caller-supplied argument.
  select u.name into v_name
    from public.app_users u
   where lower(u.email) = v_email
     and u.is_active = true
     and (
       'admin:food-count' = any (u.features)
       and ('access:all-venues' = any (u.features) or p_venue_id = any(u.venue_ids))
     );
  if not found then
    raise exception 'not authorized to import a food count for %', p_venue_id
      using errcode = '42501';
  end if;

  select kv.name into v_venue_name from public.kount_venues kv where kv.id = p_venue_id;
  if v_venue_name is null then
    raise exception 'unknown kount venue %', p_venue_id using errcode = 'P0002';
  end if;

  -- 1. Clean the sheet rows. Drops blanks and the per-sheet "TOTAL" subtotal rows.
  --    0155: a row may name its item outright (master_item_id), as the Food count screen does.
  create temp table _food_rows on commit drop as
  select
    row_number() over ()                                   as rn,
    btrim(r ->> 'item')                                    as item,
    nullif(btrim(lower(coalesce(r ->> 'unit', ''))), '')   as count_unit,
    nullif(r ->> 'pack', '')::numeric                      as units_per_case,
    nullif(r ->> 'qty', '')::numeric                       as qty,
    nullif(r ->> 'price', '')::numeric                     as price,
    nullif(btrim(coalesce(r ->> 'sheet', '')), '')         as sheet,
    nullif(r ->> 'sort', '')::int                          as sort_order,
    case when coalesce(r ->> 'master_item_id', '') ~ '^[0-9a-fA-F-]{36}$' then (r ->> 'master_item_id')::uuid end as picked_id
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as r
  where btrim(coalesce(r ->> 'item', '')) <> ''
    and upper(btrim(r ->> 'item')) <> 'TOTAL';

  -- 0088: an upload with no quantities is a LIST/PRICE setup, not a count.
  select exists (select 1 from _food_rows where qty is not null) into v_has_counts;

  -- 2. Resolve (0155): picked item -> confirmed alias -> the venue's list (exact name, then key, only when one
  --    list item has that key) -> a LIVE catalog item by exact name. Every hit is taken to the live end of its
  --    merge chain; a merged / looped row is never used as it is.
  create temp table _food_resolved on commit drop as
  with k as (select f.*, public.kount_food_key(f.item) as item_key from _food_rows f),
  list as (
    select fi.master_item_id, m.name, public.kount_food_key(m.name) as name_key, public.kount_live_item(fi.master_item_id) as live_id
      from public.kount_venue_food_items fi join public.master_items m on m.id = fi.master_item_id
     where fi.venue_id = p_venue_id
  ), tiers as (
    select k.*,
      public.kount_live_item(k.picked_id) as t_picked,
      (select public.kount_live_item(a.master_item_id) from public.kount_food_aliases a
        where a.venue_id = p_venue_id and a.alias_key = k.item_key and k.item_key <> '') as t_alias,
      (select (array_agg(l.live_id order by l.live_id))[1] from list l where lower(l.name) = lower(k.item) and l.live_id is not null) as t_list_name,
      (select case when count(distinct l.live_id) = 1 then (array_agg(l.live_id))[1] end
         from list l where l.name_key = k.item_key and k.item_key <> '' and l.live_id is not null) as t_list_key,
      (select (array_agg(m.id order by (m.base_unit is null), m.id))[1] from public.master_items m
        where lower(m.name) = lower(k.item) and m.is_active and m.merged_into_id is null) as t_catalog
    from k
  )
  select t.rn, t.item, t.count_unit, t.units_per_case, t.qty, t.price, t.sheet, t.sort_order, t.item_key,
         coalesce(t.t_picked, t.t_alias, t.t_list_name, t.t_list_key, t.t_catalog) as master_item_id,
         case when t.t_picked is not null then 'picked' when t.t_alias is not null then 'alias'
              when t.t_list_name is not null then 'list' when t.t_list_key is not null then 'list_key'
              when t.t_catalog is not null then 'catalog' end as matched_by
    from tiers t;

  -- 3. On commit: an archived same-name item that is NOT merged comes back (the venue stocks it); a new item
  --    only where no row of that name + category exists. A merged / looped row is never switched back on:
  --    such names stay unmatched for a person to pick.
  if p_commit then
    with revive as (
      select distinct on (f.rn) f.rn, m.id
        from _food_resolved f join public.master_items m on lower(m.name) = lower(f.item)
       where f.master_item_id is null and not m.is_active and m.merged_into_id is null
       order by f.rn, (m.base_unit is null), m.id
    ), upd as (
      update public.master_items m set is_active = true from revive r where m.id = r.id returning m.id
    )
    update _food_resolved f set master_item_id = r.id, matched_by = 'revived' from revive r where f.rn = r.rn;

    if p_create_missing then
      with ins as (
        insert into public.master_items (name, category, is_active)
        select distinct on (lower(f.item))
               f.item,
               case lower(coalesce(f.sheet, ''))
                 when 'meat_&_seafood' then 'Meat Cost'
                 when 'dairy_&_eggs'   then 'Dairy Cost'
                 when 'produce'        then 'Produce Cost'
                 else                       'Grocery and Dry Goods Cost'
               end,
               true
          from _food_resolved f
         where f.master_item_id is null
           and not exists (select 1 from public.master_items m where lower(m.name) = lower(f.item))
         order by lower(f.item)
        on conflict (organization_id, name, category) do nothing
        returning id, name
      )
      update _food_resolved f
         set master_item_id = ins.id, matched_by = 'created'
        from ins
       where lower(f.item) = lower(ins.name) and f.master_item_id is null;
      get diagnostics v_created = row_count;
    end if;
  end if;

  select coalesce(jsonb_agg(distinct f.item), '[]'::jsonb) into v_unmatched
    from _food_resolved f where f.master_item_id is null;
  select coalesce(jsonb_object_agg(coalesce(matched_by, 'unmatched'), n), '{}'::jsonb) into v_how
    from (select matched_by, count(*) n from _food_resolved group by matched_by) s;

  select coalesce(sum(f.qty * f.price), 0) into v_total_value
    from _food_resolved f where f.qty is not null and f.price is not null;

  -- 4. Commit: one food audit + its entries + venue costs + the food list (as 0081 / 0088).
  if p_commit and v_has_counts then
    insert into public.kount_audits
      (venue_id, venue_name, status, count_phase, audit_kind, join_code,
       started_by_email, started_by_name, started_at, count1_closed_at, completed_at, notes)
    values
      (p_venue_id, v_venue_name, 'submitted', 'final', 'food',
       'FOOD-' || to_char(p_counted_at, 'MMDD-HH24MI'),
       v_email, coalesce(v_name, v_email), p_counted_at, p_counted_at, p_counted_at,
       'Food count by ' || v_email)
    returning id into v_audit_id;

    insert into public.kount_entries
      (audit_id, item_name, master_item_id, category, qty, zone, method,
       counted_by_email, counted_by_name, is_recount, count_unit, units_per_case,
       client_entry_id, timestamp)
    select v_audit_id, f.item, f.master_item_id, f.sheet, f.qty,
           coalesce(replace(f.sheet, '_', ' '), 'Food'), 'manual',
           v_email, coalesce(v_name, v_email), false, f.count_unit, f.units_per_case,
           'FOOD-' || v_audit_id::text || '-' || f.rn::text, p_counted_at
      from _food_resolved f
     where f.master_item_id is not null
       and f.qty is not null;
    get diagnostics v_entries = row_count;
  end if;

  if p_commit then
    -- Costs: a seed (is_manual = false) the invoice refresh overwrites later.
    insert into public.kount_venue_cost_overrides
      (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
    select p_venue_id, f.master_item_id, f.price,
           'food workbook upload ' || to_char(p_counted_at, 'YYYY-MM-DD')
             || ' (' || coalesce(f.count_unit, 'unit') || ')',
           v_email, false, p_counted_at::date, now()
      from _food_resolved f
     where f.master_item_id is not null
       and f.price is not null and f.price > 0
    on conflict (venue_id, master_item_id) do update
       set cost_per_unit = excluded.cost_per_unit,
           source        = excluded.source,
           set_by        = excluded.set_by,
           is_manual     = false,
           price_date    = excluded.price_date,
           updated_at    = now();
    get diagnostics v_costs = row_count;

    -- The venue's food list + how it counts each item.
    insert into public.kount_venue_food_items
      (venue_id, master_item_id, count_unit, units_per_case, sheet_category, sort_order, updated_at)
    select distinct on (f.master_item_id)
           p_venue_id, f.master_item_id, f.count_unit, f.units_per_case, f.sheet, f.sort_order, now()
      from _food_resolved f
     where f.master_item_id is not null
     order by f.master_item_id, f.rn
    on conflict (venue_id, master_item_id) do update
       set count_unit     = coalesce(excluded.count_unit, kount_venue_food_items.count_unit),
           units_per_case = coalesce(excluded.units_per_case, kount_venue_food_items.units_per_case),
           sheet_category = coalesce(excluded.sheet_category, kount_venue_food_items.sheet_category),
           sort_order     = coalesce(excluded.sort_order, kount_venue_food_items.sort_order),
           updated_at     = now();
  end if;

  return jsonb_build_object(
    'ok',              true,
    'committed',       p_commit,
    'has_counts',      v_has_counts,
    'venue_id',        p_venue_id,
    'venue_name',      v_venue_name,
    'audit_id',        v_audit_id,
    'rows_in_sheet',   (select count(*) from _food_rows),
    'matched',         (select count(*) from _food_resolved where master_item_id is not null),
    'matched_by',      v_how,
    'unmatched',       v_unmatched,
    'masters_created', v_created,
    'rows_with_qty',   (select count(*) from _food_resolved where qty is not null),
    'rows_with_price', (select count(*) from _food_resolved where price is not null),
    'entries_written', v_entries,
    'costs_written',   v_costs,
    'total_value',     round(v_total_value, 2)
  );
end;
$function$;

-- ── pack size from the unit text Little Luck already types ──────────────────
-- "cs (4/1 gal)" -> 4, "cs (12/12 oz)" -> 12, "pk (50 ct)" -> 50, "pk (20 pc)" -> 20. "bag (25 lb)" is a SIZE of
-- one bag, not a count of units, so it is left alone (as is anything already filled in).
update public.kount_venue_food_items f
   set units_per_case = coalesce(
         nullif(substring(f.count_unit from '\(\s*(\d+(?:\.\d+)?)\s*/'), '')::numeric,
         nullif(substring(f.count_unit from '\(\s*(\d+(?:\.\d+)?)\s*(?:ct|pc|pcs|count)\s*\)'), '')::numeric),
       updated_at = now()
 where f.units_per_case is null
   and (f.count_unit ~ '\(\s*\d+(\.\d+)?\s*/' or f.count_unit ~ '\(\s*\d+(\.\d+)?\s*(ct|pc|pcs|count)\s*\)');

-- ── verification ─────────────────────────────────────────────────────────────
select public.kount_food_key('Butter, Unsalted') = public.kount_food_key('Unsalted Butter') as butter_same,
       public.kount_food_key('Heavy Cream 40%') as cream,                                   -- 'cream heavy'
       public.kount_food_key('Wagyu Ground Beef, 5lb CVP (Margaret River)') as wagyu,      -- 'beef cvp ground wagyu'
       public.kount_food_key('Avocado, Hass 20/24') as avocado,                             -- 'avocado hass'
       public.kount_food_key('Eggs, Large') as eggs,                                        -- 'egg large'
       public.kount_food_key('Tomatoes & Potatoes') as plurals,                             -- 'potato tomato'
       (select count(*) from public.kount_venue_food_items where units_per_case is not null) as packs_filled;
-- expect: true, cream heavy, beef cvp ground wagyu, avocado hass, egg large, potato tomato, > 0

commit;
