-- =============================================================================
--  0030_kount_avt_computed
--
--  Replaces the Counting app's Craftable AVT-upload dependency with an
--  in-DB computed pipeline. At audit-close time, an RPC computes the
--  same `kount_avt_rows` shape from data already in this Supabase
--  (kount_entries, v_effective_receipts, pos_check_items, recipes/maps),
--  writes a `kount_avt_reports` row tagged source='computed', and lets
--  the existing Variance UI render it unchanged.
--
--  This migration is ADDITIVE only:
--    A) Bridge column kount_venues.ops_venue_id (kount text id <-> ops uuid)
--    B) Extend kount_avt_reports with source / audit_id / computed_at
--    C) Two empty bridge tables (admin populates later):
--         - new_recipe_pos_skus            (venue+sku -> new_recipes.id)
--         - new_recipe_ingredient_master_map (ingredient_name -> master_items.id)
--    D) RPC compute_avt_for_audit(p_audit_id uuid) returns uuid
--    E) v_kount_avt_row_provenance view (debug-only)
--
--  Re-running is safe: every DDL uses IF [NOT] EXISTS and the RPC is
--  idempotent per (audit_id) -- it replaces the prior computed report
--  but never touches uploaded ones.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A) Bridge column on kount_venues
-- -----------------------------------------------------------------------------
alter table public.kount_venues
  add column if not exists ops_venue_id uuid references public.venues(id) on delete set null;

comment on column public.kount_venues.ops_venue_id is
  'Bridge to ops-side venues.id (uuid). Populated where a name match exists; admin fills the rest.';

-- Best-effort seed: case-insensitive name match. Only fills rows still NULL,
-- so this is safe to re-run.
update public.kount_venues kv
   set ops_venue_id = v.id
  from public.venues v
 where kv.ops_venue_id is null
   and lower(v.name) = lower(kv.name);

-- -----------------------------------------------------------------------------
-- B) Extend kount_avt_reports
-- -----------------------------------------------------------------------------
alter table public.kount_avt_reports
  add column if not exists source       text         not null default 'uploaded',
  add column if not exists audit_id     uuid         references public.kount_audits(id) on delete set null,
  add column if not exists computed_at  timestamptz;

-- Add CHECK constraint only if missing (can't `add constraint if not exists`).
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.kount_avt_reports'::regclass
       and conname  = 'kount_avt_reports_source_check'
  ) then
    alter table public.kount_avt_reports
      add constraint kount_avt_reports_source_check
      check (source in ('uploaded','computed'));
  end if;
end$$;

-- One computed report per audit. Uploaded reports are unconstrained.
create unique index if not exists kount_avt_reports_audit_computed_uniq
  on public.kount_avt_reports(audit_id) where source = 'computed';

-- -----------------------------------------------------------------------------
-- C) Bridge tables (start empty; admin populates)
-- -----------------------------------------------------------------------------
create table if not exists public.new_recipe_pos_skus (
  recipe_id  uuid not null references public.new_recipes(id) on delete cascade,
  pos_sku    text not null,
  venue_id   uuid not null references public.venues(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (recipe_id, venue_id, pos_sku)
);
create index if not exists new_recipe_pos_skus_lookup
  on public.new_recipe_pos_skus(venue_id, pos_sku);

create table if not exists public.new_recipe_ingredient_master_map (
  ingredient_name text primary key,
  master_item_id  uuid not null references public.master_items(id) on delete cascade,
  base_qty        numeric not null default 1,
  base_uom        text,
  created_at      timestamptz not null default now()
);

-- RLS mirrors 0028_master_items_admin_only: SELECT open to authenticated,
-- writes restricted to active corporate admins via app_users.
alter table public.new_recipe_pos_skus enable row level security;
alter table public.new_recipe_ingredient_master_map enable row level security;

-- new_recipe_pos_skus -----------------------------------------------------
drop policy if exists "new_recipe_pos_skus_select_auth" on public.new_recipe_pos_skus;
create policy "new_recipe_pos_skus_select_auth"
  on public.new_recipe_pos_skus for select
  to authenticated
  using (true);

drop policy if exists "new_recipe_pos_skus_insert_corporate" on public.new_recipe_pos_skus;
create policy "new_recipe_pos_skus_insert_corporate"
  on public.new_recipe_pos_skus for insert
  to authenticated
  with check (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

drop policy if exists "new_recipe_pos_skus_update_corporate" on public.new_recipe_pos_skus;
create policy "new_recipe_pos_skus_update_corporate"
  on public.new_recipe_pos_skus for update
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  )
  with check (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

drop policy if exists "new_recipe_pos_skus_delete_corporate" on public.new_recipe_pos_skus;
create policy "new_recipe_pos_skus_delete_corporate"
  on public.new_recipe_pos_skus for delete
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

-- new_recipe_ingredient_master_map ---------------------------------------
drop policy if exists "new_recipe_ing_map_select_auth" on public.new_recipe_ingredient_master_map;
create policy "new_recipe_ing_map_select_auth"
  on public.new_recipe_ingredient_master_map for select
  to authenticated
  using (true);

drop policy if exists "new_recipe_ing_map_insert_corporate" on public.new_recipe_ingredient_master_map;
create policy "new_recipe_ing_map_insert_corporate"
  on public.new_recipe_ingredient_master_map for insert
  to authenticated
  with check (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

drop policy if exists "new_recipe_ing_map_update_corporate" on public.new_recipe_ingredient_master_map;
create policy "new_recipe_ing_map_update_corporate"
  on public.new_recipe_ingredient_master_map for update
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  )
  with check (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

drop policy if exists "new_recipe_ing_map_delete_corporate" on public.new_recipe_ingredient_master_map;
create policy "new_recipe_ing_map_delete_corporate"
  on public.new_recipe_ingredient_master_map for delete
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

-- -----------------------------------------------------------------------------
-- D) RPC: compute_avt_for_audit(p_audit_id uuid) returns uuid
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER so the caller doesn't need direct write grants on
-- kount_avt_reports/_rows. search_path is pinned to public to defuse
-- the standard SECURITY DEFINER hijack vector.
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

  -- 1b) Authorization gate. SECURITY DEFINER would otherwise let any
  --     authenticated caller materialize ANY venue's audit into
  --     kount_avt_reports/_rows — and the SELECT policies on those tables
  --     (see 0002_kount_avt.sql + 0016_extend_dev_policies_to_authenticated.sql)
  --     are `to authenticated using (true)`, so anyone could then read it.
  --     Until per-venue SELECT policies land, gate the RPC itself:
  --       corporate -> compute any audit
  --       manager/counter -> only audits for venues in app_users.venue_ids
  --     Mirrors the app_users predicate shape from 0028_master_items_admin_only.
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
  -- NULL means "first audit ever for this venue" -> treat purchases/POS as
  -- unbounded on the lower side.
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
  --    The unique index on (audit_id) where source='computed' enforces
  --    at-most-one going forward.
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
     null)  -- notes patched below once we know depletion-source counts
  returning id into v_report_id;

  -- 4) Build all the math in one statement so CTEs can FULL OUTER JOIN.
  with
  -- 4a) Actuals = sum(kount_entries.qty) for THIS audit. Recount overrides
  --     count1 ONLY for the same (master_item_id, zone) pair, then sum
  --     across zones. Mirrors the phone's per-zone recount model: see
  --     counting-app.html:10781-10788 (closeCount1 generates one recount
  --     row per (item, zone), each row tracks its own count1Qty +
  --     recountQty independently). kount_entries is unique on
  --     (audit_id, zone, lower(item_name), is_recount) per
  --     0001_multi_user_audits.sql:108-113, so partitioning by
  --     master_item_id alone would silently drop count1 in zones B/C
  --     when a recount existed only in zone A.
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
  -- 4b) Starts = same per-(master, zone) recount-override logic but for
  --     the prior audit (null-safe).
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
  -- 4c) Purchases from v_effective_receipts in (window_start, window_end].
  --     Joins through invoices for venue_id (the view itself has none).
  --     Returns empty if ops_venue_id is null -> notes flag will say so.
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
  -- 4d) Depletions, source #1: direct master_item_id on menu_item_recipe_map
  --     (1,788 rows today). Pulls POS quantity from pos_check_items by
  --     business_date in [window_start_date, window_end_date).
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
  -- 4e) Depletions, source #2: old recipes (recipe_items -> purchase_items
  --     -> master_item_id). recipe_items is empty + mirm.recipe_id is null
  --     everywhere today, so this returns 0 rows. The chain is wired so
  --     the path activates when those populate.
  --     TODO: UoM conversion when recipes populate (currently treats
  --     recipe_items.qty as 1:1 with master_item base unit).
  --
  --     Pre-aggregate ingredients per (recipe_id, master_item_id) BEFORE
  --     joining to POS. Without this, a recipe with two ingredient lines
  --     both pointing at the same master_item_id would multiply the POS
  --     quantity twice for that master at the outer GROUP BY.
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
  -- 4f) Depletions, source #3: new_recipes via the two empty bridge
  --     tables introduced above. Returns 0 rows until admin populates.
  --     TODO: UoM conversion when bridges populate (currently treats
  --     nri.quantity * nrimm.base_qty as 1:1 with master_item base unit).
  --
  --     Same pre-aggregation trick as dep_old_recipe: collapse the
  --     ingredient legs to one (recipe_id, master_item_id) row BEFORE
  --     joining to POS so two ingredient lines mapped to the same master
  --     don't double-count the POS quantity.
  new_recipe_per_master as (
    select nri.recipe_id, nrimm.master_item_id,
           sum(coalesce(nri.quantity, 0) * coalesce(nrimm.base_qty, 1))::numeric as ing_qty
      from public.new_recipe_ingredients nri
      join public.new_recipe_ingredient_master_map nrimm
        on nrimm.ingredient_name = nri.ingredient_name
     where coalesce(nri.is_sub_recipe, false) = false
     group by nri.recipe_id, nrimm.master_item_id
  ),
  dep_new_recipe as (
    select nrpm.master_item_id, sum(pci.quantity * nrpm.ing_qty)::numeric as qty
      from public.pos_check_items pci
      join public.new_recipe_pos_skus nrps
        on nrps.venue_id = pci.venue_id
       and nrps.pos_sku  = pci.external_item_id
      join new_recipe_per_master nrpm
        on nrpm.recipe_id = nrps.recipe_id
     where v_ops_venue_id is not null
       and pci.venue_id = v_ops_venue_id
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by nrpm.master_item_id
  ),
  -- 4g) Combine depletion sources with GREATEST, not SUM, to avoid
  --     double-counting if both direct + recipe wire fire for one master.
  dep_total as (
    select coalesce(d.master_item_id, o.master_item_id, n.master_item_id) as master_item_id,
           greatest(coalesce(d.qty, 0), coalesce(o.qty, 0), coalesce(n.qty, 0)) as qty
      from dep_direct d
      full outer join dep_old_recipe o using (master_item_id)
      full outer join dep_new_recipe n using (master_item_id)
  ),
  -- 4h) CU price: most-recent purchase_items.avg_cost per master_item_id.
  prices as (
    select distinct on (master_item_id)
           master_item_id, avg_cost
      from public.purchase_items
     where master_item_id is not null
       and avg_cost is not null
     order by master_item_id, updated_at desc nulls last
  ),
  -- 4i) Union all masters that appear in ANY source so the variance UI
  --     sees missing-from-count items too.
  all_masters as (
    select master_item_id from actuals
    union
    select master_item_id from starts
    union
    select master_item_id from purchases
    union
    select master_item_id from dep_total
  ),
  -- 4j) Final row shape. theo = start + purchases - depletions.
  --     variance       = actual - theo
  --     variance_value = variance * cu_price
  --     variance_pct   = variance / NULLIF(theo, 0) * 100
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
grant execute on function public.compute_avt_for_audit(uuid) to authenticated;

comment on function public.compute_avt_for_audit(uuid) is
  'Computes a kount_avt_reports + kount_avt_rows pair for the given audit '
  'from in-DB data (kount_entries, v_effective_receipts, pos_check_items, '
  'recipes/maps). Idempotent: re-running replaces the prior computed '
  'report for the same audit. Never touches uploaded reports.';

-- -----------------------------------------------------------------------------
-- E) Provenance view (debug-only; not on the hot path)
-- -----------------------------------------------------------------------------
-- For each kount_avt_rows row of a computed report, resolves the
-- master_item_id back by name and tags which depletion source(s) would
-- have contributed. The math here re-walks the join chain from the RPC.
-- Read-only, cheap enough for a single report at a time.
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
         a.count2_closed_at as window_end,
         (select prev.count2_closed_at
            from public.kount_audits prev
           where prev.venue_id = a.venue_id and prev.status='submitted'
             and prev.id <> a.id
             and prev.count2_closed_at < a.count2_closed_at
           order by prev.count2_closed_at desc limit 1) as window_start
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
     and pci.external_item_id = nrps.pos_sku
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
  'Debug view: for each row of a computed kount_avt_reports, identifies '
  'which depletion source(s) (direct / old_recipe / new_recipe) would '
  'have contributed. Re-walks the join chain read-only.';

-- =============================================================================
-- Verification queries (run by hand after apply):
--
--   select count(*) from kount_avt_reports where source='uploaded';
--   -- expect: 28 (every pre-existing row defaulted correctly)
--
--   select count(*) from kount_venues where ops_venue_id is not null;
--   -- expect: 4 (Poppy / Keys / Bootsy Bellows / 40 Love name matches)
--
--   select compute_avt_for_audit('72249a5d-9626-4414-bdcf-52522a894fbe');
--   -- expect: a uuid; re-running returns a different uuid and the
--   -- previous report row is gone (idempotent on audit_id).
--
--   select count(*) from kount_avt_rows where report_id = '<returned-id>';
--   -- expect: > 0
-- =============================================================================
