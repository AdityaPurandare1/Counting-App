-- ROLLBACK for 0064: the byte-exact pre-0064 compute_avt_for_audit, then drop the column.
begin;
CREATE OR REPLACE FUNCTION public.compute_avt_for_audit(p_audit_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_report_id      uuid;
  v_kount_venue_id text;
  v_venue_name     text;
  v_store          text;
  v_ops_venue_id   uuid;
  v_window_start   timestamptz;
  v_window_end     timestamptz;
  v_window_phase   text;
  v_count2_at      timestamptz;
  v_completed_at   timestamptz;
  v_prev_audit_id  uuid;
  v_inserted       integer;
  v_notes          text;
  v_depletion_source text;
  v_use_item_facts boolean := false;
begin
  -- 1) Resolve audit context. Window end falls back to completed_at (historic
  --    Summary-shortcut submits left count2_closed_at NULL) and then to
  --    count1_closed_at (count-1-close interim compute â€” see 0038 header).
  select a.venue_id, kv.name, coalesce(kv.store_aliases[1], kv.name),
         kv.ops_venue_id,
         coalesce(a.count2_closed_at, a.completed_at, a.count1_closed_at),
         a.count2_closed_at, a.completed_at
    into v_kount_venue_id, v_venue_name, v_store, v_ops_venue_id, v_window_end,
         v_count2_at, v_completed_at
    from public.kount_audits a
    join public.kount_venues kv on kv.id = a.venue_id
   where a.id = p_audit_id;

  if not found then
    raise exception 'compute_avt_for_audit: audit % not found', p_audit_id
      using errcode = 'P0002';
  end if;
  if v_window_end is null then
    raise exception 'compute_avt_for_audit: audit % has not closed count 1 (count2_closed_at, completed_at and count1_closed_at are all null)',
      p_audit_id using errcode = '22023';
  end if;

  -- window_phase: 'count2' once count2_closed_at/completed_at exists (full
  -- audit window), else 'count1' (interim count-1-close compute).
  v_window_phase := case
    when coalesce(v_count2_at, v_completed_at) is not null then 'count2'
    else 'count1'
  end;

  -- 1b) Authorization gate (unchanged from 0030).
  if not exists (
    select 1
      from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and (
         u.role = any (array['corporate','admin'])
         or v_kount_venue_id = any(u.venue_ids)
       )
  ) then
    raise exception 'not authorized to compute avt for audit %', p_audit_id
      using errcode = '42501';
  end if;

  -- Window start = the prior submitted audit's close for the same kount
  -- venue, with the same coalesce fallback as the window end. count1_closed_at
  -- is added for symmetry only; a submitted audit always has count2/completed.
  select coalesce(prev.count2_closed_at, prev.completed_at, prev.count1_closed_at), prev.id
    into v_window_start, v_prev_audit_id
    from public.kount_audits prev
   where prev.venue_id = v_kount_venue_id
     and prev.status   = 'submitted'
     and prev.id      <> p_audit_id
     and coalesce(prev.count2_closed_at, prev.completed_at, prev.count1_closed_at) < v_window_end
   order by coalesce(prev.count2_closed_at, prev.completed_at, prev.count1_closed_at) desc
   limit 1;

  -- 1c) Depletion source. Only a venue that has opted in reads item_day_facts,
  --     and only for a window with no per-check lines; every other venue
  --     skips this block and computes exactly as before.
  select kv.depletion_source into v_depletion_source
    from public.kount_venues kv where kv.id = v_kount_venue_id;
  if v_depletion_source = 'item_day_facts' and v_ops_venue_id is not null then
    v_use_item_facts := not exists (
      select 1 from public.pos_check_items p
       where p.venue_id = v_ops_venue_id
         and p.business_date >= coalesce(v_window_start::date, '-infinity'::date)
         and p.business_date <  v_window_end::date
    );
  end if;

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
  -- 4Â·u) NEW in v4 â€” master size reference. base_size_ml = base_size
  --      normalized to milliliters by base_unit; NULL means non-volume
  --      (each/g/kg/lb) OR volume with base_size missing â€” is_volume tells
  --      those two apart. Prod base_unit values: each, floz, g, gal, kg, L,
  --      lb, ml, oz, qt ('oz' on masters means fluid ounces; weight masters
  --      use g/kg/lb).
  master_size as (
    select mi.id as master_item_id,
           coalesce(
             lower(mi.base_unit) in ('ml','l','floz','oz','gal','qt'),
             false)                                  as is_volume,
           case lower(mi.base_unit)
             when 'ml'   then mi.base_size
             when 'l'    then mi.base_size * 1000
             when 'floz' then mi.base_size * 29.5735
             when 'oz'   then mi.base_size * 29.5735
             when 'gal'  then mi.base_size * 3785.41
             when 'qt'   then mi.base_size * 946.353
             else null                               -- non-volume master
           end                                       as base_size_ml
      from public.master_items mi
  ),
  -- 4a) Actuals â€” SUM per (master, zone); two same-zone rows under different
  --     item_names now add instead of one being dropped by the old rn=1 pick.
  --     kount_entries.zone is NOT NULL, so it keys directly. is_recount =
  --     false excludes legacy recount rows: no current code writes true, but
  --     historic rows may exist and kount_recounts is the canonical
  --     correction store now â€” summing both would double-count.
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
  -- zone NULL â‡’ WHOLE-ITEM override (the phone writes recounts without a
  -- zone; entries always have one, so a ''-keyed join would match nothing
  -- and ADD count2_qty on top of the zone sums instead of replacing them).
  -- zone set â‡’ replaces that zone's sum only; other zones still sum in.
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
  -- override WINS â€” coalesce(whole, zone-composite) discards the per-zone
  -- result entirely. FULL OUTER again so a whole-item recount for a master
  -- with no entries and no zone recounts still contributes.
  actuals as (
    select coalesce(wo.master_item_id, zt.master_item_id) as master_item_id,
           coalesce(wo.count2_qty, zt.qty)::numeric       as qty
      from actual_zone_totals zt
      full outer join actual_whole_overrides wo
        on wo.master_item_id = zt.master_item_id
  ),
  -- 4b) Starts â€” identical logic against the previous audit (entries +
  --     recounts, same is_recount exclusion and whole-item-wins precedence
  --     as 4a). v_prev_audit_id NULL â‡’ all CTEs are empty â‡’ starts 0.
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
  -- 4p) Purchases â€” FIX v4: normalize each receipt line to master units.
  --     effective_uom is a pack-size string ('750ml','1L','0.5gal','4oz',
  --     '1each','1lb','1bunch', null); v3 summed effective_qty pack counts
  --     blind. Parse it into (number, unit); the case-mapped pack_unit_ml in
  --     the next CTE decides volume vs everything-else.
  --     FIX 0039: window filter uses coalesce(er.received_at,
  --     i.invoice_date::timestamptz) â€” receiving_events is empty so
  --     received_at is always NULL; fall back to the populated invoice_date.
  purchase_lines as (
    select er.master_item_id,
           er.effective_qty,        -- kept from v3 (net_qty exists but was never used here)
           ms.base_size_ml,
           regexp_match(er.effective_uom,
                        '^\s*([0-9]*\.?[0-9]+)\s*([a-zA-Z.]+)\s*$') as parts
      from public.v_effective_receipts er
      join public.invoices i on i.id = er.invoice_id
      left join master_size ms on ms.master_item_id = er.master_item_id
     where v_ops_venue_id is not null
       and i.venue_id = v_ops_venue_id
       and coalesce(er.received_at, i.invoice_date::timestamptz) >= coalesce(v_window_start, '-infinity'::timestamptz)
       and coalesce(er.received_at, i.invoice_date::timestamptz) <  v_window_end
       and coalesce(er.rejected, false) = false
       and er.master_item_id is not null
  ),
  purchase_lines_norm as (
    select master_item_id, effective_qty, base_size_ml,
           parts[1]::numeric as pack_num,
           case replace(lower(parts[2]), '.', '')   -- 'fl.oz' â†’ 'floz'
             when 'ml'   then 1
             when 'l'    then 1000
             when 'floz' then 29.5735
             when 'oz'   then 29.5735
             when 'gal'  then 3785.41
             when 'qt'   then 946.353
             else null   -- each/lb/bunch/... : count or weight pack, no ml
           end            as pack_unit_ml
      from purchase_lines
  ),
  -- Volume pack on a volume master with a known size â‡’ bottle-equivalents:
  --   line_ml = pack_num Ã— pack_unit_ml Ã— effective_qty, then Ã· base_size_ml.
  -- Everything else (count/weight packs, unparseable/null uom, or volume
  -- pack on a master with NULL/0 base_size_ml â€” the div-by-zero guard) keeps
  -- effective_qty as-is, matching how the shelf count sees those items.
  purchases as (
    select master_item_id,
           sum(case
                 when pack_unit_ml is not null
                  and coalesce(base_size_ml, 0) > 0
                 then (pack_num * pack_unit_ml * effective_qty) / base_size_ml
                 else effective_qty
               end)::numeric as qty
      from purchase_lines_norm
     group by master_item_id
  ),
  -- 4c..4f) Depletion candidates, one row per (master, POS item, source).
  --     All three arms key the POS item by lower(trim(pci.item_name)) so the
  --     same menu item lines up across sources for the dedup below.
  --
  --     FIX v4: a direct map means "1 sale = 1 whole unit of the master"
  --     ONLY for bottle service (is_bottle_service = true). By-glass /
  --     by-pour items must deplete via recipes (the new-recipe bridge) so a
  --     glass of wine no longer depletes a full bottle. Still priority 1.
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
       and coalesce(mirm.is_bottle_service, false) = true
       and mirm.master_item_id is not null
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by mirm.master_item_id, lower(trim(pci.item_name))
  ),
  -- Old-recipe arm: UNCONVERTED in v4 â€” recipe_items is empty in prod and
  -- its qty/uom unit semantics are indeterminate (no data to ground a
  -- conversion). Kept verbatim; old_recipe_unconverted in notes flags any
  -- rows that ever start flowing through here so the conversion can be
  -- written against real data.
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
  -- FIX v4: ing_units = MASTER UNITS consumed by ONE serving of the recipe
  -- (v3's ing_qty was raw ml posing as units). The PER-LINE unit is
  -- authoritative â€” base_qty is GLOBAL per ingredient_name and cannot fit an
  -- ingredient that appears with different line units across recipes (the
  -- 1.5 fl.oz pour vs 1 L comp-line case). The rule, in branch order:
  --   â€¢ volume-unit line (fl.oz/floz/oz/ml/l/gal/qt, case/dot-insensitive)
  --     on a volume master â‡’ quantity Ã— unit_to_ml(unit) / base_size_ml =
  --     bottle-equivalents; base_qty IGNORED. Volume masters with
  --     base_size_ml NULL/0 divide by 750 ml â€” the dominant bottle size â€”
  --     and are tallied in notes.masters_missing_base_size.
  --   â€¢ 'each' line on a volume master â‡’ quantity whole units directly:
  --     1 each of a 355 ml beer depletes exactly 1 can.
  --   â€¢ 'each' line on a non-volume master â‡’ quantity Ã— base_qty taken as
  --     unit counts directly (contract: base_qty = units per serving,
  --     typically 1; NULL â‡’ 1).
  --   â€¢ unknown unit (g, dash, tbsp, quart, ...) on a volume master â‡’ last
  --     resort: quantity Ã— base_qty (as ml-per-unit) / base_size_ml when
  --     base_qty is present, else SKIP (contributes 0). Tallied in
  --     notes.unknown_unit_lines_skipped.
  --   â€¢ non-volume master + any other unit â‡’ SKIP (contributes 0): mapping
  --     ml/g/oz-weight onto "packs" needs a pack size masters don't carry.
  --     Tallied in notes.nonvolume_ml_skipped.
  new_recipe_per_master as (
    select nri.recipe_id, nrimm.master_item_id,
           sum(
             case
               when ms.is_volume
                and replace(lower(coalesce(nri.unit, '')), '.', '')   -- 'fl.oz' â†’ 'floz'
                      in ('floz','oz','ml','l','gal','qt') then
                 (coalesce(nri.quantity, 0)
                    * case replace(lower(nri.unit), '.', '')
                        when 'floz' then 29.5735
                        when 'oz'   then 29.5735               -- fluid on volume masters
                        when 'ml'   then 1
                        when 'l'    then 1000
                        when 'gal'  then 3785.41
                        when 'qt'   then 946.353
                      end)
                 / coalesce(nullif(ms.base_size_ml, 0), 750)
               when lower(coalesce(nri.unit, '')) = 'each' then
                 case
                   when ms.is_volume then coalesce(nri.quantity, 0)   -- 1 each = 1 whole unit
                   else coalesce(nri.quantity, 0) * coalesce(nrimm.base_qty, 1)
                 end
               when ms.is_volume and nrimm.base_qty is not null then
                 -- unknown unit: base_qty as ml-per-unit, last resort
                 coalesce(nri.quantity, 0) * nrimm.base_qty
                 / coalesce(nullif(ms.base_size_ml, 0), 750)
               else 0   -- skipped: nonvolume_ml_skipped / unknown_unit_lines_skipped
             end
           )::numeric as ing_units
      from public.new_recipe_ingredients nri
      join public.new_recipe_ingredient_master_map nrimm
        on nrimm.ingredient_name = nri.ingredient_name
      join master_size ms
        on ms.master_item_id = nrimm.master_item_id
     where coalesce(nri.is_sub_recipe, false) = false
     group by nri.recipe_id, nrimm.master_item_id
  ),
  -- name-join from 0032 kept: the bridge stores menu item names, not POS UUIDs.
  dep_new_recipe as (
    select nrpm.master_item_id,
           lower(trim(pci.item_name))                   as pos_key,
           sum(pci.quantity * nrpm.ing_units)::numeric  as qty,
           2                                            as priority
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
  -- 4f-bis) The same three arms, sourced from item_day_facts instead of
  --     pos_check_items. For a venue whose POS reaches KevaOS only as daily
  --     item aggregates (Toast via aggregateToastItems), where per-check
  --     lines never land. Identical windows (business_date at day grain, as
  --     above), identical joins and priorities; quantity_sold excludes voids
  --     and includes comps, which is what depletion wants.
  --     Empty unless v_use_item_facts: the venue opted in
  --     (kount_venues.depletion_source) AND has no pos_check_items in this
  --     window - so it can never double-count, and if per-check lines start
  --     arriving for it the original arms take over on their own.
  dep_direct_f as (
    select mirm.master_item_id,
           lower(trim(pci.menu_item_name)) as pos_key,
           sum(pci.quantity_sold)::numeric as qty,
           1                          as priority   -- direct beats everything
      from public.menu_item_recipe_map mirm
      join public.item_day_facts pci
        on pci.venue_id = mirm.venue_id
       and pci.menu_item_name = mirm.menu_item_name
     where v_use_item_facts
       and v_ops_venue_id is not null
       and mirm.venue_id = v_ops_venue_id
       and mirm.is_active = true
       and coalesce(mirm.is_excluded, false) = false
       and coalesce(mirm.is_bottle_service, false) = true
       and mirm.master_item_id is not null
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by mirm.master_item_id, lower(trim(pci.menu_item_name))
  ),
  dep_old_recipe_f as (
    select orpm.master_item_id,
           lower(trim(pci.menu_item_name))                 as pos_key,
           sum(pci.quantity_sold * orpm.ing_qty)::numeric  as qty,
           3                                          as priority -- last resort
      from public.menu_item_recipe_map mirm
      join public.item_day_facts pci
        on pci.venue_id = mirm.venue_id
       and pci.menu_item_name = mirm.menu_item_name
      join old_recipe_per_master orpm
        on orpm.recipe_id = mirm.recipe_id
     where v_use_item_facts
       and v_ops_venue_id is not null
       and mirm.venue_id = v_ops_venue_id
       and mirm.is_active = true
       and mirm.recipe_id is not null
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by orpm.master_item_id, lower(trim(pci.menu_item_name))
  ),
  dep_new_recipe_f as (
    select nrpm.master_item_id,
           lower(trim(pci.menu_item_name))                   as pos_key,
           sum(pci.quantity_sold * nrpm.ing_units)::numeric  as qty,
           2                                            as priority
      from public.item_day_facts pci
      join public.new_recipe_pos_skus nrps
        on nrps.venue_id = pci.venue_id
       and lower(trim(nrps.pos_sku)) = lower(trim(pci.menu_item_name))
      join new_recipe_per_master nrpm
        on nrpm.recipe_id = nrps.recipe_id
     where v_use_item_facts
       and v_ops_venue_id is not null
       and pci.venue_id = v_ops_venue_id
       and pci.business_date >= coalesce(v_window_start::date, '-infinity'::date)
       and pci.business_date <  v_window_end::date
     group by nrpm.master_item_id, lower(trim(pci.menu_item_name))
  ),
  -- 4g) Dedup-then-SUM (from 0035): the same (master, POS item) reached via
  --     multiple sources keeps exactly one candidate by priority direct >
  --     new_recipe > old_recipe; DISJOINT POS items for the same master then
  --     SUM instead of dropping the smaller stream.
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
        union all
        select * from dep_direct_f
        union all
        select * from dep_new_recipe_f
        union all
        select * from dep_old_recipe_f
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
  --    window_phase (0038) = 'count2' (full window) or 'count1' (interim
  --    count-1-close compute), so a report's provenance is unambiguous.
  --    NEW in v4 (unit-coverage tallies; each subquery mirrors the scope of
  --    the CTE whose fallback/skip it counts):
  --      masters_missing_base_size = distinct VOLUME masters reachable via
  --        this venue's new-recipe arm whose base_size is NULL/0 â€” these
  --        deplete against the 750 ml fallback.
  --      nonvolume_ml_skipped = ingredientâ†’master pairs in that arm whose
  --        master is non-volume and whose ingredient unit isn't 'each' â€”
  --        these contribute 0 to depletions.
  --      unknown_unit_lines_skipped = ingredientâ†’master pairs in that arm
  --        whose master IS volume but whose line unit is neither a volume
  --        unit nor 'each' AND whose base_qty is NULL â€” no ml-per-unit
  --        available, so these contribute 0 to depletions.
  --      receipt_uom_unparsed = this window's receipt lines whose
  --        effective_uom is NULL or doesn't parse (regex mirrors the
  --        purchases CTE â€” keep in sync) â€” these summed qty-as-is.
  --      old_recipe_unconverted = recipe_items rows that would feed this
  --        venue's old-recipe arm; 0 today (table empty), nonzero means
  --        unconverted units are flowing.
  --    NEW in 0039:
  --      purchases_by_invoice_date = this window's purchase lines that matched
  --        via the invoice_date fallback (received_at NULL but invoice_date
  --        in-window). Mirrors the purchase_lines scope exactly. Today this is
  --        ~100% of matched lines since receiving_events is empty; it drops as
  --        real received_at values appear.
  v_notes := jsonb_build_object(
    'ops_venue_bridged',          v_ops_venue_id is not null,
    'ops_venue_id',               v_ops_venue_id,
    'prev_audit_id',              v_prev_audit_id,
    'window_start',               v_window_start,
    'window_end',                 v_window_end,
    'window_phase',               v_window_phase,
    'depletion_sources_populated', jsonb_build_object(
       'direct',     (select count(*) from public.menu_item_recipe_map
                       where venue_id = v_ops_venue_id
                         and is_active = true
                         and coalesce(is_excluded, false) = false
                         and coalesce(is_bottle_service, false) = true
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
        ) t),
    'masters_missing_base_size',
       (select count(distinct nrimm.master_item_id)
          from public.new_recipe_ingredient_master_map nrimm
          join public.master_items mi on mi.id = nrimm.master_item_id
          join public.new_recipe_ingredients nri
            on nri.ingredient_name = nrimm.ingredient_name
           and coalesce(nri.is_sub_recipe, false) = false
          join public.new_recipe_pos_skus nrps
            on nrps.recipe_id = nri.recipe_id
           and nrps.venue_id  = v_ops_venue_id
         where lower(mi.base_unit) in ('ml','l','floz','oz','gal','qt')
           and coalesce(mi.base_size, 0) = 0),
    'nonvolume_ml_skipped',
       (select count(*)
          from public.new_recipe_ingredients nri
          join public.new_recipe_ingredient_master_map nrimm
            on nrimm.ingredient_name = nri.ingredient_name
          join public.master_items mi on mi.id = nrimm.master_item_id
          join public.new_recipe_pos_skus nrps
            on nrps.recipe_id = nri.recipe_id
           and nrps.venue_id  = v_ops_venue_id
         where coalesce(nri.is_sub_recipe, false) = false
           and (lower(mi.base_unit) in ('ml','l','floz','oz','gal','qt')) is not true
           and lower(coalesce(nri.unit, '')) <> 'each'),
    'unknown_unit_lines_skipped',
       (select count(*)
          from public.new_recipe_ingredients nri
          join public.new_recipe_ingredient_master_map nrimm
            on nrimm.ingredient_name = nri.ingredient_name
          join public.master_items mi on mi.id = nrimm.master_item_id
          join public.new_recipe_pos_skus nrps
            on nrps.recipe_id = nri.recipe_id
           and nrps.venue_id  = v_ops_venue_id
         where coalesce(nri.is_sub_recipe, false) = false
           and lower(mi.base_unit) in ('ml','l','floz','oz','gal','qt')
           and replace(lower(coalesce(nri.unit, '')), '.', '')
                 not in ('floz','oz','ml','l','gal','qt','each')
           and nrimm.base_qty is null),
    'receipt_uom_unparsed',
       (select count(*)
          from public.v_effective_receipts er
          join public.invoices i on i.id = er.invoice_id
         where v_ops_venue_id is not null
           and i.venue_id = v_ops_venue_id
           and coalesce(er.received_at, i.invoice_date::timestamptz) >= coalesce(v_window_start, '-infinity'::timestamptz)
           and coalesce(er.received_at, i.invoice_date::timestamptz) <  v_window_end
           and coalesce(er.rejected, false) = false
           and er.master_item_id is not null
           and (er.effective_uom is null
                or er.effective_uom !~ '^\s*[0-9]*\.?[0-9]+\s*[a-zA-Z.]+\s*$')),
    'purchases_by_invoice_date',
       (select count(*)
          from public.v_effective_receipts er
          join public.invoices i on i.id = er.invoice_id
         where v_ops_venue_id is not null
           and i.venue_id = v_ops_venue_id
           and er.received_at is null
           and i.invoice_date::timestamptz >= coalesce(v_window_start, '-infinity'::timestamptz)
           and i.invoice_date::timestamptz <  v_window_end
           and coalesce(er.rejected, false) = false
           and er.master_item_id is not null),
    'old_recipe_unconverted',
       (select count(*)
          from public.recipe_items ri
          join public.purchase_items pi on pi.id = ri.item_id
          join public.menu_item_recipe_map mirm
            on mirm.recipe_id = ri.recipe_id
           and mirm.venue_id  = v_ops_venue_id
           and mirm.is_active = true
         where coalesce(ri.is_packaging, false) = false
           and pi.master_item_id is not null)
  )::text;

  update public.kount_avt_reports
     set row_count = v_inserted,
         notes     = v_notes
   where id = v_report_id;

  return v_report_id;
end
$function$;
alter table public.kount_venues drop constraint if exists kount_venues_purchase_mapping_check;
alter table public.kount_venues drop column if exists purchase_mapping;
commit;
