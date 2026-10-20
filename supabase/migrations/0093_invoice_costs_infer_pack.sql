-- =============================================================================
--  0093_invoice_costs_infer_pack   (FUNCTION)
--
--  kount_refresh_venue_invoice_costs (nightly job 20) turns a venue's invoice
--  lines into per-bottle costs. At Little Luck it priced almost nothing: of 325
--  products counted in LL-038, 157 had no cost at all, 73 of them on Little
--  Luck's own invoices. Two causes, both fixed here:
--
--  1. PACK SIZE UNKNOWN. LL's R365 lines are case prices with no pack field
--     (Carpano Antica 1L $192.60 = a 6-pack). With no pack and no reference
--     cost the function only said "review" -- a list nobody sees.
--     Now, when the pack is unknown, the candidates are: the pack the
--     DESCRIPTION states ("6/1800ml", "12X750", "1/24/12", "6B", "C24",
--     "700mL/6", "(3 btl.)", "24 bottles"), 1 (the line is per bottle), 6, 12, 24.
--       * With a reference cost -- this venue's cost, else the MEDIAN of the same
--         product's cost at the other venues (new), else the catalog average --
--         the description's pack is used if it lands within 2x of it (a stated
--         pack is strong evidence; a sister venue's price is weaker), unless
--         another candidate lands within 1.5x and closer. Otherwise the
--         candidate closest to the reference wins, if it is within 1.5x and no
--         other candidate also is; else review.
--       * With no reference, the description's pack is used only if the
--         resulting price per litre is plausible for the category (spirits /
--         wine / sake $6-$1500/L; beer / N/A $0.80-$60/L); if it is not but the
--         line price itself is, the line is per bottle (Genepi "12X700" at $25,
--         qty 6). Anything else stays in review.
--     A known pack (item map / line map / cu_qty / BPC) still wins and is
--     checked exactly as before.
--
--  2. THREE-VALUED-LOGIC BUG. With no pack, case_ok was NULL, so
--     `not case_ok and not line_ok` was NULL and the CASE fell through to
--     'ok: new' -- with per_unit NULL, which the apply step then silently
--     skipped. 16 LL lines (Aperol, Belvedere, Ketel One, Campari...) were
--     labelled ok every night and never saved. Booleans are now coalesced and
--     a row with no per-bottle price is never 'ok'.
--
--  Unchanged: signature, return shape, the apply step, which lines/items are
--  considered, 'manual price kept' and 'price on file is as new or newer'.
--  ROLLBACK: 0093_ROLLBACK_invoice_costs_infer_pack.sql (the pre-0093 function)
-- =============================================================================
begin;

CREATE OR REPLACE FUNCTION public.kount_refresh_venue_invoice_costs(p_venue_id text, p_days integer DEFAULT 120, p_apply boolean DEFAULT false, p_invoice_beats_manual boolean DEFAULT false)
 RETURNS TABLE(master_item_id uuid, item text, invoice_date date, invoice_number text, vendor text, line_cost numeric, pack numeric, unit_cost numeric, basis text, reference numeric, current_cost numeric, current_date_ date, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_ops uuid;
begin
  select kv.ops_venue_id into v_ops from kount_venues kv where kv.id = p_venue_id;
  if v_ops is null then
    raise exception 'kount venue % has no ops_venue_id (see migration 0056)', p_venue_id;
  end if;

  -- 0077: a second call in the same transaction (the nightly job refreshes two venues) failed with
  -- 'relation "_kvic" already exists' -- the job never completed. Drop the previous call's table first.
  drop table if exists _kvic;
  create temp table _kvic on commit drop as
  with raw as (
    select l.id as line_id, l.item_id, l.unit_cost, l.cu_qty, l.created_at, l.qty as line_qty,
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
    union all
    -- 0077: an R365 'Missing Vendor Item' line placed by kount_invoice_line_map prices the counted item it
    -- was placed on: pack = counted units per invoice unit, so unit_cost / pack = line_total / units.
    -- Single-item lines only (a line split across several wines has no per-item price).
    select r.*, lm.master_item_id, round(lm.units / nullif(r.line_qty, 0), 4), true
    from raw r
    join kount_invoice_line_map lm on lm.venue_id = p_venue_id and lm.invoice_line_id = r.line_id
    where r.line_qty > 0
      and (select count(*) from kount_invoice_line_map x where x.venue_id = p_venue_id and x.invoice_line_id = r.line_id) = 1
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
  -- 0093: the same product's cost at the OTHER venues (median), a reference for a new venue.
  sister as (
    select o2.master_item_id, percentile_cont(0.5) within group (order by o2.cost_per_unit)::numeric as med
    from kount_venue_cost_overrides o2
    where o2.venue_id <> p_venue_id and o2.cost_per_unit > 0
    group by o2.master_item_id
  ),
  priced as (
    select n.*, m.name, m.category as mcat,
           coalesce(n.map_pack, n.cu_qty, (regexp_match(n.descr, 'BPC:\s*(\d+)'))[1]::numeric) as pk,
           o.cost_per_unit as cur, o.is_manual as cur_manual,
           coalesce(o.price_date, o.updated_at::date) as cur_date,
           coalesce(o.cost_per_unit, s.med, c.avg_cost) as ref,
           -- 0093: the pack the description states, most specific pattern first.
           coalesce(
             (regexp_match(n.descr, '\((\d{1,2})\s*(?:btl|bottle)', 'i'))[1],
             (regexp_match(n.descr, '\m(\d{1,2})\s*x\s*\d+(?:\.\d+)?\s*(?:ml|l|cl|oz|z)?\M', 'i'))[1],
             (regexp_match(n.descr, '\m(\d{1,2})\s*/\s*\d{3,4}\s*(?:ml|l)?\M', 'i'))[1],
             (regexp_match(n.descr, '\m1/(\d{1,2})/\d', 'i'))[1],
             (regexp_match(n.descr, '(?:ml|l)\s*[/-]\s*(\d{1,2})\M', 'i'))[1],
             (regexp_match(n.descr, '\m(\d{1,2})\s*(?:pack|pk|b|p)\M', 'i'))[1],
             (regexp_match(n.descr, '\mc(\d{2})\M', 'i'))[1],
             (regexp_match(n.descr, '\m(\d{1,2})\s*bottles\M', 'i'))[1]
           )::numeric as dpk,
           -- 0093: bottle size in litres (catalog size, else the name), for the plausibility band.
           case lower(coalesce(m.base_unit, ''))
             when 'ml' then m.base_size / 1000.0
             when 'l' then m.base_size
             when 'cl' then m.base_size / 100.0
             when 'floz' then m.base_size * 0.0295735
             when 'oz' then m.base_size * 0.0295735
             else (select case lower(x[2]) when 'ml' then x[1]::numeric / 1000.0 when 'cl' then x[1]::numeric / 100.0
                                           when 'l' then x[1]::numeric else x[1]::numeric * 0.0295735 end
                     from regexp_match(m.name, '(\d+(?:\.\d+)?)\s*(ml|cl|l|fl\.?\s*oz|oz)\M', 'i') x)
           end as liters
    from newest n
    join master_items m on m.id = n.mid and m.category ~* 'liquor|wine|beer|beverage|consumable'
    left join cat c on c.master_item_id = n.mid
    left join sister s on s.master_item_id = n.mid
    left join kount_venue_cost_overrides o on o.venue_id = p_venue_id and o.master_item_id = n.mid
    where n.rn = 1
      -- Only items this venue actually deals in: mapped, already priced for
      -- it, or counted there. Keeps rows off the shadow items.
      and (n.mapped or o.master_item_id is not null
           or exists (select 1 from kount_entries e join kount_audits a on a.id = e.audit_id
                      where a.venue_id = p_venue_id and e.master_item_id = n.mid))
  ),
  banded as (
    select p.*,
           case when p.mcat ~* 'liquor|wine|sake' then 6.0 when p.mcat ~* 'beer|beverage' then 0.8 end as lo_l,
           case when p.mcat ~* 'liquor|wine|sake' then 1500.0 when p.mcat ~* 'beer|beverage' then 60.0 end as hi_l
    from priced p
  ),
  chosen as (
    select b.*,
           case when b.pk > 0 and b.pk <> 1 then round((b.unit_cost / b.pk)::numeric, 4) end as per_case,
           round(b.unit_cost::numeric, 4) as per_line,
           coalesce(b.pk > 0 and b.pk <> 1 and b.ref > 0 and b.unit_cost / b.pk between b.ref / 2.5 and b.ref * 2.5, false) as case_ok,
           coalesce(b.ref > 0 and b.unit_cost between b.ref / 2.5 and b.ref * 2.5, false) as line_ok,
           best.p as ref_pack, coalesce(amb.n, 0) as ref_fits,
           -- 0093: a pack the description STATES is trusted within 2x of the reference,
           -- unless another candidate lands within 1.5x and closer.
           coalesce(b.ref > 0 and b.dpk > 0 and abs(ln((b.unit_cost / b.dpk) / b.ref)) <= ln(2.0)
                    and (best.p is null or best.p = b.dpk), false) as dpk_ref_ok,
           coalesce(b.dpk > 0 and b.liters > 0 and b.lo_l is not null
                    and b.unit_cost / b.dpk / b.liters between b.lo_l and b.hi_l, false) as dpk_plausible,
           coalesce(b.liters > 0 and b.lo_l is not null
                    and b.unit_cost / b.liters between b.lo_l and b.hi_l, false) as line_plausible
    from banded b
    -- 0093: with a reference, the candidate pack whose per-bottle price is closest to it.
    left join lateral (
      select c.p
      from (select distinct unnest(array_remove(array[b.dpk, 1, 6, 12, 24]::numeric[], null)) as p) c
      where b.ref > 0 and c.p > 0 and abs(ln((b.unit_cost / c.p) / b.ref)) <= ln(1.5)
      order by abs(ln((b.unit_cost / c.p) / b.ref)), (c.p = b.dpk) desc nulls last
      limit 1
    ) best on true
    left join lateral (
      select count(*) as n
      from (select distinct unnest(array_remove(array[b.dpk, 1, 6, 12, 24]::numeric[], null)) as p) c
      where b.ref > 0 and c.p > 0 and abs(ln((b.unit_cost / c.p) / b.ref)) <= ln(1.5)
    ) amb on true
  ),
  resolved as (
    select c.*,
      case
        -- a known pack: exactly the pre-0093 rules
        when c.pk > 0 and c.case_ok then c.per_case
        when c.pk > 0 and c.line_ok then c.per_line
        when c.pk > 0 and c.ref is null and c.pk <> 1 then c.per_case
        when c.pk > 0 and c.ref is null and c.pk = 1 then c.per_line
        when c.pk > 0 then null
        -- 0093: unknown pack, reference available
        when c.dpk_ref_ok then round((c.unit_cost / c.dpk)::numeric, 4)
        when c.ref_pack is not null and (c.ref_fits = 1 or c.ref_pack = c.dpk) then round((c.unit_cost / c.ref_pack)::numeric, 4)
        when c.ref > 0 then null
        -- 0093: unknown pack, no reference -- description pack if plausible, else the line if plausible
        when c.dpk_plausible then round((c.unit_cost / c.dpk)::numeric, 4)
        when c.dpk > 0 and c.line_plausible then c.per_line
      end as per_unit,
      case
        when c.pk > 0 and c.case_ok then 'line / pack ' || c.pk
        when c.pk > 0 and c.line_ok then 'line is per unit'
        when c.pk > 0 and c.ref is null and c.pk <> 1 then 'line / pack ' || c.pk || ' (no reference)'
        when c.pk > 0 and c.ref is null and c.pk = 1 then 'line is per unit (pack 1, no reference)'
        when c.pk > 0 then null
        when c.dpk_ref_ok then
          case when c.dpk = 1 then 'line is per unit' else 'line / pack ' || c.dpk end
          || ' (pack from description, within 2x of reference $' || round(c.ref, 2) || ')'
        when c.ref_pack is not null and (c.ref_fits = 1 or c.ref_pack = c.dpk) then
          case when c.ref_pack = 1 then 'line is per unit' else 'line / pack ' || c.ref_pack end
          || case when c.ref_pack = c.dpk then ' (pack from description, ' else ' (pack inferred, ' end
          || 'within 1.5x of reference $' || round(c.ref, 2) || ')'
        when c.ref > 0 then null
        when c.dpk_plausible then 'line / pack ' || c.dpk || ' (pack from description, no reference)'
        when c.dpk > 0 and c.line_plausible then 'line is per unit (description pack ' || c.dpk || ' implausible, no reference)'
      end as basis2
    from chosen c
  )
  select r.mid, r.name as item, r.invoice_date, r.invoice_number, r.vendor, r.unit_cost as line_cost,
         coalesce(r.pk, case when r.dpk_ref_ok then r.dpk end, r.ref_pack, r.dpk) as pack,
         r.per_unit, r.basis2 as basis,
         r.ref, r.cur, r.cur_date,
         case
           when r.per_unit is null and r.ref is not null then 'review: no pack within 1.5x of reference (or two fit)'
           when r.per_unit is null and r.dpk is null then 'review: no reference cost and no pack size'
           when r.per_unit is null then 'review: description pack and line price both implausible'
           when r.cur_manual and not p_invoice_beats_manual then 'skip: manual price kept'
           when r.cur is not null and r.invoice_date <= r.cur_date then 'skip: price on file is as new or newer'
           when r.cur is null then 'ok: new'
           else 'ok: newer invoice'
         end as status
  from resolved r;

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
end $function$;

commit;
