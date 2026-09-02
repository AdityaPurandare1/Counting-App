-- 0050_entry_delete_log.sql
--
-- Problem: `_guard_block_active_entry_delete` (an ad-hoc emergency guard, never
-- captured as a migration) is a BEFORE DELETE trigger on kount_entries that
-- `return null`s -- i.e. SILENTLY CANCELS -- every delete whose audit is still
-- 'active'. It was the stop-gap for the v1.81 cross-zone move-cleanup data-loss
-- bug. That root cause was removed in v1.81 and the fleet is on v1.97, but the
-- guard was never dropped, so it now breaks the two legitimate delete paths:
--
--   1. moveEntryToZone MERGE path -- when the target zone already holds the
--      item, the phone adds the qty onto the target row and deletes the source
--      row. The delete is cancelled, so the source row survives server-side.
--      12s later reconcileAuditEntries() re-pulls it and re-inserts it locally:
--      the counter sees "the whole list re-shows up", and the moved qty is
--      DOUBLE-COUNTED (added to the target, still full at the source).
--      Reported by Anna @ Poppy, 2026-08-10, on live audit ba157c95.
--
--   2. adjustQuantity qty->0 ("Remove from count") -- same silent cancel, so a
--      removed item reappears on the next reconcile tick.
--
-- Neither surfaces an error: PostgREST reports a cancelled delete as
-- {data: [], error: null} -- success with 0 rows affected. The client's
-- onZeroRows recovery re-tries by client_entry_id, gets cancelled again, and
-- gives up quietly.
--
-- Fix: stop blocking, start recording. Deletes are allowed through again, and
-- every deleted row is snapshotted into kount_entries_deleted_log first. That
-- keeps the recoverability the guard was installed for (a future mass-delete
-- bug is fully reconstructible) without breaking correct writes.
--
-- The log trigger is SECURITY DEFINER so the anon/authenticated roles the phone
-- uses can insert into the log even though they hold no grants on it.
--
-- Idempotent: create-table-if-not-exists, create-or-replace function,
-- drop-if-exists triggers.

begin;

-- ---- 1. the recovery log -------------------------------------------------
-- Column-for-column snapshot of kount_entries (as of 0050) plus who/when.
-- Deliberately NOT a foreign key to kount_audits: the log must survive an
-- audit being hard-deleted, which is exactly when it is most valuable.
create table if not exists public.kount_entries_deleted_log (
  log_id            bigserial primary key,
  deleted_at        timestamptz not null default now(),
  deleted_by        text,
  id                uuid,
  audit_id          uuid,
  item_id           uuid,
  item_name         text,
  category          text,
  qty               numeric,
  zone              text,
  method            text,
  issue             text,
  issue_notes       text,
  sku               text,
  upc               text,
  counted_by_email  text,
  counted_by_name   text,
  is_recount        boolean,
  photo_id          text,
  "timestamp"       timestamptz,
  issue_resolved    boolean,
  issue_resolved_by text,
  issue_resolved_at timestamptz,
  master_item_id    uuid,
  client_entry_id   text
);

create index if not exists kount_entries_deleted_log_audit_idx
  on public.kount_entries_deleted_log (audit_id, deleted_at desc);
create index if not exists kount_entries_deleted_log_deleted_at_idx
  on public.kount_entries_deleted_log (deleted_at desc);

-- Corporate-only reads; nobody writes directly (the trigger is SECURITY
-- DEFINER and bypasses this).
alter table public.kount_entries_deleted_log enable row level security;

drop policy if exists kount_entries_deleted_log_select_corporate
  on public.kount_entries_deleted_log;
create policy kount_entries_deleted_log_select_corporate
  on public.kount_entries_deleted_log
  for select
  using (
    exists (
      select 1 from public.app_users u
      where u.email = (auth.jwt() ->> 'email')
        and u.role  = 'corporate'
    )
  );

revoke all on public.kount_entries_deleted_log from anon, authenticated;
grant select on public.kount_entries_deleted_log to anon, authenticated;

-- ---- 2. replace the blocking guard with a logging one --------------------
create or replace function public.log_kount_entry_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.kount_entries_deleted_log (
    deleted_by, id, audit_id, item_id, item_name, category, qty, zone, method,
    issue, issue_notes, sku, upc, counted_by_email, counted_by_name,
    is_recount, photo_id, "timestamp", issue_resolved, issue_resolved_by,
    issue_resolved_at, master_item_id, client_entry_id
  ) values (
    coalesce(auth.jwt() ->> 'email', current_user),
    old.id, old.audit_id, old.item_id, old.item_name, old.category, old.qty,
    old.zone, old.method, old.issue, old.issue_notes, old.sku, old.upc,
    old.counted_by_email, old.counted_by_name, old.is_recount, old.photo_id,
    old."timestamp", old.issue_resolved, old.issue_resolved_by,
    old.issue_resolved_at, old.master_item_id, old.client_entry_id
  );
  return old;   -- allow the delete
end;
$$;

-- Drop the blocker FIRST so there is no window where a delete is both logged
-- and cancelled (which would leave phantom log rows for rows that survived).
drop trigger if exists _guard_block_active_entry_delete on public.kount_entries;
drop function if exists public._guard_block_active_entry_delete();

drop trigger if exists _log_kount_entry_delete on public.kount_entries;
create trigger _log_kount_entry_delete
  before delete on public.kount_entries
  for each row
  execute function public.log_kount_entry_delete();

commit;

-- ---- verification (run separately, read-only) ----
-- Expect: exactly one non-internal delete trigger, named _log_kount_entry_delete;
-- the guard function gone; the log table present and empty.
--
-- select t.tgname, pg_get_triggerdef(t.oid)
--   from pg_trigger t join pg_class c on c.oid = t.tgrelid
--   where c.relname = 'kount_entries' and not t.tgisinternal;
--
-- select count(*) as guard_fn_remaining from pg_proc
--   where proname = '_guard_block_active_entry_delete';   -- expect 0
--
-- select count(*) from public.kount_entries_deleted_log;  -- expect 0 at apply
--
-- Round-trip check (safe -- inserts then deletes a throwaway row on the live
-- active audit, then cleans the log entry it produced):
-- begin;
--   insert into kount_entries (audit_id, item_name, qty, zone, counted_by_email)
--     values ('ba157c95-779b-4ec7-b48e-87398495b17f', '__delete_guard_probe__', 0, '__probe__', 'apurandare@hwoodgroup.com');
--   delete from kount_entries where item_name = '__delete_guard_probe__';
--   select count(*) as should_be_zero from kount_entries where item_name = '__delete_guard_probe__';
--   select count(*) as should_be_one  from kount_entries_deleted_log where item_name = '__delete_guard_probe__';
-- rollback;
