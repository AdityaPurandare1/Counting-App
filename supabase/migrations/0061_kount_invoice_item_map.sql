-- =============================================================================
--  0061_kount_invoice_item_map
--
--  Let a venue's invoices keep its costs current, even when the invoice feed
--  names products differently from the catalog items the bar counts.
--
--  WHY (measured 2026-10-07 on Alphabet, v12)
--  Of 346 beverage invoice lines Alphabet received through R365, 296 name no
--  product (R365 "Missing Vendor Item" placeholders or no item at all — AP
--  coding), and of the 25 real products the other 50 lines name, 24 are linked
--  to a SHADOW catalog item named after the vendor description ("KETEL ONE
--  VODKA 80 (BPC: 12, SIZE: 1L)") rather than the item the bar counts
--  ("Ketel One 1L"). R365 lines also carry no case size, and the same vendor
--  bills per CASE on one line ($333 Ketel One /12) and per BOTTLE on another
--  ($34.60 Maker's Mark). 0060's job could therefore price almost nothing for
--  Alphabet, and what it priced it would put on the wrong item.
--
--  WHAT
--  1. kount_invoice_item_map(venue, purchase_item, master, units_per_case):
--     "when this venue is invoiced for THIS vendor item, it is THAT counted
--     item, and the case holds N of the counted unit". Venue-scoped, so a
--     mapping can never re-point another venue's purchases, and it does NOT
--     touch purchase_items.master_item_id (re-pointing that would feed case
--     prices into the shared catalog cost — the Disaronno bug).
--  2. price_date on kount_venue_cost_overrides: the date the price is TRUE
--     AS OF (the invoice date, or the date of the sheet it came from), so
--     "is this invoice newer than what we have?" compares like with like
--     instead of comparing an invoice date with the day someone typed it in.
--  3. kount_refresh_venue_invoice_costs v2:
--       · line → counted item via the map first, else the existing link,
--         and only for items the venue has counted, mapped or priced
--         (no rows on shadow items);
--       · per-unit price chosen between "line ÷ pack" and "line as-is" by
--         whichever lands within 2.5x of the venue's current cost (else the
--         catalog cost); neither, or no reference and no pack → 'review';
--       · a newer invoice REPLACES the venue's price; with
--         p_invoice_beats_manual = true that includes hand-entered prices
--         (Alphabet's sheets), otherwise manual rows are left alone (Poppy's
--         catalog-error pins).
--
--  REVERSIBLE: drop table kount_invoice_item_map; re-run 0060 to restore the
--  v1 function; alter table kount_venue_cost_overrides drop column price_date.
-- =============================================================================

create table if not exists public.kount_invoice_item_map (
  venue_id          text        not null references public.kount_venues(id)   on delete cascade,
  purchase_item_id  uuid        not null references public.purchase_items(id) on delete cascade,
  master_item_id    uuid        not null references public.master_items(id)   on delete cascade,
  -- How many of the COUNTED unit one invoiced case holds (12 bottles; 24 cans;
  -- 0.48 when 48 tea bags feed a 100-count box). Null = use the line's own
  -- case size, or the "BPC: n" in its description.
  units_per_case    numeric     check (units_per_case is null or units_per_case > 0),
  note              text,
  set_by            text,
  updated_at        timestamptz not null default now(),
  primary key (venue_id, purchase_item_id, master_item_id)
);
comment on table public.kount_invoice_item_map is
  'Venue-scoped: which counted catalog item (and pack size) a vendor invoice item represents. Read by kount_refresh_venue_invoice_costs.';

alter table public.kount_invoice_item_map enable row level security;
drop policy if exists kount_invoice_item_map_select on public.kount_invoice_item_map;
create policy kount_invoice_item_map_select on public.kount_invoice_item_map
  for select to authenticated
  using (public.kount_is_corporate() or public.kount_can_see_venue(venue_id));
revoke all on public.kount_invoice_item_map from anon, public;
grant select on public.kount_invoice_item_map to authenticated;
grant all on public.kount_invoice_item_map to service_role;

alter table public.kount_venue_cost_overrides add column if not exists price_date date;
comment on column public.kount_venue_cost_overrides.price_date is
  'Date the price is true as of (invoice date, or the date of the sheet it came from). Newer invoices replace older prices.';

-- Backfill what we know. Sheet dates: the liquor/NA "Batch Costed" tracker is
-- 8/28/26; the wine inventory is titled WINE INVENTORY_092726; the wine
-- master opening list carries no date (its rows were all superseded on
-- 2026-10-07 by the 9/27 inventory). Auto rows carry their invoice date in
-- their source text.
update public.kount_venue_cost_overrides set price_date = date '2026-08-28'
  where price_date is null and source like 'Alphabet Batch Costed sheet%';
update public.kount_venue_cost_overrides set price_date = date '2026-09-27'
  where price_date is null and source like 'ALPHABET_Wine Inventory_082426%';
update public.kount_venue_cost_overrides set price_date = date '2026-08-15'
  where price_date is null and source like 'ALPHABET_Wine List MASTER_OPENING%';
update public.kount_venue_cost_overrides
  set price_date = (regexp_match(source, ' (\d{4}-\d{2}-\d{2}):'))[1]::date
  where price_date is null and not is_manual and source ~ ' \d{4}-\d{2}-\d{2}:';
update public.kount_venue_cost_overrides set price_date = updated_at::date where price_date is null;

drop function if exists public.kount_refresh_venue_invoice_costs(text, int, boolean);

create or replace function public.kount_refresh_venue_invoice_costs(
  p_venue_id              text,
  p_days                  int     default 120,
  p_apply                 boolean default false,
  p_invoice_beats_manual  boolean default false
)
returns table (
  master_item_id uuid,
  item           text,
  invoice_date   date,
  invoice_number text,
  vendor         text,
  line_cost      numeric,
  pack           numeric,
  unit_cost      numeric,
  basis          text,
  reference      numeric,
  current_cost   numeric,
  current_date_  date,
  status         text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_ops uuid;
begin
  select kv.ops_venue_id into v_ops from kount_venues kv where kv.id = p_venue_id;
  if v_ops is null then
    raise exception 'kount venue % has no ops_venue_id (see migration 0056)', p_venue_id;
  end if;

  create temp table _kvic on commit drop as
  with raw as (
    select l.id as line_id, l.item_id, l.unit_cost, l.cu_qty, l.created_at,
           coalesce(l.description, p.name) as descr,
           coalesce(l.master_item_id, p.master_item_id) as linked_mid,
           i.invoice_date, i.invoice_number, v.name as vendor
    from invoice_lines l
    join invoices i on i.id = l.invoice_id
    left join purchase_items p on p.id = l.item_id
    left join vendors v on v.id = i.vendor_id
    where i.venue_id = v_ops
      and i.invoice_date >= current_date - p_days
      and l.unit_cost > 0
      and not coalesce(l.is_ignored, false)
  ),
  -- A mapped vendor item feeds every counted item it is mapped to; an
  -- unmapped one falls back to its own link.
  routed as (
    select r.*, mp.master_item_id as mid, mp.units_per_case as map_pack, true as mapped
    from raw r join kount_invoice_item_map mp on mp.venue_id = p_venue_id and mp.purchase_item_id = r.item_id
    union all
    select r.*, r.linked_mid, null::numeric, false
    from raw r
    where r.linked_mid is not null
      and not exists (select 1 from kount_invoice_item_map mp where mp.venue_id = p_venue_id and mp.purchase_item_id = r.item_id)
  ),
  newest as (
    select *, row_number() over (partition by mid order by invoice_date desc, created_at desc nulls last, line_id desc) as rn
    from routed
  ),
  cat as (
    select distinct on (pi.master_item_id) pi.master_item_id, pi.avg_cost
    from purchase_items pi where pi.avg_cost > 0
    order by pi.master_item_id, pi.updated_at desc nulls last, pi.id desc
  ),
  priced as (
    select n.*, m.name,
           coalesce(n.map_pack, n.cu_qty, (regexp_match(n.descr, 'BPC:\s*(\d+)'))[1]::numeric) as pk,
           o.cost_per_unit as cur, o.is_manual as cur_manual,
           coalesce(o.price_date, o.updated_at::date) as cur_date,
           coalesce(o.cost_per_unit, c.avg_cost) as ref
    from newest n
    join master_items m on m.id = n.mid and m.category ~* 'liquor|wine|beer|beverage|consumable'
    left join cat c on c.master_item_id = n.mid
    left join kount_venue_cost_overrides o on o.venue_id = p_venue_id and o.master_item_id = n.mid
    where n.rn = 1
      -- Only items this venue actually deals in: mapped, already priced for
      -- it, or counted there. Keeps rows off the shadow items.
      and (n.mapped or o.master_item_id is not null
           or exists (select 1 from kount_entries e join kount_audits a on a.id = e.audit_id
                      where a.venue_id = p_venue_id and e.master_item_id = n.mid))
  ),
  chosen as (
    select p.*,
           case when p.pk > 0 and p.pk <> 1 then round((p.unit_cost / p.pk)::numeric, 4) end as per_case,
           round(p.unit_cost::numeric, 4) as per_line,
           (p.pk > 0 and p.pk <> 1 and p.ref > 0 and p.unit_cost / p.pk between p.ref / 2.5 and p.ref * 2.5) as case_ok,
           (p.ref > 0 and p.unit_cost between p.ref / 2.5 and p.ref * 2.5) as line_ok
    from priced p
  )
  select c.mid, c.name as item, c.invoice_date, c.invoice_number, c.vendor, c.unit_cost as line_cost, c.pk as pack,
         case when c.case_ok then c.per_case
              when c.line_ok then c.per_line
              when c.ref is null and c.pk > 0 and c.pk <> 1 then c.per_case
              when c.ref is null and c.pk = 1 then c.per_line end as per_unit,
         case when c.case_ok then 'line / pack ' || c.pk
              when c.line_ok then 'line is per unit'
              when c.ref is null and c.pk > 0 and c.pk <> 1 then 'line / pack ' || c.pk || ' (no reference)'
              when c.ref is null and c.pk = 1 then 'line is per unit (pack 1, no reference)' end as basis,
         c.ref, c.cur, c.cur_date,
         case
           when not c.case_ok and not c.line_ok and c.ref is not null then 'review: neither line nor line/pack within 2.5x of current'
           when c.ref is null and (c.pk is null or c.pk <= 0) then 'review: no reference cost and no pack size'
           when c.cur_manual and not p_invoice_beats_manual then 'skip: manual price kept'
           when c.cur is not null and c.invoice_date <= c.cur_date then 'skip: price on file is as new or newer'
           when c.cur is null then 'ok: new'
           else 'ok: newer invoice'
         end as status
  from chosen c;

  if p_apply then
    insert into kount_venue_cost_overrides (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
    select p_venue_id, k.mid, k.per_unit,
           format('%s invoice #%s %s: $%s, %s = $%s (auto)', k.vendor, k.invoice_number, k.invoice_date, k.line_cost, k.basis, k.per_unit),
           'kount_refresh_venue_invoice_costs', false, k.invoice_date, now()
    from _kvic k
    where k.status like 'ok%' and k.per_unit > 0
    on conflict (venue_id, master_item_id) do update
      set cost_per_unit = excluded.cost_per_unit, source = excluded.source, set_by = excluded.set_by,
          is_manual = false, price_date = excluded.price_date, updated_at = now();
  end if;

  return query
  select k.mid, k.item, k.invoice_date, k.invoice_number, k.vendor, k.line_cost, k.pack, k.per_unit, k.basis,
         k.ref, k.cur, k.cur_date, k.status
  from _kvic k
  order by k.status, k.item;
end $$;

revoke all on function public.kount_refresh_venue_invoice_costs(text, int, boolean, boolean) from public, anon, authenticated;

select
  (select count(*) from pg_class where relname = 'kount_invoice_item_map') as map_table,
  (select count(*) from information_schema.columns where table_name = 'kount_venue_cost_overrides' and column_name = 'price_date') as has_price_date,
  (select count(*) from public.kount_venue_cost_overrides where price_date is null) as undated_rows,
  (select count(*) from pg_proc where proname = 'kount_refresh_venue_invoice_costs') as fn_versions;
