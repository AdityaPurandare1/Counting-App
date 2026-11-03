-- ROLLBACK for 0149_kount_permission_gates: the role gates as they were live on 2026-11-03 (saved before 0149).
begin;
CREATE OR REPLACE FUNCTION public.approve_upc_mapping(p_mapping_id uuid, p_admin_email text, p_admin_name text DEFAULT NULL::text, p_master_item_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec               public.upc_mappings;
  target_master_id  uuid;
  upc_norm          text;
  match_count       int;
  matched_by        text := 'none';
begin
  -- Authorization (added 2026-09-08). This function is SECURITY DEFINER and
  -- previously had NO internal check: it trusted p_admin_email, a value the
  -- caller supplies, and wrote it straight into reviewed_by_email. It was
  -- reachable only because Supabase's default PUBLIC EXECUTE grant was in
  -- place; once that was correctly revoked, granting EXECUTE back to
  -- authenticated without this gate would let any signed-in user approve
  -- catalog and barcode changes with owner privileges.
  -- corporate|manager mirrors both existing callers: the phone's
  -- approveUPCPending role check and the admin's /approvals route gate.
  -- NOTE: reads the VERIFIED JWT claim, never the p_admin_email argument.
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and u.role in ('corporate', 'admin', 'manager', 'venue_manager')
  ) then
    raise exception 'not authorized: approve_upc_mapping is corporate/manager only'
      using errcode = '42501';
  end if;
  -- 1. Lock + flip the mapping to approved.
  update public.upc_mappings
     set status            = 'approved',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now()
   where id     = p_mapping_id
     and status = 'pending'
   returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Mapping not found or already finalized');
  end if;

  -- 2. Decide which master_item this UPC attaches to.
  --    Priority: caller-supplied override > mapping's own master_item_id >
  --    name-fallback against master_items.
  if p_master_item_id is not null then
    target_master_id := p_master_item_id;
    matched_by := 'caller_supplied';
  elsif rec.master_item_id is not null then
    target_master_id := rec.master_item_id;
    matched_by := 'mapping_master_item_id';
  else
    -- Fallback: exact case-insensitive name match against ACTIVE masters
    -- with no UPC already attached to them via master_item_upcs.
    -- v0057 CRASH FIX: was `max(mi.id)`. mi.id is uuid and PostgreSQL has no
    -- max(uuid) before 18 (this cluster is 17.6), so EVERY call that reached
    -- this branch aborted with 42883 "function max(uuid) does not exist" â€”
    -- see the header. array_agg has no such gap; `order by mi.id` keeps the
    -- pick deterministic, and when zero rows match array_agg returns NULL so
    -- the [1] subscript yields NULL and match_count = 0 routes to the
    -- no-match branch exactly as intended.
    select count(*), (array_agg(mi.id order by mi.id))[1]
      into match_count, target_master_id
      from public.master_items mi
     where lower(mi.name) = lower(rec.item_name)
       and mi.is_active = true
       and not exists (
         select 1 from public.master_item_upcs miu where miu.master_item_id = mi.id
       );
    if match_count = 1 then
      matched_by := 'name';
    elsif match_count > 1 then
      matched_by := 'ambiguous-name';
      -- v0057 ROLLBACK: undo the step-1 flip so the mapping stays 'pending'
      -- and retryable. Without this the row is stranded 'approved' with no
      -- master_item_upcs link and every retry returns "already finalized".
      -- target_master_id is NOT written back (step 4 is never reached), so
      -- the row returns to exactly its pre-call state.
      update public.upc_mappings
         set status            = 'pending',
             reviewed_at       = null,
             reviewed_by_email = null,
             reviewed_by_name  = null
       where id = rec.id;
      return jsonb_build_object('ok', false, 'error', 'Multiple master_items match the name; admin must pick explicitly');
    else
      matched_by := 'no-match';
      -- v0057 ROLLBACK: same compensation for the no-match branch.
      update public.upc_mappings
         set status            = 'pending',
             reviewed_at       = null,
             reviewed_by_email = null,
             reviewed_by_name  = null
       where id = rec.id;
      return jsonb_build_object('ok', false, 'error', 'No master_items match the item_name; admin must pick explicitly');
    end if;
  end if;

  -- 3. Insert into master_item_upcs. Normalize the UPC to match the column
  --    invariant (digits only, no leading zeros). If a row already exists
  --    for this UPC, the unique index makes this a no-op via ON CONFLICT.
  upc_norm := regexp_replace(regexp_replace(trim(coalesce(rec.barcode_raw, '')), '[^0-9]', '', 'g'), '^0+', '');
  if upc_norm = '' then
    return jsonb_build_object(
      'ok', true, 'id', rec.id,
      'matched_by', matched_by, 'master_item_id', target_master_id,
      'warning', 'No digits in barcode â€” no master_item_upcs row created'
    );
  end if;

  insert into public.master_item_upcs
    (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
  values (
    target_master_id,
    trim(rec.barcode_raw),
    upc_norm,
    'scan_approved',
    'Approved via approve_upc_mapping (' || matched_by || ')',
    p_admin_email
  )
  on conflict (upc_normalized) do nothing;

  -- 4. Write master_item_id back onto the mapping so future lookups are clean.
  update public.upc_mappings
     set master_item_id = target_master_id
   where id = rec.id
     and master_item_id is null;

  return jsonb_build_object(
    'ok', true,
    'id', rec.id,
    'matched_by', matched_by,
    'master_item_id', target_master_id
  );
end;
$function$;
CREATE OR REPLACE FUNCTION public.import_inventory_csv(p_items jsonb, p_replace boolean DEFAULT false, p_actor_email text DEFAULT 'admin@hwoodgroup.com'::text, p_actor_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_inserted_master    int := 0;
  v_updated_master     int := 0;
  v_added_carried      int := 0;
  v_removed_carried    int := 0;
  v_skipped            int := 0;
  v_unresolved_master  int := 0;
  v_item               jsonb;
  v_pid                uuid;
  v_existing_id        uuid;
  v_csv_pids           uuid[] := '{}';
  v_name               text;
  v_upc                text;
  v_upc_norm           text;
  v_master_id          uuid;
  v_carried_id         uuid;
  v_caller_email       text;
begin
  -- 0017 lockdown (unchanged): caller must be a corporate-role authenticated
  -- user. Email comes from the JWT, NOT from p_actor_email â€” that parameter
  -- is caller-controlled and is used only as the audit-column value.
  v_caller_email := lower(coalesce((auth.jwt() ->> 'email'), ''));
  if v_caller_email = '' then
    raise exception 'import_inventory_csv requires an authenticated session';
  end if;
  if not exists (
    select 1 from public.app_users
     where lower(email) = v_caller_email
       and role = any (array['corporate','admin'])
       and is_active = true
  ) then
    raise exception 'import_inventory_csv requires corporate role; caller % is not authorized', v_caller_email;
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a jsonb array';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_name := nullif(trim(v_item->>'name'), '');
    if v_name is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_upc := nullif(trim(v_item->>'upc'), '');
    v_existing_id := null;

    -- Match priority: UPC first (definitive), then case-insensitive name.
    if v_upc is not null then
      select id into v_existing_id
        from public.purchase_items
       where upc = v_upc
       limit 1;
    end if;
    if v_existing_id is null then
      select id into v_existing_id
        from public.purchase_items
       where lower(name) = lower(v_name)
       limit 1;
    end if;

    if v_existing_id is not null then
      -- Existing master row â€” enrich with any non-empty CSV fields. We
      -- COALESCE so a blank CSV cell never wipes an existing value.
      update public.purchase_items
         set name        = coalesce(nullif(trim(v_item->>'name'),     ''), name),
             brand       = coalesce(nullif(trim(v_item->>'brand'),    ''), brand),
             size        = coalesce(nullif(trim(v_item->>'size'),     ''), size),
             upc         = coalesce(nullif(trim(v_item->>'upc'),      ''), upc),
             category    = coalesce(nullif(trim(v_item->>'category'), ''), category),
             sku         = coalesce(nullif(trim(v_item->>'sku'),      ''), sku)
       where id = v_existing_id;
      v_pid := v_existing_id;
      v_updated_master := v_updated_master + 1;
    else
      -- New purchase_items row. FIX 0034: 0015/0017 listed 7 target columns
      -- but only 6 values (is_active had no expression) â€” this branch has
      -- never worked. New rows are explicitly active.
      insert into public.purchase_items (name, brand, size, upc, category, sku, is_active)
      values (
        v_name,
        nullif(trim(v_item->>'brand'),    ''),
        nullif(trim(v_item->>'size'),     ''),
        v_upc,
        nullif(trim(v_item->>'category'), ''),
        nullif(trim(v_item->>'sku'),      ''),
        true
      )
      returning id into v_pid;
      v_inserted_master := v_inserted_master + 1;
    end if;

    v_csv_pids := array_append(v_csv_pids, v_pid);

    -- Path B (0034): resolve the master for the carried row.
    --   1. master_item_upcs lookup on the normalized UPC (digits only,
    --      leading zeros stripped â€” same normalization as 0020).
    --   2. else case-insensitive name match against ACTIVE master_items.
    --   3. else NULL (counted in unresolved_master_count).
    v_master_id := null;
    v_upc_norm  := case
      when v_upc is not null
      then nullif(regexp_replace(regexp_replace(v_upc, '[^0-9]', '', 'g'), '^0+', ''), '')
    end;
    if v_upc_norm is not null then
      select master_item_id into v_master_id
        from public.master_item_upcs
       where upc_normalized = v_upc_norm
       limit 1;
    end if;
    if v_master_id is null then
      select id into v_master_id
        from public.master_items
       where lower(name) = lower(v_name)
         and is_active = true
       limit 1;
    end if;
    if v_master_id is null then
      v_unresolved_master := v_unresolved_master + 1;
    end if;

    -- Mark carried. Two unique keys now exist (purchase_item_id AND
    -- master_item_id, both from 0033) and ON CONFLICT can only arbitrate on
    -- one, so we resolve the existing row explicitly instead. Master match
    -- is checked first â€” it's the key both clients read by. Existing rows
    -- are only backfilled (never overwritten), and audit columns are not
    -- bumped, so re-uploading the same CSV stays idempotent.
    v_carried_id := null;
    if v_master_id is not null then
      select id into v_carried_id
        from public.kount_carried_items
       where master_item_id = v_master_id
       limit 1;
    end if;

    if v_carried_id is not null then
      -- Master-keyed row exists: backfill its purchase link, but only if no
      -- OTHER row already holds this purchase_item_id (unique index).
      update public.kount_carried_items
         set purchase_item_id = v_pid
       where id = v_carried_id
         and purchase_item_id is null
         and not exists (
           select 1 from public.kount_carried_items x
            where x.purchase_item_id = v_pid
         );
    else
      select id into v_carried_id
        from public.kount_carried_items
       where purchase_item_id = v_pid
       limit 1;

      if v_carried_id is not null then
        -- Purchase-keyed row exists: backfill the master link. Safe â€” we
        -- just verified no row carries v_master_id.
        update public.kount_carried_items
           set master_item_id = v_master_id
         where id = v_carried_id
           and master_item_id is null
           and v_master_id is not null;
      else
        insert into public.kount_carried_items (
          purchase_item_id, master_item_id, added_by_email, added_by_name, notes
        )
        values (v_pid, v_master_id, p_actor_email, p_actor_name, 'imported via CSV');
        v_added_carried := v_added_carried + 1;
      end if;
    end if;
  end loop;

  -- Replace mode: ONLY purchase-only rows (master_item_id IS NULL) not in
  -- this CSV are removed. Master-curated rows are NEVER deleted here: the
  -- phone and admin catalog both read `master_item_id is not null`, so the
  -- pre-0034 unconditional delete let a CSV upload wipe the live curated
  -- catalog. Curated rows are removed only via the admin Catalog toggle.
  -- Still skipped entirely if the CSV was empty (defensive).
  if p_replace and array_length(v_csv_pids, 1) > 0 then
    with deleted as (
      delete from public.kount_carried_items
       where master_item_id is null
         and purchase_item_id is not null
         and not (purchase_item_id = any(v_csv_pids))
       returning 1
    )
    select count(*) into v_removed_carried from deleted;
  end if;

  return jsonb_build_object(
    'inserted_master',         v_inserted_master,
    'updated_master',          v_updated_master,
    'added_carried',           v_added_carried,
    'removed_carried',         v_removed_carried,
    'skipped',                 v_skipped,
    'unresolved_master_count', v_unresolved_master
  );
end;
$function$;
CREATE OR REPLACE FUNCTION public.kount_bev_purchase_lines(p_from date, p_to date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;
CREATE OR REPLACE FUNCTION public.kount_catalog_prices(p_master_ids uuid[])
 RETURNS TABLE(id uuid, master_item_id uuid, avg_cost numeric, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active
       and u.role = any (array['corporate', 'admin', 'manager'])
  ) then
    raise exception 'Only Kount managers and corporate users can read catalog costs.'
      using errcode = '42501';
  end if;

  return query
  select distinct on (p.master_item_id) p.id, p.master_item_id, p.avg_cost, p.updated_at
    from public.purchase_items p
   where p.master_item_id = any (coalesce(p_master_ids, '{}'))
     and p.avg_cost is not null
   order by p.master_item_id, p.updated_at desc nulls last, p.id desc;
end;
$function$;
CREATE OR REPLACE FUNCTION public.kount_create_transfer(p_from_venue text, p_to_venue text, p_transferred_at timestamp with time zone, p_transferred_by text, p_note text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_role text; f record; t record; v_id uuid; v_total numeric; v_codes text[];
begin
  select u.role into v_role from public.app_users u where lower(u.email) = v_email and u.is_active;
  if v_role is null or v_role = 'counter' then raise exception 'not allowed to record transfers' using errcode = '42501'; end if;
  if p_from_venue is null or p_to_venue is null or p_from_venue = p_to_venue then
    raise exception 'pick two different venues' using errcode = '22023';
  end if;
  if not public.kount_can_see_venue(p_from_venue) or not public.kount_can_see_venue(p_to_venue) then
    raise exception 'you need access to both venues' using errcode = '42501';
  end if;
  select kv.id, kv.name, kv.ops_venue_id, v.organization_id into f
    from public.kount_venues kv left join public.venues v on v.id = kv.ops_venue_id where kv.id = p_from_venue;
  select kv.id, kv.name, kv.ops_venue_id into t from public.kount_venues kv where kv.id = p_to_venue;
  if f.ops_venue_id is null or t.ops_venue_id is null then raise exception 'venue is not linked to KevaOS' using errcode = '22023'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'add at least one item' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) e
              where coalesce((e->>'qty')::numeric, 0) <= 0
                 or not exists (select 1 from public.master_items m where m.id = (e->>'master_item_id')::uuid and m.is_active)) then
    raise exception 'every line needs an active item and a quantity above 0' using errcode = '22023';
  end if;

  create temp table _xl on commit drop as
  select (e->>'master_item_id')::uuid as mid, (e->>'qty')::numeric as qty,
         coalesce(nullif(e->>'unit_cost', '')::numeric,
                  (select o.cost_per_unit from public.kount_venue_cost_overrides o where o.venue_id = p_from_venue and o.master_item_id = (e->>'master_item_id')::uuid),
                  (select p.avg_cost from public.purchase_items p where p.master_item_id = (e->>'master_item_id')::uuid and p.avg_cost > 0 order by p.updated_at desc nulls last limit 1)) as unit_cost
    from jsonb_array_elements(p_lines) e;
  select round(coalesce(sum(qty * unit_cost), 0), 2) into v_total from _xl;

  insert into public.transfers (transfer_date, from_venue_id, to_venue_id, from_venue_name, to_venue_name, total_amount,
                                organization_id, external_source, note, created_by_email, transferred_at, transferred_by)
  values ((coalesce(p_transferred_at, now()) at time zone 'America/Los_Angeles')::date, f.ops_venue_id, t.ops_venue_id, f.name, t.name, v_total,
          f.organization_id, 'kount-admin', nullif(trim(coalesce(p_note, '')), ''), v_email, coalesce(p_transferred_at, now()),
          nullif(trim(coalesce(p_transferred_by, '')), ''))
  returning id into v_id;

  insert into public.transfer_lines (transfer_id, master_item_id, description, qty, unit_cost, line_total)
  select v_id, x.mid, m.name, x.qty, x.unit_cost, round(x.qty * coalesce(x.unit_cost, 0), 2)
    from _xl x join public.master_items m on m.id = x.mid;
  drop table _xl;

  v_codes := public.kount_transfer_recompute(v_id);
  return jsonb_build_object('id', v_id, 'total', v_total, 'recomputed', to_jsonb(v_codes));
end $function$;
CREATE OR REPLACE FUNCTION public.kount_delete_transfer(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_role text; v_by text; v_from uuid; v_to uuid; v_codes text[] := '{}'; r record;
begin
  select u.role into v_role from public.app_users u where lower(u.email) = v_email and u.is_active;
  select lower(coalesce(created_by_email, '')), from_venue_id, to_venue_id into v_by, v_from, v_to from public.transfers where id = p_id;
  if not found then raise exception 'transfer not found' using errcode = 'P0002'; end if;
  if v_role is null or not (v_role in ('admin', 'corporate') or v_by = v_email) then
    raise exception 'only an admin or the person who recorded it can delete a transfer' using errcode = '42501';
  end if;
  -- find the affected audits before the row goes, recompute after
  create temp table _xa on commit drop as
  select distinct on (a.venue_id) a.id, a.join_code
    from public.transfers t
    join public.kount_venues kv on kv.ops_venue_id in (t.from_venue_id, t.to_venue_id)
    join public.kount_audits a on a.venue_id = kv.id
   where t.id = p_id and a.status = 'submitted'
     and coalesce(a.count2_closed_at, a.completed_at, a.count1_closed_at) > coalesce(t.transferred_at, t.transfer_date::timestamptz)
   order by a.venue_id, coalesce(a.count2_closed_at, a.completed_at, a.count1_closed_at);
  delete from public.transfers where id = p_id;
  for r in select * from _xa loop perform public.compute_avt_for_audit(r.id); v_codes := v_codes || r.join_code; end loop;
  drop table _xa;
  return jsonb_build_object('deleted', p_id, 'recomputed', to_jsonb(v_codes));
end $function$;
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
begin
  -- 0. Authorization. Corporate/admin anywhere; manager only at their venue.
  --    Reads the VERIFIED JWT claim, never a caller-supplied argument.
  select u.name into v_name
    from public.app_users u
   where lower(u.email) = v_email
     and u.is_active = true
     and (
       u.role in ('corporate', 'admin')
       or (u.role = 'manager' and p_venue_id = any(u.venue_ids))
     );
  if not found then
    raise exception 'not authorized to import a food count for %', p_venue_id
      using errcode = '42501';
  end if;

  select kv.name into v_venue_name from public.kount_venues kv where kv.id = p_venue_id;
  if v_venue_name is null then
    raise exception 'unknown kount venue %', p_venue_id using errcode = 'P0002';
  end if;

  -- 1. Clean the sheet rows. Drops blanks and the per-sheet "TOTAL" subtotal
  --    rows (5 of them in the Little Luck workbook) which are not items.
  create temp table _food_rows on commit drop as
  select
    row_number() over ()                                   as rn,
    btrim(r ->> 'item')                                    as item,
    nullif(btrim(lower(coalesce(r ->> 'unit', ''))), '')   as count_unit,
    nullif(r ->> 'pack', '')::numeric                      as units_per_case,
    nullif(r ->> 'qty', '')::numeric                       as qty,
    nullif(r ->> 'price', '')::numeric                     as price,
    nullif(btrim(coalesce(r ->> 'sheet', '')), '')         as sheet,
    nullif(r ->> 'sort', '')::int                          as sort_order
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as r
  where btrim(coalesce(r ->> 'item', '')) <> ''
    and upper(btrim(r ->> 'item')) <> 'TOTAL';

  -- 0088: an upload with no quantities is a LIST/PRICE setup, not a count.
  select exists (select 1 from _food_rows where qty is not null) into v_has_counts;

  -- 2. Resolve each row to a master by exact (case-insensitive) name.
  --    The catalog holds duplicates (e.g. "Cucumber, Hot House" twice), so the
  --    pick must be deterministic: prefer a row that actually has a base_unit,
  --    then lowest id. NOTE array_agg, not max() — PostgreSQL has no max(uuid)
  --    before 18 and this cluster is 17.6 (that bug is what 0057 fixed).
  create temp table _food_resolved on commit drop as
  select f.*,
         (select (array_agg(m.id order by (not m.is_active), (m.base_unit is null), m.id))[1]
            from public.master_items m
           where lower(m.name) = lower(f.item)) as master_item_id
    from _food_rows f;

  -- 3. Reactivate, then create only what is genuinely absent.
  --    IMPORTANT: all three of Little Luck's "new" items (Garlic Powder,
  --    Heavy Cream 40%, Whole Milk) already existed as INACTIVE masters.
  --    Blindly inserting would have duplicated the catalog -- the same
  --    duplicate-master problem 0047's merge tool exists to clean up -- and
  --    collided with master_items_organization_id_name_category_key. So:
  --    resolve to the existing row (step 2 now accepts inactive) and switch
  --    it back on, because the venue demonstrably stocks it.
  if p_commit then
    update public.master_items m
       set is_active = true
      from _food_resolved f
     where m.id = f.master_item_id
       and m.is_active = false;

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
         order by lower(f.item)
        on conflict (organization_id, name, category) do update
           set is_active = true
        returning id, name
      )
      update _food_resolved f
         set master_item_id = ins.id
        from ins
       where lower(f.item) = lower(ins.name);
      get diagnostics v_created = row_count;
    end if;
  end if;

  select coalesce(jsonb_agg(distinct f.item), '[]'::jsonb) into v_unmatched
    from _food_resolved f where f.master_item_id is null;

  select coalesce(sum(f.qty * f.price), 0) into v_total_value
    from _food_resolved f where f.qty is not null and f.price is not null;

  -- 4. Commit: one food audit + its entries + venue costs + the food list.
  -- 0088: only a sheet that actually carries quantities becomes a count. A
  -- priced-but-uncounted sheet (Little Luck's "FOOD INVENTORY - Priced",
  -- 153 prices / 0 quantities) still saves the item list and prices below,
  -- but no longer leaves behind an empty food audit with zero entries.
  if p_commit and v_has_counts then
    insert into public.kount_audits
      (venue_id, venue_name, status, count_phase, audit_kind, join_code,
       started_by_email, started_by_name, started_at, count1_closed_at, completed_at, notes)
    values
      (p_venue_id, v_venue_name, 'submitted', 'final', 'food',
       'FOOD-' || to_char(p_counted_at, 'MMDD-HH24MI'),
       v_email, coalesce(v_name, v_email), p_counted_at, p_counted_at, p_counted_at,
       'Imported from food inventory workbook by ' || v_email)
    returning id into v_audit_id;

    -- Entries: only rows that were actually counted. The sheet's own unit and
    -- pack size ride along, so a case count stays a case count.
    insert into public.kount_entries
      (audit_id, item_name, master_item_id, category, qty, zone, method,
       counted_by_email, counted_by_name, is_recount, count_unit, units_per_case,
       client_entry_id, timestamp)
    -- method 'manual': kount_entries_method_check allows only
    -- barcode|photo|manual|guided|quick|recount. 'manual' is also honest --
    -- the counter did count by hand onto a sheet. Deliberately NOT widening
    -- that CHECK, because it is shared with the beverage path; provenance is
    -- already carried by audit_kind='food', the FOOD- join code and the
    -- audit's notes.
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
    -- Costs. is_manual = false ON PURPOSE: the uploaded price is a SEED, so
    -- kount_refresh_venue_invoice_costs overwrites it once real itemised
    -- invoices arrive — which is the "enter cost once, then auto-pull from
    -- invoices" behaviour that was asked for.
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

    -- The venue's food list + how it counts each item (kount_carried_items is
    -- global and cannot hold this).
    insert into public.kount_venue_food_items
      (venue_id, master_item_id, count_unit, units_per_case, sheet_category, sort_order, updated_at)
    select distinct on (f.master_item_id)
           p_venue_id, f.master_item_id, f.count_unit, f.units_per_case, f.sheet, f.sort_order, now()
      from _food_resolved f
     where f.master_item_id is not null
     order by f.master_item_id, f.rn
    on conflict (venue_id, master_item_id) do update
       set count_unit     = excluded.count_unit,
           units_per_case = coalesce(excluded.units_per_case, kount_venue_food_items.units_per_case),
           sheet_category = excluded.sheet_category,
           sort_order     = excluded.sort_order,
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
CREATE OR REPLACE FUNCTION public.kount_is_corporate()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
           select 1 from public.app_users u
            where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
              and u.is_active = true
              and u.role = any (array['corporate','admin']))
      or exists (
           select 1 from public.organization_users ou
             join public.kount_role_map m on m.keva_role = ou.role
            where ou.user_id = auth.uid()
              and ou.is_active is true
              and m.global_corporate
              and split_part(lower(coalesce(auth.jwt() ->> 'email', '')), '@', 2)
                  in (select d.domain from public.kount_keva_email_domains d));
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_add_tracking(p jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_order uuid := nullif(p->>'order_id', '')::uuid;
  v_note  text := coalesce(nullif(p->>'note', ''), 'Tracking from email');
  v_n     integer := 0;
  v_all   text;
  r       jsonb;
begin
  if public.kount_is_corporate() is not true and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  if v_order is null or not exists (select 1 from public.kount_ot_orders o where o.id = v_order and o.archived_at is null) then
    raise exception 'kount_ot_add_tracking: order not found';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p->'numbers', '[]'::jsonb)) loop
    continue when nullif(btrim(r->>'number'), '') is null;
    insert into public.kount_ot_tracking (order_id, tracking_number, carrier, source, message_id, conversation_id, note)
    values (v_order, upper(btrim(r->>'number')), nullif(r->>'carrier', ''), coalesce(nullif(p->>'source', ''), 'email'),
            nullif(p->>'message_id', ''), nullif(p->>'conversation_id', ''), v_note)
    on conflict (order_id, tracking_number) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  -- a tracking number means it shipped: every line not shipped yet moves to SHIPPED (forward only)
  if coalesce((p->>'ship_lines')::boolean, true) then
    update public.kount_ot_lines l set status = 'SHIPPED', status_source = 'document', status_note = v_note
     where l.order_id = v_order and l.status in ('REQUESTED', 'ORDERED', 'QUOTED', 'INVOICED', 'PAID');
  end if;
  select string_agg(t.tracking_number, ', ' order by t.created_at) into v_all from public.kount_ot_tracking t where t.order_id = v_order;
  update public.kount_ot_lines l set tracking_number = left(v_all, 300)
   where l.order_id = v_order and l.tracking_number is null and l.status <> 'CANCELLED';
  if nullif(p->>'inbox_id', '') is not null then
    update public.kount_ot_inbox set state = 'applied', order_id = v_order,
           decision = coalesce(nullif(p->>'decision', ''), decision),
           decided_by = coalesce(auth.jwt() ->> 'email', 'morning mail pull')
     where id = (p->>'inbox_id')::uuid;
  end if;
  return v_n;
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_apply_document(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_order uuid;
  v_note  text := nullif(p->>'note', '');
  v_items jsonb := '{}'::jsonb;
  v_id    uuid;
  v_sort  integer;
  r       jsonb;
begin
  -- the service role is the morning mail pull (it bypasses RLS)
  if public.kount_is_corporate() is not true and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  if nullif(p->'document'->>'id', '') is null then
    raise exception 'kount_ot_apply_document: document.id is required';
  end if;
  if exists (select 1 from public.kount_ot_documents d where d.id = (p->'document'->>'id')::uuid) then
    raise exception 'This document was already saved' using errcode = '23505';
  end if;

  -- 1. the order: an existing one (filling only what it lacks) or a new one
  if nullif(p->>'order_id', '') is not null then
    v_order := (p->>'order_id')::uuid;
    if not exists (select 1 from public.kount_ot_orders o where o.id = v_order) then
      raise exception 'kount_ot_apply_document: order not found';
    end if;
    if p->'order_patch' is not null then
      -- an order that now spans venues: its own lines keep the venue they were for
      if nullif(p->'order_patch'->>'venue_id', '') is not null then
        update public.kount_ot_lines l set venue_id = o.venue_id
          from public.kount_ot_orders o
         where o.id = v_order and l.order_id = v_order and l.venue_id is null and o.venue_id is not null
           and o.venue_id is distinct from p->'order_patch'->>'venue_id';
      end if;
      update public.kount_ot_orders o set
        order_number = coalesce(o.order_number, nullif(p->'order_patch'->>'order_number', '')),
        expected_on  = coalesce(nullif(p->'order_patch'->>'expected_on', '')::date, o.expected_on),
        venue_id     = coalesce(nullif(p->'order_patch'->>'venue_id', ''), o.venue_id)
      where o.id = v_order;
    end if;
  else
    insert into public.kount_ot_orders (vendor_name, order_number, venue_id, deliver_to, ordered_on, expected_on)
    values (p->'new_order'->>'vendor_name', nullif(p->'new_order'->>'order_number', ''), nullif(p->'new_order'->>'venue_id', ''),
            coalesce(nullif(p->'new_order'->>'deliver_to', ''), 'warehouse'),
            nullif(p->'new_order'->>'ordered_on', '')::date, nullif(p->'new_order'->>'expected_on', '')::date)
    returning id into v_order;
  end if;

  -- 2. catalog items asked for; an active item with the same name + SKU is reused
  for r in select * from jsonb_array_elements(coalesce(p->'new_items', '[]'::jsonb)) loop
    v_id := null;
    select i.id into v_id from public.kount_ot_items i
     where i.is_active and lower(btrim(i.name)) = lower(btrim(r->>'name'))
       and coalesce(lower(btrim(i.sku)), '') = coalesce(lower(btrim(nullif(r->>'sku', ''))), '')
     limit 1;
    if v_id is null then
      insert into public.kount_ot_items (name, sku, vendor_name, unit, pack_size)
      values (btrim(r->>'name'), nullif(btrim(r->>'sku'), ''), nullif(r->>'vendor_name', ''),
              coalesce(nullif(r->>'unit', ''), 'case'), nullif(r->>'pack_size', '')::numeric)
      returning id into v_id;
    end if;
    v_items := v_items || jsonb_build_object(r->>'key', v_id);
  end loop;

  -- 3. existing lines: only the keys present in each update change
  for r in select * from jsonb_array_elements(coalesce(p->'updates', '[]'::jsonb)) loop
    update public.kount_ot_lines l set
      status          = case when r ? 'status' then r->>'status' else l.status end,
      status_source   = case when r ? 'status' then 'document' else l.status_source end,
      status_note     = case when r ? 'status' then v_note else l.status_note end,
      unit_price      = case when r ? 'unit_price' then (r->>'unit_price')::numeric else l.unit_price end,
      quote_number    = case when r ? 'quote_number' then r->>'quote_number' else l.quote_number end,
      invoice_number  = case when r ? 'invoice_number' then r->>'invoice_number' else l.invoice_number end,
      invoice_date    = case when r ? 'invoice_date' then (r->>'invoice_date')::date else l.invoice_date end,
      tracking_number = case when r ? 'tracking_number' then r->>'tracking_number' else l.tracking_number end,
      expected_on     = case when r ? 'expected_on' then (r->>'expected_on')::date else l.expected_on end,
      item_id         = case when r ? 'item_id' then (r->>'item_id')::uuid
                             when r ? 'item_key' then (v_items->>(r->>'item_key'))::uuid else l.item_id end
    where l.id = (r->>'id')::uuid and l.order_id = v_order;
    if not found then
      raise exception 'kount_ot_apply_document: line % is not on this order', r->>'id';
    end if;
  end loop;

  -- 4. new lines, after the order's existing ones
  select coalesce(max(l.sort) + 1, 0) into v_sort from public.kount_ot_lines l where l.order_id = v_order;
  insert into public.kount_ot_lines (order_id, item_id, description, sku, qty, unit, unit_price, status, status_source, status_note,
                                     quote_number, invoice_number, invoice_date, tracking_number, expected_on, sort, venue_id)
  select v_order,
         coalesce(nullif(o.x->>'item_id', '')::uuid, (v_items->>(o.x->>'item_key'))::uuid),
         o.x->>'description', nullif(o.x->>'sku', ''), (o.x->>'qty')::numeric, nullif(o.x->>'unit', ''), nullif(o.x->>'unit_price', '')::numeric,
         o.x->>'status', 'document', v_note,
         nullif(o.x->>'quote_number', ''), nullif(o.x->>'invoice_number', ''), nullif(o.x->>'invoice_date', '')::date,
         nullif(o.x->>'tracking_number', ''), nullif(o.x->>'expected_on', '')::date,
         v_sort + (o.n::integer - 1), nullif(o.x->>'venue_id', '')
  from jsonb_array_elements(coalesce(p->'new_lines', '[]'::jsonb)) with ordinality as o(x, n);

  -- 5. the document row (its PDF is already in the bucket)
  insert into public.kount_ot_documents (id, order_id, kind, doc_number, doc_date, vendor_name, total, file_name, storage_path, parsed,
                                         source_message_id, source_conversation_id)
  values ((p->'document'->>'id')::uuid, v_order, p->'document'->>'kind', nullif(p->'document'->>'doc_number', ''),
          nullif(p->'document'->>'doc_date', '')::date, nullif(p->'document'->>'vendor_name', ''),
          nullif(p->'document'->>'total', '')::numeric, nullif(p->'document'->>'file_name', ''),
          nullif(p->'document'->>'storage_path', ''), p->'document'->'parsed',
          nullif(p->'document'->>'source_message_id', ''), nullif(p->'document'->>'source_conversation_id', ''));

  -- 6. a document from the morning mail pull: its inbox row is done, in the same transaction
  if nullif(p->>'inbox_id', '') is not null then
    update public.kount_ot_inbox set state = 'applied', order_id = v_order,
           decision = coalesce(nullif(p->>'decision', ''), decision),
           decided_by = coalesce(auth.jwt() ->> 'email', 'morning mail pull')
     where id = (p->>'inbox_id')::uuid and state <> 'applied';
    if not found then
      raise exception 'This document was already saved' using errcode = '23505';
    end if;
  end if;
  return v_order;
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_mail_disconnect()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  delete from vault.secrets where id = (select token_secret_id from public.kount_ot_mail_account where id = 1);
  update public.kount_ot_mail_account set token_secret_id = null, mailbox = null, connected_by = null, connected_at = null,
    device_code = null, device_code_expires_at = null, updated_at = now()
  where id = 1;
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_mail_set_auto_create(p_on boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  update public.kount_ot_mail_account set auto_create = coalesce(p_on, true), updated_at = now() where id = 1;
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_mail_set_doc_kinds(p_kinds text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text[];
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct k order by k), '{}') into v
    from unnest(coalesce(p_kinds, '{}')) k where k in ('quote', 'confirmation', 'invoice', 'shipping');
  if cardinality(v) = 0 then raise exception 'Pick at least one document type'; end if;
  update public.kount_ot_mail_account set doc_kinds = v, updated_at = now() where id = 1;
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_mail_set_domains(p_domains text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v text[];
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct d order by d), '{}') into v
    from (select lower(btrim(regexp_replace(x, '^.*@', ''))) as d from unnest(coalesce(p_domains, '{}')) x) t
   where d ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' and d not in ('hwoodgroup.com');
  update public.kount_ot_mail_account set vendor_domains = v,
    suggested_domains = suggested_domains - v,
    updated_at = now() where id = 1;
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_mail_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  return (select jsonb_build_object(
      'mailbox', a.mailbox, 'connected', a.token_secret_id is not null, 'connected_by', a.connected_by, 'connected_at', a.connected_at,
      'signing_in', a.device_code is not null and a.device_code_expires_at > now(),
      'vendor_domains', to_jsonb(a.vendor_domains), 'doc_kinds', to_jsonb(a.doc_kinds), 'auto_create', a.auto_create, 'suggested_domains', a.suggested_domains,
      'fetched_through', a.fetched_through,
      'running', a.running_since is not null and a.running_since > now() - interval '10 minutes',
      'last_run', a.last_run)
    from public.kount_ot_mail_account a where a.id = 1);
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_ot_r365_ap(p_numbers text[], p_since date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v    jsonb;
  v_ap uuid[];
begin
  if public.kount_is_corporate() is not true and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  -- the Accounts Payable accounts as a list FIRST: as a sub-select the planner scans all 2.2M rows (8 s timeout);
  -- as an array it uses the (gl_account_id, posting_date) index
  select array_agg(g.id) into v_ap from public.gl_accounts g where g.name ilike 'accounts payable%';
  with ap as (
    -- every R365 AP invoice and AP payment has exactly one row on an Accounts Payable account
    select e.r365_transaction_id, e.transaction_type as type, e.transaction_number as number, e.posting_date, e.venue_id,
           e.transaction_name, e.debit, e.credit
    from public.ledger_journal_entries e
    where e.gl_account_id = any(v_ap)
      and e.posting_date >= p_since
      and e.transaction_type in ('AP Invoice', 'AP Payment')
  ),
  ours as (
    -- "AP Invoice - <vendor> - <number>": the vendors of the asked invoices. R365 also posts an invoice as
    -- "INV-2026-857309 Delilah LA" (split per venue), "INV-2026-291876/2", "INV-2026-688306-D" — the
    -- INV-yyyy-nnnnnn token is what matches
    select distinct substr(a.transaction_name, 14, length(a.transaction_name) - 16 - length(a.number)) as vendor
    from ap a
    where a.type = 'AP Invoice' and upper(substring(a.number from '(?i)INV-[0-9]{4}-[0-9]{5,7}')) = any(p_numbers)
      and right(a.transaction_name, length(a.number) + 3) = ' - ' || a.number
  ),
  tx as (
    select a.type, a.number, min(a.posting_date)::text as date, min(a.venue_id::text) as venue, o.vendor,
           round(sum(case when a.type = 'AP Invoice' then a.credit - a.debit else a.debit - a.credit end), 2) as amount
    from ap a
    join ours o on left(a.transaction_name, length(a.type) + 6 + length(o.vendor)) = a.type || ' - ' || o.vendor || ' - '
    group by a.r365_transaction_id, a.type, a.number, o.vendor
  )
  select coalesce(jsonb_agg(to_jsonb(tx)), '[]'::jsonb) into v from tx;
  return v;
end
$function$;
CREATE OR REPLACE FUNCTION public.kount_refresh_bev_vendor_class()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;
CREATE OR REPLACE FUNCTION public.kount_reopen_audit(p_audit_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a          public.kount_audits;
  v_active   text;
  v_recounts integer;
  v_reports  integer;
  v_entries  integer;
begin
  if not public.kount_is_corporate() then
    raise exception 'Only corporate or admin users can reopen a submitted audit.'
      using errcode = '42501';
  end if;

  select * into a from public.kount_audits where id = p_audit_id for update;
  if not found then
    raise exception 'Audit % not found.', p_audit_id using errcode = 'P0002';
  end if;
  if a.status <> 'submitted' then
    raise exception '% is %, only a submitted audit can be reopened.', a.join_code, a.status
      using errcode = '22023';
  end if;

  select string_agg(b.join_code, ', ') into v_active
    from public.kount_audits b
   where b.venue_id = a.venue_id and b.status = 'active' and b.id <> a.id;
  if v_active is not null then
    raise exception '% already has an active audit (%). Close or cancel it before reopening %.',
      a.venue_name, v_active, a.join_code using errcode = '22023';
  end if;

  select count(*) into v_recounts from public.kount_recounts where audit_id = a.id;
  if v_recounts > 0 then
    raise exception '% has % recount row(s); reopening to Count 1 would orphan them. Reopen it by hand.',
      a.join_code, v_recounts using errcode = '22023';
  end if;

  delete from public.kount_avt_rows
   where report_id in (select id from public.kount_avt_reports
                        where audit_id = a.id and source = 'computed');
  delete from public.kount_avt_reports where audit_id = a.id and source = 'computed';
  get diagnostics v_reports = row_count;

  update public.kount_audits
     set status = 'active', count_phase = 'count1',
         count1_closed_at = null, count2_closed_at = null, completed_at = null
   where id = a.id;

  select count(*) into v_entries from public.kount_entries where audit_id = a.id;

  return jsonb_build_object('ok', true, 'audit_id', a.id, 'join_code', a.join_code,
    'venue_name', a.venue_name, 'entries', v_entries, 'reports_removed', v_reports);
end;
$function$;
CREATE OR REPLACE FUNCTION public.kount_role_for_venue(p_venue_id text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with cand(role) as (
    -- (a) legacy app_users
    select case
             when u.role in ('corporate','admin') then 'corporate'
             when p_venue_id = any (coalesce(u.venue_ids, '{}')) then
               case u.role when 'manager' then 'manager'
                           when 'counter' then 'counter'
                           when 'venue_manager' then 'viewer' end
           end
      from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
    union all
    -- (b) time-boxed grant
    select g.role
      from public.kount_access_grants g
     where g.user_id = auth.uid()
       and g.venue_id = p_venue_id
       and g.revoked_at is null
       and now() >= g.starts_at
       and now() <  coalesce(g.ends_at, 'infinity'::timestamptz)
    union all
    -- (c) Keva membership of the venue's organization
    select m.kount_role
      from public.kount_venues kv
      join public.venues v              on v.id = kv.ops_venue_id
      join public.organization_users ou on ou.organization_id = v.organization_id
      join public.kount_role_map m      on m.keva_role = ou.role
     where kv.id = p_venue_id
       and ou.user_id = auth.uid()
       and ou.is_active is true
       and (ou.venue_ids is null or kv.ops_venue_id = any (ou.venue_ids))
       and split_part(lower(coalesce(auth.jwt() ->> 'email', '')), '@', 2)
           in (select d.domain from public.kount_keva_email_domains d)
  )
  select role from cand
   where role in ('corporate','manager','counter','viewer')
   order by array_position(array['corporate','manager','counter','viewer'], role)
   limit 1;
$function$;
CREATE OR REPLACE FUNCTION public.merge_master_items(p_winner uuid, p_losers uuid[], p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_losers          uuid[];
  v_winner_active   boolean;
  v_entries         integer := 0;
  v_recounts        integer := 0;
  v_carried_move    integer := 0;
  v_carried_deldup  integer := 0;
  v_pending         integer := 0;
  v_upcs_move       integer := 0;
  v_upcs_deldup     integer := 0;
  v_mappings        integer := 0;
  v_affected_audits uuid[];
begin
  -- Auth: corporate only. Merging mutates the global catalog + historical counts.
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and u.role = any (array['corporate','admin'])
  ) then
    raise exception 'not authorized: merge_master_items is corporate-only'
      using errcode = '42501';
  end if;

  -- Normalize losers: distinct, non-null, and never the winner itself.
  select array_agg(distinct l) into v_losers
    from unnest(coalesce(p_losers, '{}'::uuid[])) l
   where l is not null and l <> p_winner;

  if p_winner is null then
    raise exception 'merge_master_items: winner is required' using errcode = '22023';
  end if;
  if v_losers is null or array_length(v_losers, 1) is null then
    raise exception 'merge_master_items: at least one loser (distinct from winner) is required'
      using errcode = '22023';
  end if;

  select is_active into v_winner_active from public.master_items where id = p_winner;
  if v_winner_active is null then
    raise exception 'merge_master_items: winner % not found', p_winner using errcode = 'P0002';
  end if;
  if v_winner_active is not true then
    raise exception 'merge_master_items: winner % is archived; pick an ACTIVE canonical', p_winner
      using errcode = '22023';
  end if;
  if not (select bool_and(exists (select 1 from public.master_items mi where mi.id = l))
            from unnest(v_losers) l) then
    raise exception 'merge_master_items: one or more losers do not exist' using errcode = 'P0002';
  end if;

  -- Audits touched by the losers' counts/recounts â€” returned so the caller can
  -- recompute their AVT afterward. Computed in both modes (read-only).
  select array_agg(distinct aid) into v_affected_audits
    from (
      select audit_id aid from public.kount_entries  where master_item_id = any(v_losers)
      union
      select audit_id aid from public.kount_recounts where master_item_id = any(v_losers)
    ) x;

  if p_dry_run then
    -- Impact counts only; NO mutation.
    select count(*) into v_entries  from public.kount_entries  where master_item_id = any(v_losers);
    select count(*) into v_recounts from public.kount_recounts where master_item_id = any(v_losers);
    select count(*) into v_pending  from public.kount_pending_items where master_item_id = any(v_losers);
    select count(*) into v_mappings from public.upc_mappings   where master_item_id = any(v_losers);
    -- carried: rows that would collide with an already-carried winner (deleted) vs moved
    select count(*) filter (where w.master_item_id is not null),
           count(*) filter (where w.master_item_id is null)
      into v_carried_deldup, v_carried_move
      from public.kount_carried_items c
      left join public.kount_carried_items w on w.master_item_id = p_winner
     where c.master_item_id = any(v_losers);
    -- upcs: rows whose normalized upc the winner already owns (deleted) vs moved
    select count(*) filter (where exists (
             select 1 from public.master_item_upcs w
              where w.master_item_id = p_winner and w.upc_normalized = u.upc_normalized)),
           count(*) filter (where not exists (
             select 1 from public.master_item_upcs w
              where w.master_item_id = p_winner and w.upc_normalized = u.upc_normalized))
      into v_upcs_deldup, v_upcs_move
      from public.master_item_upcs u
     where u.master_item_id = any(v_losers);

    return jsonb_build_object(
      'dry_run', true, 'winner', p_winner, 'losers', to_jsonb(v_losers),
      'entries_repointed', v_entries, 'recounts_repointed', v_recounts,
      'carried_repointed', v_carried_move, 'carried_deleted_dup', v_carried_deldup,
      'pending_repointed', v_pending, 'upcs_moved', v_upcs_move,
      'upcs_deleted_dup', v_upcs_deldup, 'mappings_repointed', v_mappings,
      'affected_audits', to_jsonb(coalesce(v_affected_audits, '{}'::uuid[]))
    );
  end if;

  -- ---- REAL RUN (atomic) --------------------------------------------------
  -- 1. kount_entries: unique key is on item_id/name, not master â†’ safe repoint.
  update public.kount_entries set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_entries = row_count;

  -- 2. kount_recounts: same (unique on item_id/name + zone) â†’ safe repoint.
  update public.kount_recounts set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_recounts = row_count;

  -- 3. kount_carried_items: UNIQUE(master_item_id). Delete loser rows that would
  --    collide with an already-carried winner; repoint the rest.
  delete from public.kount_carried_items c
   where c.master_item_id = any(v_losers)
     and exists (select 1 from public.kount_carried_items w where w.master_item_id = p_winner);
  get diagnostics v_carried_deldup = row_count;
  update public.kount_carried_items set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_carried_move = row_count;

  -- 4. kount_pending_items: partial (non-unique) index â†’ free repoint.
  update public.kount_pending_items set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_pending = row_count;

  -- 5. master_item_upcs: UNIQUE(upc_normalized). Delete loser UPCs the winner
  --    already owns; move the rest so future scans resolve to the winner.
  delete from public.master_item_upcs u
   where u.master_item_id = any(v_losers)
     and exists (select 1 from public.master_item_upcs w
                  where w.master_item_id = p_winner and w.upc_normalized = u.upc_normalized);
  get diagnostics v_upcs_deldup = row_count;
  update public.master_item_upcs set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_upcs_move = row_count;

  -- 6. upc_mappings (pending/approved queue): partial index â†’ free repoint.
  update public.upc_mappings set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_mappings = row_count;

  -- 7. Collapse any redirect chains that pointed at a loser, then fold the
  --    losers: tombstone â†’ winner, archived. (winner itself never a loser.)
  update public.master_items set merged_into_id = p_winner
   where merged_into_id = any(v_losers);
  update public.master_items
     set merged_into_id = p_winner, is_active = false
   where id = any(v_losers);

  return jsonb_build_object(
    'dry_run', false, 'winner', p_winner, 'losers', to_jsonb(v_losers),
    'entries_repointed', v_entries, 'recounts_repointed', v_recounts,
    'carried_repointed', v_carried_move, 'carried_deleted_dup', v_carried_deldup,
    'pending_repointed', v_pending, 'upcs_moved', v_upcs_move,
    'upcs_deleted_dup', v_upcs_deldup, 'mappings_repointed', v_mappings,
    'affected_audits', to_jsonb(coalesce(v_affected_audits, '{}'::uuid[]))
  );
end
$function$;
CREATE OR REPLACE FUNCTION public.reject_pending_item(p_pending_id uuid, p_admin_email text, p_admin_name text DEFAULT NULL::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec public.kount_pending_items;
begin
  -- Authorization (added 2026-09-08). This function is SECURITY DEFINER and
  -- previously had NO internal check: it trusted p_admin_email, a value the
  -- caller supplies, and wrote it straight into reviewed_by_email. It was
  -- reachable only because Supabase's default PUBLIC EXECUTE grant was in
  -- place; once that was correctly revoked, granting EXECUTE back to
  -- authenticated without this gate would let any signed-in user approve
  -- catalog and barcode changes with owner privileges.
  -- corporate|manager mirrors both existing callers: the phone's
  -- approveUPCPending role check and the admin's /approvals route gate.
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and u.role in ('corporate', 'admin', 'manager', 'venue_manager')
  ) then
    raise exception 'not authorized: reject_pending_item is corporate/manager only'
      using errcode = '42501';
  end if;
  update public.kount_pending_items
     set status            = 'rejected',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now(),
         reject_reason     = p_reason
   where id     = p_pending_id
     and status = 'pending'
  returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Pending item not found or already finalized');
  end if;

  return jsonb_build_object('ok', true, 'pending_id', rec.id);
end;
$function$;
CREATE OR REPLACE FUNCTION public.reject_upc_mapping(p_mapping_id uuid, p_admin_email text, p_admin_name text DEFAULT NULL::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rec public.upc_mappings;
begin
  -- Authorization (added 2026-09-08). This function is SECURITY DEFINER and
  -- previously had NO internal check: it trusted p_admin_email, a value the
  -- caller supplies, and wrote it straight into reviewed_by_email. It was
  -- reachable only because Supabase's default PUBLIC EXECUTE grant was in
  -- place; once that was correctly revoked, granting EXECUTE back to
  -- authenticated without this gate would let any signed-in user approve
  -- catalog and barcode changes with owner privileges.
  -- corporate|manager mirrors both existing callers: the phone's
  -- approveUPCPending role check and the admin's /approvals route gate.
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and u.role in ('corporate', 'admin', 'manager', 'venue_manager')
  ) then
    raise exception 'not authorized: reject_upc_mapping is corporate/manager only'
      using errcode = '42501';
  end if;
  update public.upc_mappings
     set status = 'rejected',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now()
   where id = p_mapping_id
     and status = 'pending'
  returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Mapping not found or already finalized');
  end if;

  return jsonb_build_object('ok', true, 'id', rec.id, 'reason', p_reason);
end;
$function$;
CREATE OR REPLACE FUNCTION public.rename_venue_zone(p_venue_id text, p_old_zone_name text, p_new_zone_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_old              text := trim(coalesce(p_old_zone_name, ''));
  v_new              text := trim(coalesce(p_new_zone_name, ''));
  v_default_zones    text[];
  v_old_idx          int;
  v_old_in_custom    boolean;
  v_target_exists    boolean;
  v_both_audits      int;
  v_entries_updated  int;
  v_recounts_updated int;
  v_members_updated  int;
begin
  if not public.kount_is_corporate() then
    raise exception 'not authorized: rename_venue_zone is corporate/admin only'
      using errcode = '42501';
  end if;

  if v_old = '' or v_new = '' then
    return jsonb_build_object('ok', false, 'error', 'Old and new zone names are required');
  end if;
  if lower(v_old) = lower(v_new) then
    return jsonb_build_object('ok', false, 'error', 'New zone name must be different from the old one');
  end if;

  select coalesce(default_zones, '{}') into v_default_zones
    from public.kount_venues
   where id = p_venue_id
     for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Venue not found');
  end if;

  if exists (select 1 from public.kount_audits
              where venue_id = p_venue_id and status = 'active') then
    return jsonb_build_object('ok', false, 'error',
      'This venue has an audit in progress. Rename zones after it is submitted or cancelled.');
  end if;

  select min(o) into v_old_idx
    from unnest(v_default_zones) with ordinality u(z, o)
   where lower(z) = lower(v_old);
  v_old_in_custom := exists (
    select 1 from public.kount_venue_zones
     where venue_id = p_venue_id and lower(zone_name) = lower(v_old));

  -- A zone that was removed from the lists but still labels past counts is
  -- the main thing this exists to fix, so history alone is enough.
  if v_old_idx is null and not v_old_in_custom
     and not exists (select 1 from public.kount_entries e
                       join public.kount_audits a on a.id = e.audit_id
                      where a.venue_id = p_venue_id and lower(e.zone) = lower(v_old))
     and not exists (select 1 from public.kount_recounts r
                       join public.kount_audits a on a.id = r.audit_id
                      where a.venue_id = p_venue_id and lower(r.zone) = lower(v_old)) then
    return jsonb_build_object('ok', false, 'error', 'Zone "' || v_old || '" not found for this venue');
  end if;

  v_target_exists :=
       exists (select 1 from unnest(v_default_zones) z where lower(z) = lower(v_new))
    or exists (select 1 from public.kount_venue_zones
                where venue_id = p_venue_id and lower(zone_name) = lower(v_new));

  -- Any audit that already holds more than one distinct label among
  -- {old, new} (case variants included) would have to COMBINE counts.
  select count(*) into v_both_audits
    from (
      select x.audit_id
        from (
          select e.audit_id, e.zone
            from public.kount_entries e
            join public.kount_audits a on a.id = e.audit_id
           where a.venue_id = p_venue_id
             and lower(e.zone) in (lower(v_old), lower(v_new))
          union
          select r.audit_id, r.zone
            from public.kount_recounts r
            join public.kount_audits a on a.id = r.audit_id
           where a.venue_id = p_venue_id
             and lower(r.zone) in (lower(v_old), lower(v_new))
        ) x
       group by x.audit_id
      having count(distinct x.zone) > 1
    ) both_zones;

  if v_both_audits > 0 then
    return jsonb_build_object('ok', false, 'error',
      v_both_audits || ' past audit(s) counted both "' || v_old || '" and "' || v_new ||
      '" separately, so merging would combine their counts. Nothing was changed.',
      'conflicting_audits', v_both_audits);
  end if;

  -- 1. History. Safe by the check above: no audit holds both labels, so no
  --    unique key can collide and no recount can land on a different sum.
  update public.kount_entries e
     set zone = v_new
    from public.kount_audits a
   where e.audit_id = a.id
     and a.venue_id = p_venue_id
     and lower(e.zone) = lower(v_old);
  get diagnostics v_entries_updated = row_count;

  update public.kount_recounts r
     set zone = v_new
    from public.kount_audits a
   where r.audit_id = a.id
     and a.venue_id = p_venue_id
     and lower(r.zone) = lower(v_old);
  get diagnostics v_recounts_updated = row_count;

  update public.kount_members m
     set assigned_zones = (
           select array_agg(z order by first_o)
             from (select case when lower(u.z) = lower(v_old) then v_new else u.z end as z,
                          min(u.o) as first_o
                     from unnest(m.assigned_zones) with ordinality u(z, o)
                    group by 1) d)
    from public.kount_audits a
   where m.audit_id = a.id
     and a.venue_id = p_venue_id
     and exists (select 1 from unnest(m.assigned_zones) z where lower(z) = lower(v_old));
  get diagnostics v_members_updated = row_count;

  -- 2. Zone lists. Rename relabels in place (keeps its default/custom status
  --    and position); merge just drops the old entry.
  if v_old_idx is not null then
    if v_target_exists then
      v_default_zones := v_default_zones[1 : v_old_idx - 1]
                      || v_default_zones[v_old_idx + 1 : array_length(v_default_zones, 1)];
    else
      v_default_zones[v_old_idx] := v_new;
    end if;
    update public.kount_venues set default_zones = v_default_zones where id = p_venue_id;
  end if;

  if v_old_in_custom then
    if v_target_exists or v_old_idx is not null then
      -- target already listed, or the default list now carries the new name
      delete from public.kount_venue_zones
       where venue_id = p_venue_id and lower(zone_name) = lower(v_old);
    else
      update public.kount_venue_zones
         set zone_name = v_new
       where venue_id = p_venue_id and lower(zone_name) = lower(v_old);
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'merged', v_target_exists,
    'old_zone', v_old,
    'new_zone', v_new,
    'entries_updated', v_entries_updated,
    'recounts_updated', v_recounts_updated,
    'members_updated', v_members_updated
  );
end;
$function$;

drop policy if exists "kount_ot_orders_corporate" on public.kount_ot_orders;
create policy "kount_ot_orders_corporate" on public.kount_ot_orders for all to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_orders_read" on public.kount_ot_orders;

drop policy if exists "kount_ot_orders_write" on public.kount_ot_orders;

drop policy if exists "kount_ot_lines_corporate" on public.kount_ot_lines;
create policy "kount_ot_lines_corporate" on public.kount_ot_lines for all to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_lines_read" on public.kount_ot_lines;

drop policy if exists "kount_ot_lines_write" on public.kount_ot_lines;

drop policy if exists "kount_ot_items_corporate" on public.kount_ot_items;
create policy "kount_ot_items_corporate" on public.kount_ot_items for all to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_items_read" on public.kount_ot_items;

drop policy if exists "kount_ot_items_write" on public.kount_ot_items;

drop policy if exists "kount_ot_stock_moves_corporate" on public.kount_ot_stock_moves;
create policy "kount_ot_stock_moves_corporate" on public.kount_ot_stock_moves for all to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_stock_moves_read" on public.kount_ot_stock_moves;

drop policy if exists "kount_ot_stock_moves_write" on public.kount_ot_stock_moves;

drop policy if exists "kount_ot_tracking_corporate" on public.kount_ot_tracking;
create policy "kount_ot_tracking_corporate" on public.kount_ot_tracking for all to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_tracking_read" on public.kount_ot_tracking;

drop policy if exists "kount_ot_tracking_write" on public.kount_ot_tracking;

drop policy if exists "kount_ot_documents_corporate" on public.kount_ot_documents;
create policy "kount_ot_documents_corporate" on public.kount_ot_documents for all to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_documents_read" on public.kount_ot_documents;

drop policy if exists "kount_ot_documents_write" on public.kount_ot_documents;

drop policy if exists "kount_ot_bibles_corporate" on public.kount_ot_bibles;
create policy "kount_ot_bibles_corporate" on public.kount_ot_bibles for all to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_bibles_read" on public.kount_ot_bibles;

drop policy if exists "kount_ot_bibles_write" on public.kount_ot_bibles;

drop policy if exists "kount_ot_events_corporate_read" on public.kount_ot_events;
create policy "kount_ot_events_corporate_read" on public.kount_ot_events for select to authenticated
  using ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_inbox_corporate_read" on public.kount_ot_inbox;
create policy "kount_ot_inbox_corporate_read" on public.kount_ot_inbox for select to authenticated
  using ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_ot_inbox_corporate_update" on public.kount_ot_inbox;
create policy "kount_ot_inbox_corporate_update" on public.kount_ot_inbox for update to authenticated
  using ((kount_is_corporate() IS TRUE))
  with check ((kount_is_corporate() IS TRUE));

drop policy if exists "kount_order_docs_read" on storage.objects;
create policy "kount_order_docs_read" on storage.objects for select to authenticated
  using (((bucket_id = 'kount-order-docs'::text) AND (kount_is_corporate() IS TRUE)));

drop policy if exists "kount_order_docs_write" on storage.objects;
create policy "kount_order_docs_write" on storage.objects for insert to authenticated
  with check (((bucket_id = 'kount-order-docs'::text) AND (kount_is_corporate() IS TRUE)));

drop policy if exists "kount_order_docs_update" on storage.objects;
create policy "kount_order_docs_update" on storage.objects for update to authenticated
  using (((bucket_id = 'kount-order-docs'::text) AND (kount_is_corporate() IS TRUE)))
  with check (((bucket_id = 'kount-order-docs'::text) AND (kount_is_corporate() IS TRUE)));

drop policy if exists "kount_order_docs_delete" on storage.objects;
create policy "kount_order_docs_delete" on storage.objects for delete to authenticated
  using (((bucket_id = 'kount-order-docs'::text) AND (kount_is_corporate() IS TRUE)));

drop policy if exists "kount_bev_vendor_class_read" on public.kount_bev_vendor_class;
create policy "kount_bev_vendor_class_read" on public.kount_bev_vendor_class for select to authenticated
  using ((kount_is_corporate() IS TRUE));

drop policy if exists "auth_dev_kount_audits_delete" on public.kount_audits;
create policy "auth_dev_kount_audits_delete" on public.kount_audits for delete to authenticated
  using (( SELECT kount_is_corporate() AS kount_is_corporate));

drop policy if exists "auth_dev_kount_venues_insert" on public.kount_venues;
create policy "auth_dev_kount_venues_insert" on public.kount_venues for insert to authenticated
  with check (( SELECT kount_is_corporate() AS kount_is_corporate));

drop policy if exists "auth_dev_kount_venues_update" on public.kount_venues;
create policy "auth_dev_kount_venues_update" on public.kount_venues for update to authenticated
  using (( SELECT kount_is_corporate() AS kount_is_corporate))
  with check (( SELECT kount_is_corporate() AS kount_is_corporate));

drop policy if exists "auth_dev_kount_venues_delete" on public.kount_venues;
create policy "auth_dev_kount_venues_delete" on public.kount_venues for delete to authenticated
  using (( SELECT kount_is_corporate() AS kount_is_corporate));

drop policy if exists "master_items_insert_corporate" on public.master_items;
create policy "master_items_insert_corporate" on public.master_items for insert to authenticated
  with check (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true))))));

drop policy if exists "master_items_update_corporate" on public.master_items;
create policy "master_items_update_corporate" on public.master_items for update to authenticated
  using (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true))))))
  with check (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true))))));

drop policy if exists "auth_master_item_upcs_update" on public.master_item_upcs;
create policy "auth_master_item_upcs_update" on public.master_item_upcs for update to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))))
  with check ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))));

drop policy if exists "auth_master_item_upcs_delete" on public.master_item_upcs;
create policy "auth_master_item_upcs_delete" on public.master_item_upcs for delete to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))));

drop policy if exists "auth_master_item_upcs_review_insert" on public.master_item_upcs_review;
create policy "auth_master_item_upcs_review_insert" on public.master_item_upcs_review for insert to authenticated
  with check (( SELECT kount_is_corporate() AS kount_is_corporate));

drop policy if exists "auth_master_item_upcs_review_update" on public.master_item_upcs_review;
create policy "auth_master_item_upcs_review_update" on public.master_item_upcs_review for update to authenticated
  using (( SELECT kount_is_corporate() AS kount_is_corporate))
  with check (( SELECT kount_is_corporate() AS kount_is_corporate));

drop policy if exists "auth_master_item_upcs_review_delete" on public.master_item_upcs_review;
create policy "auth_master_item_upcs_review_delete" on public.master_item_upcs_review for delete to authenticated
  using (( SELECT kount_is_corporate() AS kount_is_corporate));

drop policy if exists "new_recipe_pos_skus_insert_corporate" on public.new_recipe_pos_skus;
create policy "new_recipe_pos_skus_insert_corporate" on public.new_recipe_pos_skus for insert to authenticated
  with check ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

drop policy if exists "new_recipe_pos_skus_update_corporate" on public.new_recipe_pos_skus;
create policy "new_recipe_pos_skus_update_corporate" on public.new_recipe_pos_skus for update to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))))
  with check ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

drop policy if exists "new_recipe_pos_skus_delete_corporate" on public.new_recipe_pos_skus;
create policy "new_recipe_pos_skus_delete_corporate" on public.new_recipe_pos_skus for delete to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

drop policy if exists "new_recipe_ing_map_insert_corporate" on public.new_recipe_ingredient_master_map;
create policy "new_recipe_ing_map_insert_corporate" on public.new_recipe_ingredient_master_map for insert to authenticated
  with check ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

drop policy if exists "new_recipe_ing_map_update_corporate" on public.new_recipe_ingredient_master_map;
create policy "new_recipe_ing_map_update_corporate" on public.new_recipe_ingredient_master_map for update to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))))
  with check ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

drop policy if exists "new_recipe_ing_map_delete_corporate" on public.new_recipe_ingredient_master_map;
create policy "new_recipe_ing_map_delete_corporate" on public.new_recipe_ingredient_master_map for delete to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

drop policy if exists "auth_update_upc_mapping_stats" on public.upc_mappings;
create policy "auth_update_upc_mapping_stats" on public.upc_mappings for update to authenticated
  using (((lower(submitted_by_email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) OR (EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])))))))
  with check (((lower(submitted_by_email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) OR (EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])))))));

drop policy if exists "kount_client_errors_select" on public.kount_client_errors;
create policy "kount_client_errors_select" on public.kount_client_errors for select to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users WHERE ((lower(app_users.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (app_users.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (app_users.is_active = true)))));

drop policy if exists "kount_entries_deleted_log_select_corporate" on public.kount_entries_deleted_log;
create policy "kount_entries_deleted_log_select_corporate" on public.kount_entries_deleted_log for select to public
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((u.email = (auth.jwt() ->> 'email'::text)) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))));

drop policy if exists "kount_admin_audit_log_select" on public.kount_admin_audit_log;
create policy "kount_admin_audit_log_select" on public.kount_admin_audit_log for select to authenticated
  using ((EXISTS ( SELECT 1 FROM app_users u WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'admin'::text) AND (u.is_active = true)))));

drop policy if exists "auth_dev_app_users_select" on public.app_users;
create policy "auth_dev_app_users_select" on public.app_users for select to authenticated
  using (((lower(email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) OR kount_is_corporate()));

drop trigger if exists kount_members_role_in on public.kount_members;
drop function if exists public.kount_members_role_in();
alter table public.kount_admin_audit_log drop constraint if exists kount_admin_audit_log_action_check;
alter table public.kount_admin_audit_log add constraint kount_admin_audit_log_action_check check (action = any (array['invite', 'disable', 'enable', 'delete', 'reset_password', 'update_profile', 'migrate_legacy', 'grant_access', 'revoke_access', 'extend_access', 'resend_invite']));
drop function if exists public.kount_app_user_has(text);
commit;
