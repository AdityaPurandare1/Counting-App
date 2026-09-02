-- =============================================================================
--  0047_merge_master_items
--
--  Admin "merge duplicate variants" primitive. Counters hit many near-identical
--  master_items (e.g. "Veuve Clicquot, 'Yellow Label', Brut Champagne 750ml"
--  vs a bare "Veuve Brut", or "Blanc de Blanc" vs "Blanc de Blancs"). 0044
--  auto-folded the UNAMBIGUOUS ones (exactly one active twin) via merged_into_id
--  and taught v_effective_receipts to follow the redirect for PURCHASES. What
--  0044 could NOT resolve: clusters with 2+ ACTIVE masters (needs a human to
--  pick the canonical), and the COUNT side (kount_entries etc.) never followed
--  the redirect at all.
--
--  This RPC lets an admin pick a WINNER (canonical, active) and one or more
--  LOSERS, and folds losers into the winner by:
--    • REPOINTING the counting-owned tables loser→winner:
--        kount_entries, kount_recounts, kount_carried_items,
--        kount_pending_items, master_item_upcs, upc_mappings
--      (these are written only by the counting app — never re-synced from R365 —
--       so repointing is durable, unlike purchase_items which 0044 deliberately
--       left alone).
--    • Setting loser.merged_into_id = winner and loser.is_active = false, and
--      collapsing any existing redirect chains that pointed at a loser.
--
--  WHY NO compute_avt CHANGE: compute_avt_for_audit (v4, 0037) groups counts by
--  raw master_item_id and unions all_masters from actuals/starts/purchases/
--  depletions. After the repoint, the loser has no counts/recounts, purchases
--  already redirect to the winner (0044), so the loser drops out of all_masters
--  entirely — the duplicate disappears from variance and both sides consolidate
--  on the winner, with ZERO surgery on that critical function. Recompute affected
--  closed audits afterward (RPC returns their ids) to refresh computed reports.
--
--  COLLISION HANDLING on repoint:
--    • kount_carried_items — UNIQUE(master_item_id): if the winner is already
--      carried, DELETE the loser's carried row instead of repointing.
--    • master_item_upcs — UNIQUE(upc_normalized): if the winner already owns a
--      loser's normalized UPC, DELETE the loser's duplicate instead of moving.
--    kount_entries / kount_recounts unique keys are on item_id/item_name (NOT
--    master_item_id), so repointing there never collides; two rows for the same
--    (audit,zone,master) simply SUM in compute_avt.
--
--  p_dry_run = true returns the SAME impact summary WITHOUT mutating, for a UI
--  preview. Corporate-only (catalog is global across venues). Atomic (function).
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`. STAGING ONLY until validated, then add
--  the APPLIED.md row.
--  ROLLBACK is NOT automatic (data repoint). Before running for real, snapshot:
--    create table _bak_0047_entries as select id, master_item_id from kount_entries where master_item_id = any(<losers>);
--    ... (and the other repointed tables) so a manual restore is possible.
-- =============================================================================

begin;

create or replace function public.merge_master_items(
  p_winner   uuid,
  p_losers   uuid[],
  p_dry_run  boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
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
       and u.role = 'corporate'
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

  -- Audits touched by the losers' counts/recounts — returned so the caller can
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
  -- 1. kount_entries: unique key is on item_id/name, not master → safe repoint.
  update public.kount_entries set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_entries = row_count;

  -- 2. kount_recounts: same (unique on item_id/name + zone) → safe repoint.
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

  -- 4. kount_pending_items: partial (non-unique) index → free repoint.
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

  -- 6. upc_mappings (pending/approved queue): partial index → free repoint.
  update public.upc_mappings set master_item_id = p_winner
   where master_item_id = any(v_losers);
  get diagnostics v_mappings = row_count;

  -- 7. Collapse any redirect chains that pointed at a loser, then fold the
  --    losers: tombstone → winner, archived. (winner itself never a loser.)
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
$fn$;

revoke all on function public.merge_master_items(uuid, uuid[], boolean) from public;
grant  execute on function public.merge_master_items(uuid, uuid[], boolean) to authenticated;

comment on function public.merge_master_items(uuid, uuid[], boolean) is
  'Folds loser master_items into an active winner: repoints counting-owned tables (kount_entries/recounts/carried/pending, master_item_upcs, upc_mappings) loser→winner, sets loser.merged_into_id + is_active=false, collapses redirect chains. Purchases already follow merged_into_id (0044); counts consolidate via the repoint so the loser drops out of compute_avt with no change to that function. p_dry_run=true returns the impact summary without mutating. Corporate-only. Returns jsonb incl. affected_audits to recompute.';

commit;

-- -----------------------------------------------------------------------------
-- Verification (run after applying — STAGING first)
-- -----------------------------------------------------------------------------
--
-- 1. Dry-run a known dup pair (winner first, then loser) — expect nonzero
--    repoint counts and NO mutation:
--      select public.merge_master_items(
--        '<winner-uuid>', array['<loser-uuid>']::uuid[], true);
--      -- confirm the loser is still active afterwards:
--      select id, is_active, merged_into_id from master_items where id = '<loser-uuid>';
--
-- 2. Real run, then confirm the fold + repoint:
--      select public.merge_master_items('<winner>', array['<loser>']::uuid[], false);
--      select id, is_active, merged_into_id from master_items where id = '<loser>';
--        -- expect is_active=false, merged_into_id=<winner>
--      select count(*) from kount_entries where master_item_id = '<loser>';  -- expect 0
--      select count(*) from master_item_upcs where master_item_id = '<loser>'; -- expect 0
--
-- 3. Recompute affected audits (returned as affected_audits) so computed
--    variance consolidates on the winner:
--      select compute_avt_for_audit('<affected-audit-id>');
--
-- 4. Auth negative: a non-corporate JWT must get 42501.
