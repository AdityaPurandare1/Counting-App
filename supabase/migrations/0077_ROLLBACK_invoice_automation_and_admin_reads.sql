-- ROLLBACK for 0077: restores the pre-0077 refresh function (byte-exact) and nightly job; drops the new objects.
-- Auto-placed line-map rows (set_by 'kount_auto_place') and refreshed costs are data: remove them separately if wanted.
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
end $function$;
select cron.alter_job(20, command := $cmd$select count(*) from kount_refresh_venue_invoice_costs('v12', 120, true, true); select count(*) from kount_refresh_venue_invoice_costs('v5', 120, true, false);$cmd$);
drop function if exists public.kount_unmapped_pos_items(text, integer);
drop function if exists public.kount_unplaced_invoice_lines(uuid);
drop function if exists public.kount_auto_place_placeholder_lines(text, integer, boolean);
drop function if exists public.kount_learn_price_fingerprints(text);
drop table if exists public.kount_price_fingerprints;
commit;
