-- =============================================================================
--  0040_repoint_carried_to_active
--
--  Re-points carried rows off archived (is_active = false) master_items onto
--  the active same-name twin, then prunes the unresolvable remainder.
--
--  Context:
--    The Fix F admin workflow soft-deletes bad/legacy master_items variants
--    (is_active = false) and keeps an active twin under the same name. But
--    kount_carried_items rows that were created against the archived variant
--    kept pointing at the dead master. After the dedup work, ~1,175 carried
--    rows still point at an archived master:
--      - ~802 of them have an active same-name twin → re-point onto it.
--      - the remaining ~373 have no active twin (or the active twin already
--        carries) → prune them.
--    Phone v1.76 also stops loading these rows into carriedSet at runtime
--    (the loadCarriedItemsFromSupabase query now inner-joins on is_active),
--    but the data still needs cleaning so the catalog is correct at the source
--    and so reconcileCarriedAgainstMaster stops scoring them as unresolved.
--
--  Collision guard:
--    kount_carried_items has a PLAIN UNIQUE index on master_item_id (0033).
--    A blind UPDATE that moves an archived-pointing row onto an active twin
--    that ALREADY has a carried row would violate that unique index. So we
--    only re-point archived rows whose active twin does NOT already carry.
--    Archived-pointing rows whose active twin already carries (collisions),
--    plus any archived row with no active twin, are removed by the prune step.
--
--  Idempotent: re-running is a no-op once no carried row points at an
--  inactive master (the post-commit SELECT asserts this is 0).
-- =============================================================================

begin;

-- 1. Re-point archived-pointing carried rows onto the active same-name twin,
--    but ONLY where the active twin does not already have a carried row
--    (otherwise the UNIQUE(master_item_id) index from 0033 would be violated).
update kount_carried_items c
set master_item_id = act.id
from master_items arch
join master_items act
  on act.is_active = true
 and lower(act.name) = lower(arch.name)
where c.master_item_id = arch.id
  and arch.is_active = false
  and not exists (
    select 1 from kount_carried_items c2
    where c2.master_item_id = act.id
  );

-- 2. Prune every remaining carried row that still points at an archived
--    master: those with no active twin, and the collision cases the guard in
--    step 1 deliberately skipped (active twin already carried).
delete from kount_carried_items c
using master_items mi
where c.master_item_id = mi.id
  and mi.is_active = false;

commit;

-- Verification (run after commit): must return 0.
select count(*) as carried_pointing_at_inactive
from kount_carried_items c
join master_items mi on mi.id = c.master_item_id
where mi.is_active = false;
