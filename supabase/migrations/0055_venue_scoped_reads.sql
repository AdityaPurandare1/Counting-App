-- 0055_venue_scoped_reads.sql
--
-- G3: venue scoping was CLIENT-SIDE ONLY. Measured as dmalouf (a manager
-- whose app_users.venue_ids is exactly {v12}), before this migration:
--
--     kount_venues        12 rows      (his scope: 1 venue)
--     app_users           23 rows      every colleague's email + role
--     kount_audits        33 rows      31 of them other venues'
--     kount_entries    6,708 rows      every count line at every venue
--
-- The apps only ever FILTERED the picker; the database answered in full.
-- Not reachable through the UI, but the anon/authenticated key plus any
-- HTTP client walks straight past it.
--
-- Scope of this migration: SELECT only.
--   * It closes the reported exposure (reading other venues' data).
--   * It also substantially mitigates the write side as a side effect:
--     UPDATE/DELETE still carry `using (true)`, but you can no longer
--     ENUMERATE the ids of rows outside your venues, so a blind write
--     needs an id you have no supported way to obtain.
--   * Tightening writes is deliberately NOT bundled here. Counting is the
--     one flow we cannot afford to break mid-shift, and write policies
--     want their own change with its own rollback story.
--
-- RECURSION: the app_users policy cannot itself query app_users — Postgres
-- would recurse forever. Both helpers are SECURITY DEFINER so they read
-- app_users with RLS bypassed. That is also why they must NOT be made
-- SECURITY INVOKER later without re-solving this.
--
-- GRANT: explicit EXECUTE to authenticated. Learned from 0052 — these
-- functions would otherwise ride on the PUBLIC grant, and the next time
-- someone revokes PUBLIC every counting read dies at once.
--
-- Unaffected by design:
--   compute_avt_for_audit + the approve/reject RPCs  — SECURITY DEFINER
--   admin-user-mgmt Edge Function                    — service_role
--   anon                                             — these policies are
--     `to authenticated`; anon already saw 0 rows and still does.

begin;

-- ---- helpers -------------------------------------------------------------
create or replace function public.kount_is_corporate()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and u.role = 'corporate'
  );
$$;

create or replace function public.kount_can_see_venue(p_venue_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active = true
       and (u.role = 'corporate' or p_venue_id = any(coalesce(u.venue_ids, '{}')))
  );
$$;

revoke all on function public.kount_is_corporate()          from public, anon;
revoke all on function public.kount_can_see_venue(text)     from public, anon;
grant execute on function public.kount_is_corporate()       to authenticated;
grant execute on function public.kount_can_see_venue(text)  to authenticated;

-- ---- app_users: your own row, or everything if you are corporate --------
-- Safe for both clients: the phone writes ACCESS_LIST but only ever looks
-- itself up in it (its other two app_users reads are email=eq.<self>), and
-- the admin's Security screen — the one place that needs every row — is
-- already corporate-gated on the route.
drop policy if exists auth_dev_app_users_select on public.app_users;
create policy auth_dev_app_users_select
  on public.app_users
  for select
  to authenticated
  using (
    lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or public.kount_is_corporate()
  );

-- ---- kount_audits: venue-scoped --------------------------------------
drop policy if exists auth_kount_audits_select on public.kount_audits;
create policy auth_kount_audits_select
  on public.kount_audits
  for select
  to authenticated
  using (public.kount_can_see_venue(venue_id));

-- ---- child tables: scoped through their audit --------------------------
-- kount_entries.audit_id, kount_members.audit_id and kount_recounts.audit_id
-- are all indexed (kount_entries_audit_idx, kount_members_audit_idx,
-- kount_recounts_audit_zone_idx), and kount_audits.id is the PK, so these
-- resolve on an index lookup per row rather than a scan.
drop policy if exists auth_dev_kount_entries_select on public.kount_entries;
create policy auth_dev_kount_entries_select
  on public.kount_entries
  for select
  to authenticated
  using (exists (
    select 1 from public.kount_audits a
     where a.id = kount_entries.audit_id
       and public.kount_can_see_venue(a.venue_id)
  ));

drop policy if exists auth_dev_kount_members_select on public.kount_members;
create policy auth_dev_kount_members_select
  on public.kount_members
  for select
  to authenticated
  using (exists (
    select 1 from public.kount_audits a
     where a.id = kount_members.audit_id
       and public.kount_can_see_venue(a.venue_id)
  ));

drop policy if exists auth_dev_kount_recounts_select on public.kount_recounts;
create policy auth_dev_kount_recounts_select
  on public.kount_recounts
  for select
  to authenticated
  using (exists (
    select 1 from public.kount_audits a
     where a.id = kount_recounts.audit_id
       and public.kount_can_see_venue(a.venue_id)
  ));

commit;

-- ---- verification (run separately; all reads, no writes) ---------------
-- As dmalouf (manager, venue_ids = {v12}):
--   app_users      -> 1     (was 23)
--   kount_audits   -> 2     (was 33)  both v12
--   kount_entries  -> 342   (was 6708) all on v12 audits
-- As apurandare (corporate): unchanged counts on every table.
-- As anon: still 0 everywhere.
