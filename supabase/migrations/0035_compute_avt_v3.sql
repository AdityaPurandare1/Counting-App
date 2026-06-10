-- =============================================================================
--  0035_compute_avt_v3
--
--  Third revision of compute_avt_for_audit (0030 → 0032 → this). Uploaded AVT
--  reports are deprecated; the computed AVT is THE product, so accuracy of
--  this RPC is now critical. Four corrections, plus the stale debug view:
--
--  1. RECOUNT OVERRIDE (the big one). 0030/0032 picked one entries row per
--     (master, zone) via row_number() ordered by is_recount desc — but NO
--     code anywhere writes is_recount = true, so that branch was dead AND the
--     rn=1 pick silently DROPPED qty when one master had two same-zone rows
--     under different item_names (the entries merge key is name-based for
--     custom items). Real recount corrections live in kount_recounts.count2_qty.
--     New semantics:
--       actual(master, zone) = SUM of kount_entries.qty       (sum, don't pick;
--       legacy is_recount = true rows are EXCLUDED — kount_recounts is the
--       canonical correction store now, so summing both would double-count).
--       Recount overrides (count2_qty not null, status <> 'dismissed',
--       latest wins per slot):
--         zone set  ⇒ replaces THAT zone's sum; other zones still sum in.
--         zone NULL ⇒ WHOLE-ITEM override: replaces the master's ENTIRE
--                     summed actual across all zones. (The phone writes
--                     recounts with zone null, while kount_entries.zone is
--                     NOT NULL with real zone names — keying null as ''
--                     matches no entry sum, so a naive FULL OUTER JOIN would
--                     ADD count2_qty on top instead of replacing.)
--       If a master has BOTH a whole-item and zone overrides for the same
--       audit, the whole-item override WINS (explicit precedence, see 4a).
--       Recounts with no matching entries still contribute — the item was
--       found during recount. Same logic applies to the starts (previous
--       audit's entries + previous audit's recounts).
--
--  2. DEPLETIONS. greatest(direct, old_recipe, new_recipe) per master was
--     wrong whenever a master depletes via DISJOINT menu items across
--     sources — GREATEST keeps only the biggest stream and drops the rest.
--     Correct semantics: dedup per POS menu item, then SUM. Candidates are
--     keyed (master, lower(trim(pos item name)), source); when the same
--     (master, pos item) is reached via multiple sources, ONE is kept by
--     priority direct > new_recipe > old_recipe; the survivors are summed
--     across distinct pos items per master. The 0032 name-join for the
--     new-recipe bridge is kept.
--
--  3. WINDOW ROBUSTNESS. Both clients' Submit buttons historically skipped
--     setting count2_closed_at (Summary-shortcut submits), so submitted
--     audits can have count2_closed_at NULL. The window end and the
--     previous-audit lookup now use coalesce(count2_closed_at, completed_at);
--     the RPC errors only when BOTH are null.
--
--  4. v_kount_avt_row_provenance (debug-only view from 0030) still joined
--     nrps.pos_sku = pci.external_item_id in its src_new_recipe arm after
--     0032 fixed the RPC to the name join. Recreated here to match the RPC
--     (name join + coalesced window).
--
--  Preserved from 0030/0032: auth gate, idempotent delete+reinsert of the
--  computed report, report/notes structure (notes gains
--  recount_overrides_applied and name_derived_recounts_skipped),
--  name-only-entry skip + its notes counter, cu_price from latest
--  purchase_items.avg_cost.
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`.
-- =============================================================================

begin;

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
  -- 1) Resolve audit context. Window end falls back to completed_at because
  --    historic Summary-shortcut submits left count2_closed_at NULL.
  select a.venue_id, kv.name, coalesce(kv.store_aliases[1], kv.name),
         kv.ops_venue_id, coalesce(a.count2_closed_at, a.completed_at)
    into v_kount_venue_id, v_venue_name, v_store, v_ops_venue_id, v_window_end
    from public.kount_audits a
    join public.kount_venues kv on kv.id = a.venue_id
   where a.id = p_audit_id;

  if not found then
    raise exception 'compute_avt_for_audit: audit % not found', p_audit_id
      using errcode = 'P0002';
  end if;
  if v_window_end is null then
    raise exception 'compute_avt_for_audit: audit % is not closed (count2_closed_at and completed_at are both null)',
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

  -- Window start = the prior submitted audit's close for the same kount
  -- venue, with the same coalesce fallback as the window end.
  select coalesce(prev.count2_closed_at, prev.completed_at), prev.id
    into v_window_start, v_prev_audit_id
    from public.kount_audits prev
   where prev.venue_id = v_kount_venue_id
     and prev.status   = 'submitted'
     and prev.id      <> p_audit_id
     and coalesce(prev.count2_closed_at, prev.completed_at) < v_window_end
   order by coalesce(prev.count2_closed_at, prev.completed_at) desc
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
  -- 4a) Actuals — SUM per (master, zone); two same-zone rows under different
  --     item_names now add instead of one being dropped by the old rn=1 pick.
  --     kount_entries.zone is NOT NULL, so it keys directly. is_recount =
  --     false excludes legacy recount rows: no current code writes true, but
  --     historic rows may exist and kount_recounts is the canonical
  --     correction store now — summing both would double-count.
  actual_entry_sums as (
    select master_item_id, zone as zone_key,
           sum(qty)::numeric as qty
      from public.kount_entries
     where audit_id = p_audit_id
       and master_item_id is not null
       and is_recount = false
     group by master_item_id, zone
  ),
  -- One recount per (master, zone-or-NULL): the latest non-dismissed recount
  -- with a real count2_qty. PARTITION BY groups NULL zones together (GROUP
  -- BY semantics), so a master's NULL-zone recounts collapse to one row too.
  -- kount_recounts has no updated_at; resolved_at (set when status flips to
  -- done) falling back to created_at is the best recency signal, with id as
  -- a deterministic tiebreak.
  actual_recounts as (
    select master_item_id, zone, count2_qty
      from (
        select r.master_item_id, r.zone, r.count2_qty,
               row_number() over (
                 partition by r.master_item_id, r.zone
                 order by coalesce(r.resolved_at, r.created_at) desc,
                          r.created_at desc, r.id desc
               ) as rn
          from public.kount_recounts r
         where r.audit_id = p_audit_id
           and r.master_item_id is not null
           and r.count2_qty is not null
           and r.status <> 'dismissed'
      ) x
     where x.rn = 1
  ),
  -- zone NULL ⇒ WHOLE-ITEM override (the phone writes recounts without a
  -- zone; entries always have one, so a ''-keyed join would match nothing
  -- and ADD count2_qty on top of the zone sums instead of replacing them).
  -- zone set ⇒ replaces that zone's sum only; other zones still sum in.
  actual_whole_overrides as (
    select master_item_id, count2_qty
      from actual_recounts
     where zone is null
  ),
  actual_zone_overrides as (
    select master_item_id, zone as zone_key, count2_qty
      from actual_recounts
     where zone is not null
  ),
  -- FULL OUTER: a recount for a (master, zone) with no entries rows still
  -- counts (item was found during recount despite never being scanned).
  actual_zone_totals as (
    select coalesce(es.master_item_id, ov.master_item_id) as master_item_id,
           sum(coalesce(ov.count2_qty, es.qty))::numeric  as qty
      from actual_entry_sums es
      full outer join actual_zone_overrides ov
        on ov.master_item_id = es.master_item_id
       and ov.zone_key       = es.zone_key
     group by coalesce(es.master_item_id, ov.master_item_id)
  ),
  -- PRECEDENCE (explicit, not a join-order artifact): if a master has BOTH a
  -- whole-item override and zone overrides for this audit, the whole-item
  -- override WINS — coalesce(whole, zone-composite) discards the per-zone
  -- result entirely. FULL OUTER again so a whole-item recount for a master
  -- with no entries and no zone recounts still contributes.
  actuals as (
    select coalesce(wo.master_item_id, zt.master_item_id) as master_item_id,
           coalesce(wo.count2_qty, zt.qty)::numeric       as qty
      from actual_zone_totals zt
      full outer join actual_whole_overrides wo
        on wo.master_item_id = zt.master_item_id
  ),
  -- 4b) Starts — identical logic against the previous audit (entries +
  --     recounts, same is_recount exclusion and whole-item-wins precedence
  --     as 4a). v_prev_audit_id NULL ⇒ all CTEs are empty ⇒ starts 0.
  start_entry_sums as (
    select master_item_id, zone as zone_key,
           sum(qty)::numeric as qty
      from public.kount_entries
     where audit_id = v_prev_audit_id
       and master_item_id is not null
       and is_recount = false
     group by master_item_id, zone
  ),
  start_recounts as (
    select master_item_id, zone, count2_qty
      from (
        select r.master_item_id, r.zone, r.count2_qty,
               row_number() over (
                 partition by r.master_item_id, r.zone
                 order by coalesce(r.resolved_at, r.created_at) desc,
                          r.created_at desc, r.id desc
               ) as rn
          from public.kount_recounts r
         where r.audit_id = v_prev_audit_id
           and r.master_item_id is not null
           and r.count2_qty is not null
           and r.status <> 'dismissed'
      ) x
     where x.rn = 1
  ),
  start_whole_overrides as (
    select master_item_id, count2_qty
      from start_recounts
     where zone is null
  ),
  start_zone_overrides as (
    select master_item_id, zone as zone_key, count2_qty
      from start_recounts
     where zone is not null
  ),
  start_zone_totals as (
    select coalesce(es.master_item_id, ov.master_item_id) as master_item_id,
           sum(coalesce(ov.count2_qty, es.qty))::numeric  as qty
      from start_entry_sums es
      full outer join start_zone_overrides ov
        on ov.master_item_id = es.master_item_id
       and ov.zone_key       = es.zone_key
     group by coalesce(es.master_item_id, ov.master_item_id)
  ),
  starts as (
    select coalesce(wo.master_item_id, zt.master_item_id) as master_item_id,
           coalesce(wo.count2_qty, zt.qty)::numeric       as qty
      from start_zone_totals zt
      full outer join start_whole_overrides wo
        on wo.master_item_id = zt.master_item_id
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
  -- 4c..4f) Depletion candidates, one row per (master, POS item, source).
  --     All three arms key the POS item by lower(trim(pci.item_name)) so the
  --     same menu item lines up across sources for the dedup below.
  dep_direct as (
    select mirm.master_item_id,
           lower(trim(pci.item_name)) as pos_key,
           sum(pci.quantity)::numeric as qty,
           1                          as priority   -- direct beats everything
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
     group by mirm.master_item_id, lower(trim(pci.item_name))
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
    select orpm.master_item_id,
           lower(trim(pci.item_name))                 as pos_key,
           sum(pci.quantity * orpm.ing_qty)::numeric  as qty,
           3                                          as priority -- last resort
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
     group by orpm.master_item_id, lower(trim(pci.item_name))
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
  -- name-join from 0032 kept: the bridge stores menu item names, not POS UUIDs.
  dep_new_recipe as (
    select nrpm.master_item_id,
           lower(trim(pci.item_name))                 as pos_key,
           sum(pci.quantity * nrpm.ing_qty)::numeric  as qty,
           2                                          as priority
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
     group by nrpm.master_item_id, lower(trim(pci.item_name))
  ),
  -- 4g) Dedup-then-SUM (replaces 0030's GREATEST-of-three): the same
  --     (master, POS item) reached via multiple sources keeps exactly one
  --     candidate by priority direct > new_recipe > old_recipe; DISJOINT POS
  --     items for the same master then SUM instead of dropping the smaller
  --     stream.
  dep_candidates as (
    select master_item_id, pos_key, qty,
           row_number() over (
             partition by master_item_id, pos_key
             order by priority
           ) as rn
      from (
        select * from dep_direct
        union all
        select * from dep_new_recipe
        union all
        select * from dep_old_recipe
      ) c
  ),
  dep_total as (
    select master_item_id, sum(qty)::numeric as qty
      from dep_candidates
     where rn = 1
     group by master_item_id
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
  --    recount_overrides_applied = distinct (master, zone-or-whole) override
  --    slots present for THIS audit; zone slots shadowed by a whole-item
  --    override for the same master still count (it tallies corrections
  --    recorded, not the precedence outcome).
  --    name_derived_recounts_skipped = this audit's otherwise-eligible
  --    recount corrections that can't override anything because they have no
  --    master_item_id (name-only items), parallel to
  --    name_derived_entries_skipped.
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
         where audit_id = p_audit_id and master_item_id is null),
    'name_derived_recounts_skipped',
       (select count(*) from public.kount_recounts r
         where r.audit_id = p_audit_id
           and r.master_item_id is null
           and r.count2_qty is not null
           and r.status <> 'dismissed'),
    'recount_overrides_applied',
       (select count(*) from (
          select distinct r.master_item_id, coalesce(r.zone, '')
            from public.kount_recounts r
           where r.audit_id = p_audit_id
             and r.master_item_id is not null
             and r.count2_qty is not null
             and r.status <> 'dismissed'
        ) t)
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

comment on function public.compute_avt_for_audit(uuid) is
  'Computes a kount_avt_reports + kount_avt_rows pair for the given audit from in-DB data (kount_entries + kount_recounts overrides, v_effective_receipts, pos_check_items, recipes/maps). v3 (0035): recount corrections replace per-zone entry sums; depletions dedup per POS item then SUM; window end falls back to completed_at. Idempotent: re-running replaces the prior computed report for the same audit. Never touches uploaded reports.';

-- -----------------------------------------------------------------------------
-- Provenance view — recreated to match the v3 RPC. DEBUG-ONLY: never on the
-- hot path, re-walks the join chain read-only for one report at a time.
-- Changes vs 0030: src_new_recipe joins the bridge by NAME (the 0032 RPC
-- fix that this view never received), and the audit window uses
-- coalesce(count2_closed_at, completed_at) like the RPC.
-- -----------------------------------------------------------------------------
create or replace view public.v_kount_avt_row_provenance as
with rows_with_master as (
  select r.id            as report_id,
         r.audit_id,
         r.computed_at,
         row_.id         as row_id,
         row_.item_name,
         row_.venue_id   as kount_venue_id,
         mi.id           as master_item_id,
         kv.ops_venue_id
    from public.kount_avt_reports r
    join public.kount_avt_rows    row_ on row_.report_id = r.id
    left join public.master_items mi on lower(mi.name) = lower(row_.item_name)
    left join public.kount_venues kv on kv.id = row_.venue_id
   where r.source = 'computed'
),
audit_window as (
  select a.id as audit_id,
         coalesce(a.count2_closed_at, a.completed_at) as window_end,
         (select coalesce(prev.count2_closed_at, prev.completed_at)
            from public.kount_audits prev
           where prev.venue_id = a.venue_id and prev.status='submitted'
             and prev.id <> a.id
             and coalesce(prev.count2_closed_at, prev.completed_at)
                 < coalesce(a.count2_closed_at, a.completed_at)
           order by coalesce(prev.count2_closed_at, prev.completed_at) desc
           limit 1) as window_start
    from public.kount_audits a
),
src_direct as (
  select distinct rwm.row_id
    from rows_with_master rwm
    join audit_window aw on aw.audit_id = rwm.audit_id
    join public.menu_item_recipe_map mirm
      on mirm.venue_id = rwm.ops_venue_id
     and mirm.master_item_id = rwm.master_item_id
     and mirm.is_active = true
     and coalesce(mirm.is_excluded, false) = false
    join public.pos_check_items pci
      on pci.venue_id = mirm.venue_id
     and pci.item_name = mirm.menu_item_name
     and pci.business_date >= coalesce(aw.window_start::date, '-infinity'::date)
     and pci.business_date <  aw.window_end::date
),
src_old_recipe as (
  select distinct rwm.row_id
    from rows_with_master rwm
    join audit_window aw on aw.audit_id = rwm.audit_id
    join public.purchase_items pi      on pi.master_item_id = rwm.master_item_id
    join public.recipe_items ri        on ri.item_id = pi.id
                                       and coalesce(ri.is_packaging, false) = false
    join public.menu_item_recipe_map mirm
      on mirm.venue_id = rwm.ops_venue_id
     and mirm.recipe_id = ri.recipe_id
     and mirm.is_active = true
    join public.pos_check_items pci
      on pci.venue_id = mirm.venue_id
     and pci.item_name = mirm.menu_item_name
     and pci.business_date >= coalesce(aw.window_start::date, '-infinity'::date)
     and pci.business_date <  aw.window_end::date
),
src_new_recipe as (
  select distinct rwm.row_id
    from rows_with_master rwm
    join audit_window aw on aw.audit_id = rwm.audit_id
    join public.new_recipe_ingredient_master_map nrimm
      on nrimm.master_item_id = rwm.master_item_id
    join public.new_recipe_ingredients nri
      on nri.ingredient_name = nrimm.ingredient_name
     and coalesce(nri.is_sub_recipe, false) = false
    join public.new_recipe_pos_skus nrps
      on nrps.recipe_id = nri.recipe_id
     and nrps.venue_id  = rwm.ops_venue_id
    join public.pos_check_items pci
      on pci.venue_id = nrps.venue_id
     -- FIX 0035: name join, matching the RPC since 0032 (bridge stores menu
     -- item names, not POS UUIDs).
     and lower(trim(nrps.pos_sku)) = lower(trim(pci.item_name))
     and pci.business_date >= coalesce(aw.window_start::date, '-infinity'::date)
     and pci.business_date <  aw.window_end::date
)
select rwm.report_id,
       rwm.audit_id,
       rwm.computed_at,
       rwm.row_id,
       rwm.item_name,
       rwm.master_item_id,
       case
         when sd.row_id is not null and (so.row_id is not null or sn.row_id is not null)
           then 'multi'
         when sd.row_id is not null then 'direct'
         when so.row_id is not null then 'old_recipe'
         when sn.row_id is not null then 'new_recipe'
         else 'none'
       end as depletion_source,
       (sd.row_id is not null) as has_direct,
       (so.row_id is not null) as has_old_recipe,
       (sn.row_id is not null) as has_new_recipe
  from rows_with_master rwm
  left join src_direct     sd on sd.row_id = rwm.row_id
  left join src_old_recipe so on so.row_id = rwm.row_id
  left join src_new_recipe sn on sn.row_id = rwm.row_id;

comment on view public.v_kount_avt_row_provenance is
  'Debug view: for each row of a computed kount_avt_reports, identifies which depletion source(s) (direct / old_recipe / new_recipe) would have contributed. Re-walks the join chain read-only. 0035: new_recipe arm uses the name join to match the RPC.';

commit;

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
--
-- 1. Recompute a known audit and check notes:
--      select compute_avt_for_audit('<audit-id>');
--      select notes from kount_avt_reports
--       where audit_id = '<audit-id>' and source = 'computed';
--    Expect recount_overrides_applied present (0 for audits with no recounts).
--
-- 2. Recount override: pick an audit with a done recount (count2_qty set);
--    the actual for that master should equal SUM(other zones) + count2_qty,
--    not the raw entries sum.
--
-- 3. Historic Summary-shortcut audits (count2_closed_at null,
--    completed_at set) now compute instead of raising 22023:
--      select id from kount_audits
--       where status='submitted' and count2_closed_at is null
--         and completed_at is not null limit 1;
--
-- 4. View parity: depletion_source coverage should rise for cocktail masters
--      select depletion_source, count(*)
--        from v_kount_avt_row_provenance
--       where report_id = '<report-id>' group by 1;
