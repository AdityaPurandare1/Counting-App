-- =============================================================================
--  0077_invoice_automation_and_admin_reads
--
--  #6 Fresh venue costs. kount_refresh_venue_invoice_costs:
--     * drops its temp table first -- the nightly job (jobid 20, v12 + v5) failed every night since it
--       was scheduled ('relation "_kvic" already exists' on the second call), so no venue cost ever
--       refreshed from invoices (Alphabet: Jim Beam 1L $16.40 on file vs $22.75 invoiced).
--     * prices counted items from placeholder lines placed by kount_invoice_line_map (single-item lines).
--  #3 Automatic placement of R365 'Missing Vendor Item' lines by exact price:
--     kount_price_fingerprints (vendor + GL + exact unit cost -> counted item, units per invoice unit),
--     learned from confirmed single-item placements; a key that ever maps to two items is never used.
--     kount_auto_place_placeholder_lines(venue, days, apply) places lines whose key has ONE fingerprint.
--     Opted-in venues only (purchase_mapping = venue_item_map). Rows set_by 'kount_auto_place'.
--  #4 kount_unplaced_invoice_lines(audit): placeholder lines in the audit's variance window not placed.
--  #5 kount_unmapped_pos_items(venue, days): POS items selling with no bottle / recipe link (not food).
--  Nightly job 20: auto-place (opted-in venues) -> refresh costs (opted-in venues, invoice beats the
--  opening-sheet price; Poppy v5 unchanged).
--  ROLLBACK: 0077_ROLLBACK_invoice_automation_and_admin_reads.sql
-- =============================================================================
begin;

-- ---------- #6 ----------
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

-- ---------- #3 ----------
create table if not exists public.kount_price_fingerprints (
  venue_id       text    not null references public.kount_venues(id),
  vendor_id      uuid    not null,
  gl_code        text    not null default '',
  unit_cost      numeric(12,2) not null,
  master_item_id uuid    not null references public.master_items(id),
  units_per_qty  numeric not null check (units_per_qty > 0),
  learned_from   uuid,
  source         text,
  created_at     timestamptz not null default now(),
  primary key (venue_id, vendor_id, gl_code, unit_cost, master_item_id, units_per_qty)
);
alter table public.kount_price_fingerprints enable row level security;
drop policy if exists kount_price_fingerprints_read on public.kount_price_fingerprints;
create policy kount_price_fingerprints_read on public.kount_price_fingerprints
  for select to authenticated using (public.kount_can_see_venue(venue_id));
grant select on public.kount_price_fingerprints to authenticated;

create or replace function public.kount_learn_price_fingerprints(p_venue_id text)
returns integer language plpgsql security definer set search_path to 'public' as $fn$
declare n integer;
begin
  insert into kount_price_fingerprints (venue_id, vendor_id, gl_code, unit_cost, master_item_id, units_per_qty, learned_from, source)
  select lm.venue_id, i.vendor_id, coalesce(il.gl_code, ''), round(il.unit_cost, 2), lm.master_item_id,
         round(lm.units / il.qty, 4), il.id,
         format('learned from %s invoice #%s %s (%s)', coalesce(v.name, '?'), i.invoice_number, i.invoice_date, coalesce(lm.set_by, '?'))
    from kount_invoice_line_map lm
    join invoice_lines il on il.id = lm.invoice_line_id
    join invoices i on i.id = il.invoice_id
    left join vendors v on v.id = i.vendor_id
   where lm.venue_id = p_venue_id and il.qty > 0 and il.unit_cost > 0 and i.vendor_id is not null and lm.units > 0
     and (select count(*) from kount_invoice_line_map x where x.venue_id = lm.venue_id and x.invoice_line_id = lm.invoice_line_id) = 1
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $fn$;

create or replace function public.kount_auto_place_placeholder_lines(p_venue_id text, p_days integer default 120, p_apply boolean default false)
returns table(invoice_line_id uuid, invoice_number text, invoice_date date, vendor text, gl_code text, qty numeric,
              unit_cost numeric, line_total numeric, item text, units numeric, status text)
language plpgsql security definer set search_path to 'public' as $fn$
#variable_conflict use_column
declare v_ops uuid; v_map text;
begin
  select kv.ops_venue_id, kv.purchase_mapping into v_ops, v_map from kount_venues kv where kv.id = p_venue_id;
  if v_ops is null or v_map is distinct from 'venue_item_map' then return; end if;
  perform kount_learn_price_fingerprints(p_venue_id);

  return query
  with cand as (
    select il.id, i.invoice_number, i.invoice_date, i.vendor_id, coalesce(v.name, '?') as vname, coalesce(il.gl_code, '') as gl,
           il.qty, il.unit_cost, il.line_total
      from invoice_lines il join invoices i on i.id = il.invoice_id
      left join vendors v on v.id = i.vendor_id left join purchase_items p on p.id = il.item_id
     where i.venue_id = v_ops and i.invoice_date >= current_date - p_days
       and coalesce(il.description, p.name, '') ilike 'missing vendor item%'
       and il.qty > 0 and il.unit_cost > 0 and not coalesce(il.is_ignored, false)
       and not exists (select 1 from kount_invoice_line_map lm where lm.venue_id = p_venue_id and lm.invoice_line_id = il.id)),
  hits as (
    select c.*, f.master_item_id, f.units_per_qty, count(*) over (partition by c.id) as n
      from cand c join kount_price_fingerprints f
        on f.venue_id = p_venue_id and f.vendor_id = c.vendor_id and f.gl_code = c.gl and f.unit_cost = round(c.unit_cost, 2))
  select h.id, h.invoice_number, h.invoice_date, h.vname, h.gl, h.qty, h.unit_cost, h.line_total, m.name,
         round(h.qty * h.units_per_qty, 4),
         case when h.n = 1 then case when p_apply then 'placed' else 'would place' end else 'skipped: price matches several items' end
    from hits h join master_items m on m.id = h.master_item_id
   order by h.invoice_date, h.vname;

  if p_apply then
    insert into kount_invoice_line_map (venue_id, invoice_line_id, master_item_id, units, confidence, evidence, set_by)
    select p_venue_id, h.id, h.master_item_id, round(h.qty * h.units_per_qty, 4), 'price',
           format('auto: %s #%s %s x $%s exact price = learned item, %s per unit', h.vname, h.invoice_number, h.qty, h.unit_cost, h.units_per_qty),
           'kount_auto_place'
      from (
        select c.*, f.master_item_id, f.units_per_qty, count(*) over (partition by c.id) as n
          from (select il.id, i.invoice_number, i.vendor_id, coalesce(v.name, '?') as vname, coalesce(il.gl_code, '') as gl, il.qty, il.unit_cost
                  from invoice_lines il join invoices i on i.id = il.invoice_id
                  left join vendors v on v.id = i.vendor_id left join purchase_items p on p.id = il.item_id
                 where i.venue_id = v_ops and i.invoice_date >= current_date - p_days
                   and coalesce(il.description, p.name, '') ilike 'missing vendor item%'
                   and il.qty > 0 and il.unit_cost > 0 and not coalesce(il.is_ignored, false)
                   and not exists (select 1 from kount_invoice_line_map lm where lm.venue_id = p_venue_id and lm.invoice_line_id = il.id)) c
          join kount_price_fingerprints f
            on f.venue_id = p_venue_id and f.vendor_id = c.vendor_id and f.gl_code = c.gl and f.unit_cost = round(c.unit_cost, 2)) h
     where h.n = 1
    on conflict do nothing;
  end if;
end $fn$;
revoke all on function public.kount_learn_price_fingerprints(text) from public, anon, authenticated;
revoke all on function public.kount_auto_place_placeholder_lines(text, integer, boolean) from public, anon, authenticated;

-- ---------- #4 ----------
create or replace function public.kount_unplaced_invoice_lines(p_audit_id uuid)
returns table(vendor text, invoice_number text, invoice_date date, gl_code text, description text,
              qty numeric, unit_cost numeric, line_total numeric, is_beverage boolean)
language plpgsql stable security definer set search_path to 'public' as $fn$
#variable_conflict use_column
declare v_venue text; v_ops uuid; v_notes jsonb; v_ws timestamptz; v_we timestamptz;
begin
  select a.venue_id, kv.ops_venue_id into v_venue, v_ops
    from kount_audits a join kount_venues kv on kv.id = a.venue_id where a.id = p_audit_id;
  if v_venue is null or v_ops is null or not kount_can_see_venue(v_venue) then return; end if;
  begin
    select r.notes::jsonb into v_notes from kount_avt_reports r
     where r.audit_id = p_audit_id and r.source = 'computed' order by r.computed_at desc limit 1;
  exception when others then return;
  end;
  if v_notes is null or v_notes->>'window_end' is null then return; end if;
  v_ws := nullif(v_notes->>'window_start', '')::timestamptz;
  v_we := (v_notes->>'window_end')::timestamptz;
  return query
  select coalesce(v.name, '?'), i.invoice_number, i.invoice_date, coalesce(il.gl_code, ''), il.description,
         il.qty, il.unit_cost, il.line_total, coalesce(il.gl_code, '') ~ '^53'
    from v_effective_receipts er
    join invoices i on i.id = er.invoice_id
    join invoice_lines il on il.id = er.invoice_line_id
    join master_items mi on mi.id = er.master_item_id
    left join vendors v on v.id = i.vendor_id
   where i.venue_id = v_ops
     and coalesce(er.received_at, i.invoice_date::timestamptz) >= coalesce(v_ws, '-infinity'::timestamptz)
     and coalesce(er.received_at, i.invoice_date::timestamptz) < v_we
     and coalesce(er.rejected, false) = false
     and mi.name ilike 'missing vendor item%'
     and not exists (select 1 from kount_invoice_line_map lm where lm.venue_id = v_venue and lm.invoice_line_id = er.invoice_line_id)
   order by 9 desc, il.line_total desc;
end $fn$;
revoke all on function public.kount_unplaced_invoice_lines(uuid) from public, anon;
grant execute on function public.kount_unplaced_invoice_lines(uuid) to authenticated;

-- ---------- #5 ----------
create or replace function public.kount_unmapped_pos_items(p_venue_id text, p_days integer default 14)
returns table(pos_item text, category text, qty numeric, net_sales numeric, first_sold date, last_sold date)
language plpgsql stable security definer set search_path to 'public' as $fn$
#variable_conflict use_column
declare v_ops uuid; v_src text;
begin
  if not kount_can_see_venue(p_venue_id) then return; end if;
  select kv.ops_venue_id, kv.depletion_source into v_ops, v_src from kount_venues kv where kv.id = p_venue_id;
  if v_ops is null then return; end if;
  return query
  with sold as (
    select f.menu_item_name as n, f.parent_category as c, f.quantity_sold::numeric as q, coalesce(f.net_sales, 0)::numeric as s, f.business_date as d
      from item_day_facts f
     where v_src = 'item_day_facts' and f.venue_id = v_ops and f.business_date >= current_date - p_days
    union all
    select p.item_name, p.parent_category_name, p.quantity::numeric, (coalesce(p.price, 0) * coalesce(p.quantity, 0))::numeric, p.business_date
      from pos_check_items p
     where coalesce(v_src, 'pos_check_items') = 'pos_check_items' and p.venue_id = v_ops and p.business_date >= current_date - p_days),
  handled as (
    select lower(trim(m.menu_item_name)) as k from menu_item_recipe_map m
     where m.venue_id = v_ops and m.is_active
       and (coalesce(m.is_excluded, false) or m.recipe_id is not null
            or (coalesce(m.is_bottle_service, false) and m.master_item_id is not null))
    union
    select lower(trim(s.pos_sku)) from new_recipe_pos_skus s where s.venue_id = v_ops)
  select s.n, max(s.c), sum(s.q), round(sum(s.s), 2), min(s.d), max(s.d)
    from sold s
   where coalesce(s.c, '') !~* '^food' and lower(trim(s.n)) not in (select k from handled)
   group by s.n
  having sum(s.q) > 0
   order by 4 desc, 3 desc;
end $fn$;
revoke all on function public.kount_unmapped_pos_items(text, integer) from public, anon;
grant execute on function public.kount_unmapped_pos_items(text, integer) to authenticated;

-- ---------- nightly job ----------
select cron.alter_job(20, command := $cmd$select count(*) from public.kount_venues kv cross join lateral public.kount_auto_place_placeholder_lines(kv.id, 120, true) where kv.purchase_mapping = 'venue_item_map' and kv.is_active; select count(*) from public.kount_venues kv cross join lateral public.kount_refresh_venue_invoice_costs(kv.id, 120, true, true) where kv.purchase_mapping = 'venue_item_map' and kv.is_active; select count(*) from kount_refresh_venue_invoice_costs('v5', 120, true, false);$cmd$);

commit;
