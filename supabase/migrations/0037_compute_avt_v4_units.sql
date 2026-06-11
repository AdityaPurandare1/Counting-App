-- =============================================================================
--  0037_compute_avt_v4_units
--
--  Fourth revision of compute_avt_for_audit (0030 → 0032 → 0035 → this).
--  v3 fixed WHICH rows count; v4 fixes WHAT UNITS they count in. Every term
--  of theo (start + purchases − depletions) and actual must be in MASTER
--  UNITS — whole sellable units of the master item (bottles for volume
--  masters, eaches/packs for the rest) — because that is what kount_entries
--  physically counts. v3 mixed at least three unit systems:
--
--  1. DIRECT MAPS counted every mapped POS sale as ONE WHOLE unit of the
--     master, even for by-the-glass items (one glass of wine depleted a full
--     bottle). Direct maps now mean "1 sale = 1 whole unit" ONLY where
--     menu_item_recipe_map.is_bottle_service = true; by-glass items must
--     deplete via recipes (the new-recipe bridge). Still priority 1.
--
--  2. NEW-RECIPE arm summed nri.quantity × nrimm.base_qty — raw MILLILITERS —
--     straight into depletions, so one 2 fl.oz pour depleted ~59 "bottles".
--     The PER-LINE unit (new_recipe_ingredients.unit) is now AUTHORITATIVE.
--     base_qty cannot be: it is GLOBAL per ingredient_name, but one
--     ingredient appears in recipes with DIFFERENT line units — '818 Blanco
--     1L Base Item' in prod has a 1.5 fl.oz pour line in one recipe and a
--     1 L comp line in another — so no single ml-per-unit fits all lines.
--     UNIT CONTRACT (the parallel ingestion package writes to this going
--     forward; pre-existing rows may not comply, see notes counters):
--       • volume-unit line (fl.oz/floz/oz, ml, l, gal, qt — case/dot-
--         insensitive) on a volume master ⇒ line_ml = quantity ×
--         unit_to_ml(unit); base_qty IGNORED (redundant when the unit is
--         explicit, wrong when units are mixed).
--       • 'each' line on a VOLUME master ⇒ quantity whole units directly
--         (1 each of a 355 ml beer = 1 can).
--       • 'each' line on a non-volume master ⇒ quantity × coalesce(base_qty,
--         1) count-units (base_qty = units per serving, typically 1).
--       • any other unit on a volume master (g, dash, tbsp, quart, ...) ⇒
--         last resort: base_qty as ml-per-unit when present, else skip
--         (+ unknown_unit_lines_skipped counter).
--     base_qty is therefore ONLY consulted for each-unit lines on non-volume
--     masters and as last resort for unknown units on volume masters.
--     Line-ml divides by the master's size in ml (new master_size CTE:
--     base_size normalized by base_unit). Volume masters missing base_size
--     fall back to 750 ml (+ masters_missing_base_size counter). Non-volume
--     masters (base_unit each/g/kg/lb) take each-unit ingredients as direct
--     unit counts and SKIP ml/g-style ingredients (+ nonvolume_ml_skipped
--     counter) — turning ml or grams into "packs" needs a pack size we
--     don't have.
--
--  3. PURCHASES summed v_effective_receipts.effective_qty — PACK COUNTS in
--     whatever pack the vendor shipped ('1L', '0.5gal', '4oz', ...) — as if
--     they were master units (a 1L case line on a 750ml master under-counted
--     by a third). effective_uom is now parsed (number + unit); volume packs
--     convert to bottle-equivalents via the master's base_size_ml; count and
--     weight packs ('1each','1lb','1bunch') stay qty-as-is by design;
--     unparseable/null uoms stay qty-as-is too (+ receipt_uom_unparsed
--     counter). Volume packs on masters with NULL/0 base_size_ml also stay
--     qty-as-is (the receipt pack is the best available proxy for the master
--     unit, and it matches how the shelf count sees those items) — that is
--     the div-by-zero guard. effective_qty (not net_qty) is kept: it is the
--     column v3 summed, and net-of-damage adjustments stay a receiving-side
--     concern.
--
--  4. OLD-RECIPE arm: recipe_items is EMPTY in prod (0 rows; its qty/uom
--     units are therefore indeterminate), so behavior is kept verbatim at
--     priority 3 with an old_recipe_unconverted notes counter — any future
--     rows flowing through unconverted become visible immediately.
--
--  notes gains: masters_missing_base_size, nonvolume_ml_skipped,
--  unknown_unit_lines_skipped, receipt_uom_unparsed, old_recipe_unconverted.
--
--  Everything else from 0035 is preserved verbatim: auth gate, coalesced
--  window (count2_closed_at falling back to completed_at), recount overrides
--  with whole-item NULL-zone precedence, idempotent delete+reinsert,
--  dedup-then-SUM depletions, name-only-entry/recount skips, cu_price from
--  latest purchase_items.avg_cost. v_kount_avt_row_provenance (debug view)
--  is NOT recreated: it reports source reachability, not quantities — note
--  only that its src_direct arm now over-reports 'direct' for maps with
--  is_bottle_service = false.
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`. STAGING ONLY until validated.
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
  -- 4·u) NEW in v4 — master size reference. base_size_ml = base_size
  --      normalized to milliliters by base_unit; NULL means non-volume
  --      (each/g/kg/lb) OR volume with base_size missing — is_volume tells
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
  -- 4p) Purchases — FIX v4: normalize each receipt line to master units.
  --     effective_uom is a pack-size string ('750ml','1L','0.5gal','4oz',
  --     '1each','1lb','1bunch', null); v3 summed effective_qty pack counts
  --     blind. Parse it into (number, unit); the case-mapped pack_unit_ml in
  --     the next CTE decides volume vs everything-else.
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
       and er.received_at >= coalesce(v_window_start, '-infinity'::timestamptz)
       and er.received_at <  v_window_end
       and coalesce(er.rejected, false) = false
       and er.master_item_id is not null
  ),
  purchase_lines_norm as (
    select master_item_id, effective_qty, base_size_ml,
           parts[1]::numeric as pack_num,
           case replace(lower(parts[2]), '.', '')   -- 'fl.oz' → 'floz'
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
  -- Volume pack on a volume master with a known size ⇒ bottle-equivalents:
  --   line_ml = pack_num × pack_unit_ml × effective_qty, then ÷ base_size_ml.
  -- Everything else (count/weight packs, unparseable/null uom, or volume
  -- pack on a master with NULL/0 base_size_ml — the div-by-zero guard) keeps
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
  -- Old-recipe arm: UNCONVERTED in v4 — recipe_items is empty in prod and
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
  -- authoritative — base_qty is GLOBAL per ingredient_name and cannot fit an
  -- ingredient that appears with different line units across recipes (the
  -- 1.5 fl.oz pour vs 1 L comp-line case). The rule, in branch order:
  --   • volume-unit line (fl.oz/floz/oz/ml/l/gal/qt, case/dot-insensitive)
  --     on a volume master ⇒ quantity × unit_to_ml(unit) / base_size_ml =
  --     bottle-equivalents; base_qty IGNORED. Volume masters with
  --     base_size_ml NULL/0 divide by 750 ml — the dominant bottle size —
  --     and are tallied in notes.masters_missing_base_size.
  --   • 'each' line on a volume master ⇒ quantity whole units directly:
  --     1 each of a 355 ml beer depletes exactly 1 can.
  --   • 'each' line on a non-volume master ⇒ quantity × base_qty taken as
  --     unit counts directly (contract: base_qty = units per serving,
  --     typically 1; NULL ⇒ 1).
  --   • unknown unit (g, dash, tbsp, quart, ...) on a volume master ⇒ last
  --     resort: quantity × base_qty (as ml-per-unit) / base_size_ml when
  --     base_qty is present, else SKIP (contributes 0). Tallied in
  --     notes.unknown_unit_lines_skipped.
  --   • non-volume master + any other unit ⇒ SKIP (contributes 0): mapping
  --     ml/g/oz-weight onto "packs" needs a pack size masters don't carry.
  --     Tallied in notes.nonvolume_ml_skipped.
  new_recipe_per_master as (
    select nri.recipe_id, nrimm.master_item_id,
           sum(
             case
               when ms.is_volume
                and replace(lower(coalesce(nri.unit, '')), '.', '')   -- 'fl.oz' → 'floz'
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
  --    NEW in v4 (unit-coverage tallies; each subquery mirrors the scope of
  --    the CTE whose fallback/skip it counts):
  --      masters_missing_base_size = distinct VOLUME masters reachable via
  --        this venue's new-recipe arm whose base_size is NULL/0 — these
  --        deplete against the 750 ml fallback.
  --      nonvolume_ml_skipped = ingredient→master pairs in that arm whose
  --        master is non-volume and whose ingredient unit isn't 'each' —
  --        these contribute 0 to depletions.
  --      unknown_unit_lines_skipped = ingredient→master pairs in that arm
  --        whose master IS volume but whose line unit is neither a volume
  --        unit nor 'each' AND whose base_qty is NULL — no ml-per-unit
  --        available, so these contribute 0 to depletions.
  --      receipt_uom_unparsed = this window's receipt lines whose
  --        effective_uom is NULL or doesn't parse (regex mirrors the
  --        purchases CTE — keep in sync) — these summed qty-as-is.
  --      old_recipe_unconverted = recipe_items rows that would feed this
  --        venue's old-recipe arm; 0 today (table empty), nonzero means
  --        unconverted units are flowing.
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
           and er.received_at >= coalesce(v_window_start, '-infinity'::timestamptz)
           and er.received_at <  v_window_end
           and coalesce(er.rejected, false) = false
           and er.master_item_id is not null
           and (er.effective_uom is null
                or er.effective_uom !~ '^\s*[0-9]*\.?[0-9]+\s*[a-zA-Z.]+\s*$')),
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
$fn$;

revoke all on function public.compute_avt_for_audit(uuid) from public;
grant  execute on function public.compute_avt_for_audit(uuid) to authenticated;

comment on function public.compute_avt_for_audit(uuid) is
  'Computes a kount_avt_reports + kount_avt_rows pair for the given audit from in-DB data (kount_entries + kount_recounts overrides, v_effective_receipts, pos_check_items, recipes/maps). v4 (0037): all terms in MASTER UNITS — direct maps gated to bottle service, recipe lines converted by their OWN unit (per-line unit authoritative; base_qty only for each-on-non-volume and unknown-unit fallback) then ÷ base_size_ml, receipt packs parsed to bottle-equivalents. Idempotent: re-running replaces the prior computed report for the same audit. Never touches uploaded reports.';

commit;

-- -----------------------------------------------------------------------------
-- Verification (run after applying — STAGING first)
-- -----------------------------------------------------------------------------
--
-- 1. Recompute a known audit and check the new counters land in notes:
--      select compute_avt_for_audit('<audit-id>');
--      select notes from kount_avt_reports
--       where audit_id = '<audit-id>' and source = 'computed';
--    Expect masters_missing_base_size, nonvolume_ml_skipped,
--    receipt_uom_unparsed present; old_recipe_unconverted = 0 (recipe_items
--    is empty in prod).
--
-- 2. Side-by-side per-drink sanity for a known Miami bridge item — replays
--    the v4 new-recipe conversion for 'Spicy Siena' at Delilah Miami
--    (venue 288b7f22-ffdc-4701-a396-a6b415aff0f1). Expect 818 Blanco 1L
--    (2 fl.oz pour, master 1 L ⇒ 1000 ml; the LINE unit drives the
--    conversion, base_qty is ignored) to deplete 2 × 29.5735 / 1000 ≈
--    0.0591 bottles per drink — NOT 59.147:
--      select nri.ingredient_name, nri.quantity, nri.unit,
--             mi.base_unit, mi.base_size,
--             round(
--               (nri.quantity *
--                  case replace(lower(coalesce(nri.unit, '')), '.', '')
--                    when 'floz' then 29.5735
--                    when 'oz'   then 29.5735
--                    when 'ml'   then 1
--                    when 'l'    then 1000
--                    when 'gal'  then 3785.41
--                    when 'qt'   then 946.353
--                  end)
--               / coalesce(nullif(
--                   case lower(mi.base_unit)
--                     when 'ml' then mi.base_size
--                     when 'l'  then mi.base_size * 1000
--                     when 'floz' then mi.base_size * 29.5735
--                     when 'oz'   then mi.base_size * 29.5735
--                     when 'gal'  then mi.base_size * 3785.41
--                     when 'qt'   then mi.base_size * 946.353
--                   end, 0), 750), 4) as units_per_drink
--        from new_recipe_pos_skus nrps
--        join new_recipe_ingredients nri
--          on nri.recipe_id = nrps.recipe_id
--         and coalesce(nri.is_sub_recipe, false) = false
--        join new_recipe_ingredient_master_map nrimm
--          on nrimm.ingredient_name = nri.ingredient_name
--        join master_items mi on mi.id = nrimm.master_item_id
--       where nrps.venue_id = '288b7f22-ffdc-4701-a396-a6b415aff0f1'
--         and lower(trim(nrps.pos_sku)) = 'spicy siena'
--         and lower(mi.base_unit) in ('ml','l','floz','oz','gal','qt')
--         and replace(lower(coalesce(nri.unit, '')), '.', '')
--               in ('floz','oz','ml','l','gal','qt');
--
-- 2b. Mixed-unit ingredient — the bug this revision fixes. 'Grey Goose 1L
--     Base Item' (and '818 Blanco 1L Base Item') has a 1.5 fl.oz pour line
--     in one recipe AND a 1 L comp/package line in another, but base_qty is
--     GLOBAL per ingredient_name (29.5735). Per-line conversion must yield
--     1.5 × 29.5735 / 1000 ≈ 0.0444 bottles for the pour line and exactly
--     1000 / 1000 = 1.0 bottle for the 1 L comp line:
--      select nri.recipe_id, nri.ingredient_name, nri.quantity, nri.unit,
--             round(
--               (nri.quantity *
--                  case replace(lower(coalesce(nri.unit, '')), '.', '')
--                    when 'floz' then 29.5735
--                    when 'oz'   then 29.5735
--                    when 'ml'   then 1
--                    when 'l'    then 1000
--                    when 'gal'  then 3785.41
--                    when 'qt'   then 946.353
--                  end) / 1000, 4) as bottles_per_line   -- master is 1 L
--        from new_recipe_ingredients nri
--       where nri.ingredient_name in ('Grey Goose 1L Base Item',
--                                     '818 Blanco 1L Base Item')
--         and coalesce(nri.is_sub_recipe, false) = false
--       order by nri.ingredient_name, nri.unit, nri.quantity;
--
-- 2c. Each-on-volume-master ('1 each' beer lines, e.g. Bud Light / Estrella
--     on 12 oz masters): the each branch takes quantity as WHOLE UNITS, so
--     1 each depletes exactly 1 can — base_size_ml never enters. Spot-check:
--      select nri.ingredient_name, nri.quantity, nri.unit,
--             mi.base_unit, mi.base_size,
--             nri.quantity as units_per_serving
--        from new_recipe_ingredients nri
--        join new_recipe_ingredient_master_map nrimm
--          on nrimm.ingredient_name = nri.ingredient_name
--        join master_items mi on mi.id = nrimm.master_item_id
--       where lower(coalesce(nri.unit, '')) = 'each'
--         and lower(mi.base_unit) in ('ml','l','floz','oz','gal','qt')
--         and coalesce(nri.is_sub_recipe, false) = false;
--
-- 3. Bottle-service gate: depletions for a by-glass master with a direct map
--    (is_bottle_service = false) should now come from the recipe bridge (or
--    drop to 0 if unbridged) instead of 1-sale-=-1-bottle. Compare a v3 vs
--    v4 computed report for the same audit:
--      select item_name, depletions from kount_avt_rows
--       where report_id = '<old-report-id>' order by item_name;  -- before
--      select item_name, depletions from kount_avt_rows
--       where report_id = '<new-report-id>' order by item_name;  -- after
--
-- 4. Purchases normalization: pick a window receipt line with effective_uom
--    '1L' on a 750ml master — its contribution should be
--    effective_qty × 1000 / 750, not effective_qty:
--      select er.description, er.effective_qty, er.effective_uom,
--             mi.base_unit, mi.base_size
--        from v_effective_receipts er
--        join master_items mi on mi.id = er.master_item_id
--       where er.effective_uom is not null limit 20;
--
-- 5. Unparsed-uom visibility: notes ->> 'receipt_uom_unparsed' should equal
--      select count(*) from v_effective_receipts er
--        join invoices i on i.id = er.invoice_id
--       where i.venue_id = '<ops-venue-id>'
--         and er.received_at >= '<window-start>' and er.received_at < '<window-end>'
--         and coalesce(er.rejected, false) = false
--         and er.master_item_id is not null
--         and (er.effective_uom is null
--              or er.effective_uom !~ '^\s*[0-9]*\.?[0-9]+\s*[a-zA-Z.]+\s*$');
