-- ============================================================================
-- 0032: fix new-recipe bridge join key + purge demo venue rows
-- ============================================================================
-- Migration 0030 wired dep_new_recipe to join new_recipe_pos_skus.pos_sku
-- against pos_check_items.external_item_id (a UUID). But the people who
-- populated the bridge stored MENU ITEM NAMES in pos_sku (e.g. "Don Julio
-- Anejo", "BTL Don Julio 1942 Magnum") — so 802 bridge rows produced zero
-- POS matches against the 97,638 distinct external_item_id UUIDs in the
-- last 30 days. Coverage of cocktail/recipe depletions = 0.
--
-- Two adjustments:
--   1. Change dep_new_recipe's join from
--          nrps.pos_sku = pci.external_item_id
--      to
--          lower(trim(nrps.pos_sku)) = lower(trim(pci.item_name))
--      matching the same case-insensitive item_name join that
--      dep_direct + dep_old_recipe already use against menu_item_recipe_map.
--   2. Delete demo venue rows (UUIDs 1111…1111 and 2222…2222) so they
--      don't muddy debugging output. 356 of 802 bridge rows.
--
-- Everything else in compute_avt_for_audit stays byte-identical to 0030.
-- Idempotent: re-running drops the same demo rows (already gone after
-- first run) and re-applies the same function body.
-- ============================================================================

begin;

-- 1) Purge demo-data rows from the bridge. These were almost certainly
--    seeded during development against placeholder venue IDs; they map
--    to real menu items but to fake venues. Keeping them risks an
--    accidental join against a real venue if either UUID ever becomes a
--    real venue id (vanishingly unlikely but trivial to defuse).
delete from public.new_recipe_pos_skus
 where venue_id in (
   '11111111-1111-1111-1111-111111111111'::uuid,
   '22222222-2222-2222-2222-222222222222'::uuid
 );

-- 2) Recreate compute_avt_for_audit with the corrected dep_new_recipe
--    join. Body is copied verbatim from 0030 except for those two lines.
create or replace function public.compute_avt_for_audit(p_audit_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_report_id      uuid;
  v_kount_venue_id text;
  v_venue_name     text;
  v_store          text;
  v_ops_venue_id   uuid;
  v_window_start   timestamptz;
  v_window_end     timestamptz;
  v_prev_audit_id  uuid;
  v_inserted       integer;
  v_notes          text;
begin
  -- 1) Resolve audit context.
  select a.venue_id, kv.name, coalesce(kv.store_aliases[1], kv.name),
         kv.ops_venue_id, a.count2_closed_at
    into v_kount_venue_id, v_venue_name, v_store, v_ops_venue_id, v_window_end
    from public.kount_audits a
    join public.kount_venues kv on kv.id = a.venue_id
   where a.id = p_audit_id;

  if not found then
    raise exception 'compute_avt_for_audit: audit % not found', p_audit_id
      using errcode = 'P0002';
  end if;
  if v_window_end is null then
    raise exception 'compute_avt_for_audit: audit % is not closed (count2_closed_at is null)',
      p_audit_id using errcode = '22023';
  end if;

  -- 1b) Authorization gate (unchanged from 0030).
  if not exists (
    select 1
      from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and (
         u.role = 'corporate'
         or v_kount_venue_id = any(u.venue_ids)
       )
  ) then
    raise exception 'not authorized to compute avt for audit %', p_audit_id
      using errcode = '42501';
  end if;

  -- Window start = the prior submitted audit's close for the same kount venue.
  select prev.count2_closed_at, prev.id
    into v_window_start, v_prev_audit_id
    from public.kount_audits prev
   where prev.venue_id = v_kount_venue_id
     and prev.status   = 'submitted'
     and prev.id      <> p_audit_id
     and prev.count2_closed_at < v_window_end
   order by prev.count2_closed_at desc
   limit 1;

  -- 2) Idempotency: replace prior computed report for this audit, if any.
  delete from public.kount_avt_rows
   where report_id in (
     select id from public.kount_avt_reports
      where audit_id = p_audit_id and source = 'computed'
   );
  delete from public.kount_avt_reports
   where audit_id = p_audit_id and source = 'computed';

  -- 3) Insert the new report shell. row_count is patched at the end.
  insert into public.kount_avt_reports
    (uploaded_by_email, uploaded_by_name, file_name, row_count, venue_ids,
     source, audit_id, computed_at, notes)
  values
    ('system@computed', 'Computed AVT', null, 0,
     array[v_kount_venue_id]::text[],
     'computed', p_audit_id, now(),
     null)
  returning id into v_report_id;

  -- 4) Build all the math in one statement so CTEs can FULL OUTER JOIN.
  with
  actuals_pick as (
    select master_item_id, zone, qty,
           row_number() over (
             partition by master_item_id, zone
             order by is_recount desc nulls last
           ) as rn
      from public.kount_entries
     where audit_id = p_audit_id
       and master_item_id is not null
  ),
  actuals as (
    select master_item_id, sum(qty)::numeric as qty
      from actuals_pick
     where rn = 1
     group by master_item_id
  ),
  starts_pick as (
    select master_item_id, zone, qty,
           row_number() over (
             partition by master_item_id, zone
             order by is_recount desc nulls last
           ) as rn
      from public.kount_entries
     where audit_id = v_prev_audit_id
       and master_item_id is not null
  ),
  starts as (
    select master_item_id, sum(qty)::numeric as qty
      from starts_pick
     where rn = 1
     group by master_item_id
  ),
  purchases as (
    select er.master_item_id, sum(er.effective_qty)::numeric as qty
      from public.v_effective_receipts er
      join public.invoices i on i.id = er.invoice_id
     where v_ops_venue_id is not null
       and i.venue_id = v_ops_venue_id
       and er.received_at >= coalesce(v_window_start, '-infinity'::timestamptz)
       and er.received_at <  v_window_end
       and coalesce(er.rejected, false) = false
       and er.master_item_id is not null
     group by er.master_item_id
  ),
  dep_direct as (
    select mirm.master_item_id, sum(pci.quantity)::numeric as qty
      from public.menu_item_recipe_map mirm
      join public.pos_check_items pci
        on pci.venue_id = mirm.venue_id
       and pci.item_name = mirm.menu_item_name
     where v_ops_venue_id is not null
       and mirm.venue_id = v_ops_venue_id
       and mirm.is_active = true
       and coalesce(mirm.is_excluded, false) = false
       and mirm.master_item_id is not null
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by mirm.master_item_id
  ),
  old_recipe_per_master as (
    select ri.recipe_id, pi.master_item_id, sum(coalesce(ri.qty, 0))::numeric as ing_qty
      from public.recipe_items ri
      join public.purchase_items pi
        on pi.id = ri.item_id
     where coalesce(ri.is_packaging, false) = false
       and pi.master_item_id is not null
     group by ri.recipe_id, pi.master_item_id
  ),
  dep_old_recipe as (
    select orpm.master_item_id, sum(pci.quantity * orpm.ing_qty)::numeric as qty
      from public.menu_item_recipe_map mirm
      join public.pos_check_items pci
        on pci.venue_id = mirm.venue_id
       and pci.item_name = mirm.menu_item_name
      join old_recipe_per_master orpm
        on orpm.recipe_id = mirm.recipe_id
     where v_ops_venue_id is not null
       and mirm.venue_id = v_ops_venue_id
       and mirm.is_active = true
       and mirm.recipe_id is not null
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by orpm.master_item_id
  ),
  new_recipe_per_master as (
    select nri.recipe_id, nrimm.master_item_id,
           sum(coalesce(nri.quantity, 0) * coalesce(nrimm.base_qty, 1))::numeric as ing_qty
      from public.new_recipe_ingredients nri
      join public.new_recipe_ingredient_master_map nrimm
        on nrimm.ingredient_name = nri.ingredient_name
     where coalesce(nri.is_sub_recipe, false) = false
     group by nri.recipe_id, nrimm.master_item_id
  ),
  -- 4f) dep_new_recipe — FIX 0032: join nrps.pos_sku against
  --     pci.item_name (case-insensitive trim), not external_item_id.
  --     The bridge stores menu item names, NOT POS UUIDs.
  dep_new_recipe as (
    select nrpm.master_item_id, sum(pci.quantity * nrpm.ing_qty)::numeric as qty
      from public.pos_check_items pci
      join public.new_recipe_pos_skus nrps
        on nrps.venue_id = pci.venue_id
       and lower(trim(nrps.pos_sku)) = lower(trim(pci.item_name))
      join new_recipe_per_master nrpm
        on nrpm.recipe_id = nrps.recipe_id
     where v_ops_venue_id is not null
       and pci.venue_id = v_ops_venue_id
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by nrpm.master_item_id
  ),
  dep_total as (
    select coalesce(d.master_item_id, o.master_item_id, n.master_item_id) as master_item_id,
           greatest(coalesce(d.qty, 0), coalesce(o.qty, 0), coalesce(n.qty, 0)) as qty
      from dep_direct d
      full outer join dep_old_recipe o using (master_item_id)
      full outer join dep_new_recipe n using (master_item_id)
  ),
  prices as (
    select distinct on (master_item_id)
           master_item_id, avg_cost
      from public.purchase_items
     where master_item_id is not null
       and avg_cost is not null
     order by master_item_id, updated_at desc nulls last
  ),
  all_masters as (
    select master_item_id from actuals
    union
    select master_item_id from starts
    union
    select master_item_id from purchases
    union
    select master_item_id from dep_total
  ),
  final_rows as (
    select
      m.master_item_id,
      mi.name      as item_name,
      mi.category  as category,
      coalesce(a.qty, 0)::numeric  as actual,
      coalesce(s.qty, 0)::numeric  as start_qty,
      coalesce(p.qty, 0)::numeric  as purchases,
      coalesce(dt.qty, 0)::numeric as depletions,
      pr.avg_cost::numeric         as cu_price,
      (coalesce(s.qty, 0) + coalesce(p.qty, 0) - coalesce(dt.qty, 0))::numeric as theo
      from all_masters m
      left join actuals   a  on a.master_item_id  = m.master_item_id
      left join starts    s  on s.master_item_id  = m.master_item_id
      left join purchases p  on p.master_item_id  = m.master_item_id
      left join dep_total dt on dt.master_item_id = m.master_item_id
      left join prices    pr on pr.master_item_id = m.master_item_id
      join public.master_items mi on mi.id = m.master_item_id
  )
  insert into public.kount_avt_rows
    (report_id, store, venue_id, venue_name, item_name, category,
     actual, theo, variance, variance_value, variance_pct,
     cu_price, start_qty, purchases, depletions)
  select
    v_report_id,
    v_store,
    v_kount_venue_id,
    v_venue_name,
    fr.item_name,
    fr.category,
    fr.actual,
    fr.theo,
    (fr.actual - fr.theo)                                            as variance,
    (fr.actual - fr.theo) * coalesce(fr.cu_price, 0)                 as variance_value,
    case when fr.theo = 0 then null
         else (fr.actual - fr.theo) / fr.theo * 100 end              as variance_pct,
    fr.cu_price,
    fr.start_qty,
    fr.purchases,
    fr.depletions
    from final_rows fr;

  get diagnostics v_inserted = row_count;

  -- 5) Patch notes with provenance + the row count we just inserted.
  v_notes := jsonb_build_object(
    'ops_venue_bridged',          v_ops_venue_id is not null,
    'ops_venue_id',               v_ops_venue_id,
    'prev_audit_id',              v_prev_audit_id,
    'window_start',               v_window_start,
    'window_end',                 v_window_end,
    'depletion_sources_populated', jsonb_build_object(
       'direct',     (select count(*) from public.menu_item_recipe_map
                       where venue_id = v_ops_venue_id
                         and is_active = true
                         and coalesce(is_excluded, false) = false
                         and master_item_id is not null),
       'old_recipe', (select count(*) from public.menu_item_recipe_map
                       where venue_id = v_ops_venue_id
                         and is_active = true
                         and recipe_id is not null),
       'new_recipe', (select count(*) from public.new_recipe_pos_skus
                       where venue_id = v_ops_venue_id)
    ),
    'name_derived_entries_skipped',
       (select count(*) from public.kount_entries
         where audit_id = p_audit_id and master_item_id is null)
  )::text;

  update public.kount_avt_reports
     set row_count = v_inserted,
         notes     = v_notes
   where id = v_report_id;

  return v_report_id;
end
$fn$;

revoke all on function public.compute_avt_for_audit(uuid) from public;
grant  execute on function public.compute_avt_for_audit(uuid) to authenticated;

commit;
