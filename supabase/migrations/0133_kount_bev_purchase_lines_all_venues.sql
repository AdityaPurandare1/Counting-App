-- =============================================================================
--  0133_kount_bev_purchase_lines_all_venues   (FUNCTION, read-only)
--
--  Replaces 0107's kount_bev_purchase_lines (same signature, same jsonb row
--  shape) for the admin "Liquor & wine prices" tab (Counting-Admin v0.79):
--
--  1. ALL h.wood venues. 0107 read only KevaOS venues linked to a counting
--     venue, so Bird Streets Club ($996k over 24 months), Nice Guy LA ($772k),
--     Delilah Dallas ($611k) and Catering never appeared. Every KevaOS venue of
--     The h.wood Group organization is read now; a venue linked to a counting
--     venue keeps that id and name ('v1', 'Delilah LA'), the others use their
--     KevaOS id and name. Other KevaOS tenants' venues are excluded.
--
--  2. Liquor + wine that is not itemized. Lines with no item and no beverage GL
--     (gl_code empty or a 1xxx balance-sheet account -- Lady Delilah's opening
--     orders were booked to Construction in Progress, one line per invoice) are
--     classed by their vendor (kount_bev_vendor_class, refreshed nightly by
--     kount_refresh_bev_vendor_class) and returned with category 'Mixed' and
--     route 'vendor': spend only, no item, no price per bottle. ~$660k over 24
--     months (Dallas, Lady Delilah, Alphabet).
--
--  3. Speed: every venue triples the lines read, so clearly non-beverage lines
--     (another category's item, a food / expense GL) are dropped first.
--
--  Everything else -- the gate, routing, pack hints, references, dup_of -- is
--  0107 unchanged.
--  ROLLBACK: 0133_ROLLBACK_kount_bev_purchase_lines_all_venues.sql (= 0107's function).
-- =============================================================================
begin;

-- ── which vendors' unitemized lines are liquor + wine ───────────────────────
create table if not exists public.kount_bev_vendor_class (
  vendor_id     uuid primary key,
  vendor_name   text,
  vcat          text check (vcat is null or vcat = 'Mixed'),
  bev_spend     numeric,   -- itemized liquor + wine at h.wood, last 3 years
  total_spend   numeric,   -- all itemized / 5xxx-coded spend, last 3 years
  basis         text,
  refreshed_at  timestamptz not null default now()
);
alter table public.kount_bev_vendor_class enable row level security;
revoke all on table public.kount_bev_vendor_class from public, anon, authenticated;
grant select on table public.kount_bev_vendor_class to authenticated;
drop policy if exists kount_bev_vendor_class_read on public.kount_bev_vendor_class;
create policy kount_bev_vendor_class_read on public.kount_bev_vendor_class
  for select to authenticated using (public.kount_is_corporate() is true);

-- A vendor that sold unitemized lines (no item; GL empty or 1xxx) in the last
-- three years is 'Mixed' (liquor + wine, not split) when its itemized purchases
-- at h.wood over the same years are >= 75% liquor + wine with >= $2k of history,
-- or -- with no history -- its name says so. Names of non-suppliers that
-- history or a word would catch (cellar DESIGN, a clothing vendor mis-mapped to
-- wine, movers, rentals, the alcohol COMMISSION) are excluded.
create or replace function public.kount_refresh_bev_vendor_class()
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  n integer;
begin
  -- the nightly cron runs as postgres; anyone else must be admin / corporate
  if session_user <> 'postgres' and public.kount_is_corporate() is not true then
    raise exception 'kount_refresh_bev_vendor_class: admin and corporate only' using errcode = '42501';
  end if;

  with hw as (
    select v.id from venues v where v.organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
  ),
  cand as (
    select distinct i.vendor_id
    from invoices i
    join hw on hw.id = i.venue_id
    join invoice_lines l on l.invoice_id = i.id
    left join purchase_items p on p.id = l.item_id
    left join master_items m on m.id = coalesce(l.master_item_id, p.master_item_id)
    where i.invoice_date >= current_date - 1095 and i.vendor_id is not null
      and not coalesce(l.is_ignored, false)
      and m.category is null and (l.gl_code is null or l.gl_code ~ '^1')
  ),
  vhist as (
    select i.vendor_id,
           sum(l.line_total) filter (where lower(m.category) in ('liquor cost', 'liquor', 'wine cost', 'wine')
                                        or (m.category is null and left(l.gl_code, 4) in ('5310', '5320'))) as bev,
           sum(l.line_total) as tot
    from invoices i
    join hw on hw.id = i.venue_id
    join invoice_lines l on l.invoice_id = i.id
    left join purchase_items p on p.id = l.item_id
    left join master_items m on m.id = coalesce(l.master_item_id, p.master_item_id)
    where i.vendor_id in (select vendor_id from cand)
      and i.invoice_date >= current_date - 1095
      and not coalesce(l.is_ignored, false)
      and (m.category is not null or l.gl_code ~ '^5')
    group by i.vendor_id
  ),
  cls as (
    select vd.id as vendor_id, vd.name as vendor_name, h.bev, h.tot,
           case
             when vd.name ~* '(design|construct|clothing|uniform|moving|rental|commission|tax board|payroll|furniture|equipment|printing)' then null
             when coalesce(h.tot, 0) >= 2000 and h.bev / nullif(h.tot, 0) >= 0.75 then 'Mixed'
             when coalesce(h.tot, 0) < 2000
              and vd.name ~* '(\mwines?\M|vineyard|winery|vinicole|\mvins?\M|cellars\M|spirits|liquor|glazer|breakthru|empire merchants|republic national|johnson brothers|winebow|skurnik|martignetti)'
               then 'Mixed'
           end as vcat,
           case
             when vd.name ~* '(design|construct|clothing|uniform|moving|rental|commission|tax board|payroll|furniture|equipment|printing)' then 'excluded by name'
             when coalesce(h.tot, 0) >= 2000 then 'history: ' || round(100 * coalesce(h.bev, 0) / nullif(h.tot, 0)) || '% liquor + wine of $' || round(h.tot)
             else 'name (no itemized history)'
           end as basis
    from vendors vd
    left join vhist h on h.vendor_id = vd.id
    where vd.id in (select vendor_id from cand)
  )
  insert into public.kount_bev_vendor_class as k (vendor_id, vendor_name, vcat, bev_spend, total_spend, basis, refreshed_at)
  select c.vendor_id, c.vendor_name, c.vcat, round(c.bev, 2), round(c.tot, 2), c.basis, now() from cls c
  on conflict (vendor_id) do update
    set vendor_name = excluded.vendor_name, vcat = excluded.vcat, bev_spend = excluded.bev_spend,
        total_spend = excluded.total_spend, basis = excluded.basis, refreshed_at = excluded.refreshed_at;

  -- vendors no longer selling unitemized lines drop out (not touched by this run)
  delete from public.kount_bev_vendor_class where refreshed_at < now();
  select count(*) into n from public.kount_bev_vendor_class where vcat is not null;
  return n;
end
$fn$;
-- not callable from the app: the nightly job (postgres) runs it; an app call would only burn
-- ~18 s of shared database time and then hit the 8 s statement timeout
revoke all on function public.kount_refresh_bev_vendor_class() from public, anon, authenticated;

select public.kount_refresh_bev_vendor_class();

-- nightly, after job 20 (11:30 UTC) has placed the night's invoice lines
select cron.schedule('kount-bev-vendor-class-nightly', '45 11 * * *', 'select public.kount_refresh_bev_vendor_class()');

create or replace function public.kount_bev_purchase_lines(p_from date, p_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_out jsonb;
begin
  -- `is not true`, not `not`: a NULL from the helper must refuse, not fall through.
  if public.kount_is_corporate() is not true then
    raise exception 'Purchase prices are limited to admin and corporate users' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'kount_bev_purchase_lines: invalid date range % to %', p_from, p_to;
  end if;
  if p_to - p_from > 1100 then
    raise exception 'kount_bev_purchase_lines: range longer than 3 years';
  end if;

  with hw as (
    -- 0133: EVERY h.wood KevaOS venue, not only the counting ones (Bird Streets,
    -- Nice Guy, Delilah Dallas, Catering had ~$2.4M of liquor + wine invisible).
    -- Scoped to the h.wood organization: KevaOS hosts other tenants' venues.
    select v.id as ops_id, v.name as ops_name
    from venues v where v.organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
  ),
  kvm as (
    -- one counting venue per KevaOS venue: ops_venue_id is not unique-constrained,
    -- and two rows sharing one would return (and count) every invoice line twice
    select distinct on (k.ops_venue_id) k.id, k.name, k.ops_venue_id
    from kount_venues k where k.ops_venue_id is not null
    order by k.ops_venue_id, k.is_active desc, k.ordinal nulls last, k.id
  ),
  kv as (
    -- the counting venue when one is linked (its id 'v1'... and name), else the KevaOS venue itself
    select coalesce(kvm.id, hw.ops_id::text) as id, coalesce(kvm.name, hw.ops_name) as name, hw.ops_id as ops_venue_id
    from hw left join kvm on kvm.ops_venue_id = hw.ops_id
  ),
  inv as (
    select i.id, i.invoice_number, i.invoice_date, i.vendor_id, i.venue_id, i.total_amount,
           i.external_source, coalesce(i.is_credit, false) as is_credit, kv.id as kv_id, kv.name as kv_name
    from invoices i
    join kv on kv.ops_venue_id = i.venue_id
    where i.invoice_date between p_from and p_to
  ),
  raw as (
    select l.id as line_id, l.invoice_id, l.description, l.qty, l.unit_cost, l.line_total, l.gl_code, l.cu_qty,
           l.item_id, coalesce(l.master_item_id, p.master_item_id) as linked_mid, p.name as pi_name,
           inv.invoice_number, inv.invoice_date, inv.vendor_id, inv.venue_id, inv.total_amount,
           inv.external_source, inv.is_credit, inv.kv_id, inv.kv_name
    from inv
    join invoice_lines l on l.invoice_id = inv.id
    left join purchase_items p on p.id = l.item_id
    left join master_items ml on ml.id = coalesce(l.master_item_id, p.master_item_id)
    -- routing below follows merged_into_id, so the filter judges the KEEPER's category
    left join master_items mk on mk.id = ml.merged_into_id
    where not coalesce(l.is_ignored, false)
      -- 0133: drop clearly non-beverage lines first (most of the volume once every
      -- venue is read). Kept: a liquor / wine item; no item with a beverage, empty
      -- or balance-sheet GL; anything a venue map could re-route to another item.
      and (lower(case when ml.merged_into_id is not null then mk.category else ml.category end) in ('liquor cost', 'liquor', 'wine cost', 'wine')
           or ((case when ml.merged_into_id is not null then mk.category else ml.category end) is null
               and (l.gl_code is null or l.gl_code ~ '^1' or left(l.gl_code, 4) in ('5310', '5320')))
           or exists (select 1 from kount_invoice_line_map x where x.invoice_line_id = l.id)
           or (l.item_id is not null and exists (select 1 from kount_invoice_item_map y where y.purchase_item_id = l.item_id)))
  ),
  -- the two map tables are small: aggregate once and hash-join (a per-line
  -- lateral lookup over ~50k lines cost most of the 8s statement budget)
  lm_agg as (
    select x.venue_id, x.invoice_line_id, count(*) as n, min(x.master_item_id::text)::uuid as mid, min(x.units) as units,
           -- a split line (0072 opening lumps) has no single item, but when every item it
           -- was split across is wine (or all liquor) it still counts in that category's spend
           count(distinct case when lower(m.category) in ('liquor cost', 'liquor') then 'Liquor'
                               when lower(m.category) in ('wine cost', 'wine') then 'Wine' else 'Other' end) as ncat,
           min(case when lower(m.category) in ('liquor cost', 'liquor') then 'Liquor'
                    when lower(m.category) in ('wine cost', 'wine') then 'Wine' else 'Other' end) as split_cat
    from kount_invoice_line_map x
    left join master_items m on m.id = x.master_item_id
    group by x.venue_id, x.invoice_line_id
  ),
  im_agg as (
    select y.venue_id, y.purchase_item_id, count(*) as n, min(y.master_item_id::text)::uuid as mid, min(y.units_per_case) as upc
    from kount_invoice_item_map y group by y.venue_id, y.purchase_item_id
  ),
  routed as (
    select r.*,
           case when lm.n = 1 and r.qty > 0 then lm.mid
                when lm.n > 1 then null            -- split across items: spend only, no item
                when lm.n = 1 then r.linked_mid
                when im.n = 1 then im.mid
                else r.linked_mid end as routed_mid,
           case when lm.n > 1 and lm.ncat = 1 and lm.split_cat <> 'Other' then lm.split_cat end as split_cat,
           case when lm.n = 1 and r.qty > 0 then round(lm.units / r.qty, 4)
                when lm.n is null and im.n = 1 then im.upc end as map_pack,
           case when lm.n = 1 and r.qty > 0 then 'line_map'
                when lm.n > 1 then 'split_line'
                when lm.n is null and im.n = 1 then 'item_map'
                else 'linked' end as route
    from raw r
    left join lm_agg lm on lm.venue_id = r.kv_id and lm.invoice_line_id = r.line_id
    left join im_agg im on im.venue_id = r.kv_id and im.purchase_item_id = r.item_id
  ),
  itemed as (
    select r.*, m.id as mid, m.name as item_name, m.category as item_category, m.base_size, m.base_unit
    from routed r
    left join master_items m0 on m0.id = r.routed_mid
    left join master_items m on m.id = coalesce(m0.merged_into_id, m0.id)
  ),
  -- 0133: lines with NO item and NO beverage GL -- an opening order booked to
  -- "Construction in Progress" as one line per invoice, an uncoded R365 line --
  -- are classed by their VENDOR through kount_bev_vendor_class (rules on its
  -- refresh function below; computing the vendor histories inline cost ~10 s of
  -- the 8 s statement budget, so it is refreshed nightly instead).
  vclass as (
    select c.vendor_id, c.vcat from kount_bev_vendor_class c where c.vcat is not null
  ),
  bev as (
    select t.*,
           coalesce(t.item_category is null and t.split_cat is null and (t.gl_code is null or t.gl_code ~ '^1')
                    and vc.vcat is not null and not (coalesce(t.description, '') ~* t.nonbev_re), false) as vendor_based,
           case when lower(t.item_category) in ('liquor cost', 'liquor') then 'Liquor'
                when lower(t.item_category) in ('wine cost', 'wine') then 'Wine'
                when t.item_category is null and t.split_cat is not null then t.split_cat
                when t.item_category is null and left(t.gl_code, 4) = '5310' then 'Liquor'
                when t.item_category is null and left(t.gl_code, 4) = '5320' then 'Wine'
                when t.item_category is null and (t.gl_code is null or t.gl_code ~ '^1')
                     and not (coalesce(t.description, '') ~* t.nonbev_re) then vc.vcat
           end as cat
    from (select it.*,
                 -- deposits, freight, fuel, delivery and tax lines of a beverage vendor are not liquor or wine
                 '(deposit|freight|fuel|delivery|shipping|surcharge|\mtax|\mcrv\M|\mkegs?\M)'::text as nonbev_re
          from itemed it) t
    left join vclass vc on vc.vendor_id = t.vendor_id
  ),
  lines as (
    select * from bev where cat is not null
  ),
  dup as (
    select d.id,
           (select t.invoice_number
              from invoices t
             where t.id <> d.id
               and t.venue_id = d.venue_id
               and t.vendor_id is not distinct from d.vendor_id
               and coalesce(t.external_source, '') not ilike 'manual%'
               -- a hand-entered CREDIT is never a copy of an upstream invoice (totals are
               -- always >= 0, so a full-amount credit memo has the invoice's exact total)
               and coalesce(t.is_credit, false) = d.is_credit
               and (t.invoice_number = regexp_replace(d.invoice_number, '-BRIDGE$', '', 'i')
                    or (coalesce(d.total_amount, 0) <> 0
                        and abs(coalesce(t.total_amount, 0) - d.total_amount) < 0.01
                        and abs(t.invoice_date - d.invoice_date) <= 3))
               and exists (select 1 from invoice_lines tl where tl.invoice_id = t.id and not coalesce(tl.is_ignored, false))
             order by abs(t.invoice_date - d.invoice_date), t.invoice_number
             limit 1) as dup_of
    from (select distinct l.invoice_id as id, l.venue_id, l.vendor_id, l.invoice_number, l.invoice_date, l.total_amount, l.is_credit
            from lines l where l.external_source ilike 'manual%') d
  ),
  mids as (select distinct mid from lines where mid is not null),
  cat_cost as (
    select distinct on (pi.master_item_id) pi.master_item_id, pi.avg_cost
    from purchase_items pi
    join mids on mids.mid = pi.master_item_id
    where pi.avg_cost > 0
    order by pi.master_item_id, pi.updated_at desc nulls last, pi.id desc
  ),
  venue_cost as (
    select o.venue_id, o.master_item_id, o.cost_per_unit
    from kount_venue_cost_overrides o join mids on mids.mid = o.master_item_id
    where o.cost_per_unit > 0
  ),
  -- the same product's cost at the OTHER venues (median), per venue
  sister as (
    select k.id as venue_id, o.master_item_id,
           percentile_cont(0.5) within group (order by o.cost_per_unit)::numeric as med
    from kv k join venue_cost o on o.venue_id <> k.id
    group by k.id, o.master_item_id
  ),
  res as (
    select l.*,
           d.dup_of,
           vc.cost_per_unit as ref_venue,
           s.med as ref_sister,
           cc.avg_cost as ref_catalog,
           (regexp_match(coalesce(l.description, ''), 'BPC:\s*(\d+)'))[1]::numeric as bpc,
           -- 0093's description-pack patterns, most specific first, plus one.
           coalesce(
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\((\d{1,2})\s*(?:btl|bottle)', 'i'))[1],
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\m(\d{1,2})\s*x\s*\d+(?:\.\d+)?\s*(?:ml|l|cl|oz|z)?\M', 'i'))[1],
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\m(\d{1,2})\s*/\s*\d{3,4}\s*(?:ml|l)?\M', 'i'))[1],
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\m1/(\d{1,2})/\d', 'i'))[1],
             -- 0107 addition: distributor format "Duckhorn Merlot 1/12 750 ml", "Casamigos 1/6 1 ltr"
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\m1/(\d{1,2})\s+\d+(?:\.\d+)?\s*(?:ml|l|ltr|lt)\M', 'i'))[1],
             (regexp_match(coalesce(l.description, l.pi_name, ''), '(?:ml|l)\s*[/-]\s*(\d{1,2})\M', 'i'))[1],
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\m(\d{1,2})\s*(?:pack|pk|b|p)\M', 'i'))[1],
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\mc(\d{2})\M', 'i'))[1],
             (regexp_match(coalesce(l.description, l.pi_name, ''), '\m(\d{1,2})\s*bottles\M', 'i'))[1]
           )::numeric as dpk,
           case lower(coalesce(l.base_unit, ''))
             when 'ml' then l.base_size / 1000.0
             when 'l' then l.base_size
             when 'cl' then l.base_size / 100.0
             when 'floz' then l.base_size * 0.0295735
             when 'oz' then l.base_size * 0.0295735
             else (select case lower(x[2]) when 'ml' then x[1]::numeric / 1000.0 when 'cl' then x[1]::numeric / 100.0
                                           when 'l' then x[1]::numeric else x[1]::numeric * 0.0295735 end
                     from regexp_match(coalesce(l.item_name, ''), '(\d+(?:\.\d+)?)\s*(ml|cl|l|fl\.?\s*oz|oz)\M', 'i') x)
           end as liters
    from lines l
    left join dup d on d.id = l.invoice_id
    left join venue_cost vc on vc.venue_id = l.kv_id and vc.master_item_id = l.mid
    left join sister s on s.venue_id = l.kv_id and s.master_item_id = l.mid
    left join cat_cost cc on cc.master_item_id = l.mid
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'line_id', o.line_id,
           'invoice_id', o.invoice_id,
           'invoice_number', o.invoice_number,
           'invoice_date', o.invoice_date,
           'is_credit', o.is_credit,
           'dup_of', o.dup_of,
           'venue_id', o.kv_id,
           'venue_name', o.kv_name,
           'vendor_id', o.vendor_id,
           'vendor_name', vd.name,
           'item_id', case when o.vendor_based then null else o.mid end,
           'item_name', o.item_name,
           'category', o.cat,
           'route', case when o.vendor_based then 'vendor' else o.route end,
           'description', left(o.description, 90),
           'qty', o.qty,
           'unit_cost', o.unit_cost,
           'line_total', o.line_total,
           'gl_code', o.gl_code,
           'cu_qty', o.cu_qty,
           'map_pack', o.map_pack,
           'bpc', o.bpc,
           'dpk', o.dpk,
           'liters', round(o.liters, 4),
           'ref_venue', round(o.ref_venue, 4),
           'ref_sister', round(o.ref_sister, 4),
           'ref_catalog', round(o.ref_catalog, 4)
         )) order by o.invoice_date, o.invoice_number, o.line_id), '[]'::jsonb)
    into v_out
  from res o
  left join vendors vd on vd.id = o.vendor_id;

  return v_out;
end
$fn$;

revoke all on function public.kount_bev_purchase_lines(date, date) from public;
revoke all on function public.kount_bev_purchase_lines(date, date) from anon;
grant execute on function public.kount_bev_purchase_lines(date, date) to authenticated;

comment on function public.kount_bev_purchase_lines(date, date) is
  'Liquor + wine invoice lines for every h.wood venue, with pack hints, reference costs and vendor-classified unitemized lines (0133). Admin/corporate only. Read-only.';

commit;
