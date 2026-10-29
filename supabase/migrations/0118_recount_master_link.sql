-- =============================================================================
--  0118_recount_master_link   (FUNCTION + TRIGGER + DATA)
--
--  Recount corrections never reached the final variance. compute_avt_for_audit
--  only applies kount_recounts rows that carry master_item_id, but the phone
--  (<= v2.24) builds variance-flagged recount rows with masterId: null, so a
--  "Count Corrected" result was dropped on the normal close path. On
--  2026-10-28: 206 recounted rows, 16 linked; 22 real corrections across 11
--  submitted audits (Poppy, Little Luck, Delilah LA) never applied.
--
--  1. kount_recount_fill_master: BEFORE INSERT/UPDATE trigger that fills a
--     missing master_item_id, so phones still on an old build are covered
--     (phone v2.25 sends the id itself).
--  2. Backfills existing rows with the same resolver. Filled ids are kept in
--     _mig0118_recount_backfill for the rollback.
--
--  Resolver (first rule that gives exactly one id): the audit's own entries
--  with the same item name; else the one master with that exact name; else the
--  one ACTIVE master with that name. Otherwise null (known: two inactive
--  'BIB - Cranberry 2.5gal' twins at Poppy).
--
--  Recomputes nothing. Past reports pick the corrections up only when they are
--  recomputed, which is a separate, deliberate step.
--  ROLLBACK: 0118_ROLLBACK_recount_master_link.sql
-- =============================================================================
begin;

create or replace function public.kount_resolve_recount_master(p_audit_id uuid, p_item_name text)
returns uuid
language sql stable security definer set search_path = public
as $$
  with by_entry as (
    select distinct e.master_item_id as id
      from public.kount_entries e
     where e.audit_id = p_audit_id
       and e.master_item_id is not null
       and lower(btrim(e.item_name)) = lower(btrim(p_item_name))
  ), by_name as (
    select mi.id, mi.is_active
      from public.master_items mi
     where lower(btrim(mi.name)) = lower(btrim(p_item_name))
  )
  select case
    when (select count(*) from by_entry) = 1 then (select id from by_entry)
    when (select count(*) from by_entry) > 1 then null
    when (select count(*) from by_name) = 1 then (select id from by_name)
    when (select count(*) from by_name where is_active) = 1 then (select id from by_name where is_active)
    else null
  end;
$$;

create or replace function public.kount_recount_fill_master()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.master_item_id is null and nullif(btrim(new.item_name), '') is not null then
    new.master_item_id := public.kount_resolve_recount_master(new.audit_id, new.item_name);
  end if;
  return new;
end;
$$;

-- Internal helpers: nobody calls them over the API. The trigger runs them as
-- their owner, so revoking EXECUTE doesn't stop it firing.
revoke execute on function public.kount_resolve_recount_master(uuid, text) from public, anon, authenticated;
revoke execute on function public.kount_recount_fill_master() from public, anon, authenticated;

drop trigger if exists kount_recount_fill_master on public.kount_recounts;
create trigger kount_recount_fill_master
  before insert or update of master_item_id, item_name on public.kount_recounts
  for each row execute function public.kount_recount_fill_master();

create table if not exists public._mig0118_recount_backfill (
  id             uuid        primary key,
  master_item_id uuid        not null,
  filled_at      timestamptz not null default now()
);
alter table public._mig0118_recount_backfill enable row level security;
revoke all on public._mig0118_recount_backfill from anon, authenticated;

with fill as (
  select r.id, public.kount_resolve_recount_master(r.audit_id, r.item_name) as mid
    from public.kount_recounts r
   where r.master_item_id is null
     and nullif(btrim(r.item_name), '') is not null
), upd as (
  update public.kount_recounts r
     set master_item_id = f.mid
    from fill f
   where f.id = r.id
     and f.mid is not null
  returning r.id, r.master_item_id
)
insert into public._mig0118_recount_backfill (id, master_item_id)
select id, master_item_id from upd;

-- Check: rows filled, and recount corrections now linked vs still unlinked.
select (select count(*) from public._mig0118_recount_backfill) as rows_filled,
       count(*) filter (where count2_qty is not null and count2_qty is distinct from count1_qty
                          and master_item_id is not null) as corrections_linked,
       count(*) filter (where count2_qty is not null and count2_qty is distinct from count1_qty
                          and master_item_id is null) as corrections_unlinked
  from public.kount_recounts;

commit;
