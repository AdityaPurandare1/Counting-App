-- =============================================================================
--  0107_kount_bev_purchase_lines   (FUNCTION, read-only)
--
--  Feeds the admin "Purchase prices" screen (Counting-Admin v0.74): every
--  liquor and wine invoice line for the counting venues in a date range, with
--  what the screen needs to turn a case price into a price per bottle.
--
--  WHY AN RPC. invoices / invoice_lines / purchase_items are KevaOS tables whose
--  RLS is organization-scoped; Kount users read them only through SECURITY
--  DEFINER functions (same pattern as kount_catalog_prices, 0098). Gated to
--  admin + corporate via kount_is_corporate() -- this is org-wide financial data.
--
--  WHAT EACH LINE CARRIES
--    * The item it is about, routed the way the cost job (0093) routes it:
--      a single kount_invoice_line_map entry, else a single kount_invoice_item_map
--      entry, else the line's own link (invoice_lines.master_item_id, then
--      purchase_items.master_item_id), then through master_items.merged_into_id
--      so merged duplicates share one history. A split line (several line-map
--      rows, e.g. 0072's opening lumps) has no single item: it carries none and
--      counts in spend only, in the category its items share. Ambiguous item
--      maps keep the line's own link.
--    * Liquor vs wine from the item's category (legacy lowercase folded in);
--      GL 5310 / 5320 only when the line has no categorised item. GL alone is
--      not trusted -- 5315 holds garnish and some venues label 5320 "Liquor".
--    * Pack hints, all optional: the map's units (map_pack), Craftable's cu_qty,
--      "BPC: n" in the description (bpc), the pack the description states (dpk,
--      0093's patterns verbatim plus "1/12 750 ml"), and the bottle size in litres.
--    * Reference per-bottle costs for choosing the pack: this venue's cost
--      (kount_venue_cost_overrides), the median at the other venues, and the
--      catalog cost (newest purchase_items.avg_cost) -- 0093's three references.
--    * dup_of: a hand-entered copy ('manual%' source) of an invoice that also
--      came in from upstream with lines -- same venue and vendor, and either the
--      number minus "-BRIDGE" or the same total within 3 days, and the same
--      credit flag (a hand-entered credit memo has its invoice's exact total).
--      Poppy has five (Jun-Jul 2026, ~$18k); the screen leaves them out.
--    * kount_venues is read DISTINCT ON ops_venue_id: two counting venues
--      sharing a KevaOS venue would otherwise return every line twice.
--
--  Returns ONE jsonb array (not SETOF) so PostgREST's 1000-row cap cannot
--  silently truncate it. Range capped at 3 years.
--
--  ROLLBACK: 0107_ROLLBACK_kount_bev_purchase_lines.sql (drops the function).
-- =============================================================================
begin;

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

  with kv as (
    -- one counting venue per KevaOS venue: ops_venue_id is not unique-constrained,
    -- and two rows sharing one would return (and count) every invoice line twice
    select distinct on (k.ops_venue_id) k.id, k.name, k.ops_venue_id
    from kount_venues k where k.ops_venue_id is not null
    order by k.ops_venue_id, k.is_active desc, k.ordinal nulls last, k.id
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
    where not coalesce(l.is_ignored, false)
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
  bev as (
    select t.*,
           case when lower(t.item_category) in ('liquor cost', 'liquor') then 'Liquor'
                when lower(t.item_category) in ('wine cost', 'wine') then 'Wine'
                when t.item_category is null and t.split_cat is not null then t.split_cat
                when t.item_category is null and left(t.gl_code, 4) = '5310' then 'Liquor'
                when t.item_category is null and left(t.gl_code, 4) = '5320' then 'Wine'
           end as cat
    from itemed t
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
           'item_id', o.mid,
           'item_name', o.item_name,
           'category', o.cat,
           'route', o.route,
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
  'Liquor + wine invoice lines for the counting venues, with pack hints and reference costs (0107). Admin/corporate only. Read-only.';

commit;

-- -----------------------------------------------------------------------------
--  VERIFY (run after applying; as a corporate/admin JWT inside a rolled-back txn)
-- -----------------------------------------------------------------------------
-- begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', '{"sub":"<auth uid>","email":"<admin email>","role":"authenticated"}', true);
--   with j as (select public.kount_bev_purchase_lines(current_date - 365, current_date) j)
--   select jsonb_array_length(j) as lines,
--          (select count(distinct e->>'line_id') from jsonb_array_elements(j) e) as distinct_lines  -- must equal lines
--   from j;
-- rollback;
-- select ops_venue_id, count(*) from kount_venues where ops_venue_id is not null group by 1 having count(*) > 1;  -- expect 0 rows
