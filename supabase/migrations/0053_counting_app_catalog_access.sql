-- =============================================================================
--  0053_counting_app_catalog_access.sql
--
--  Third and final part of the 2026-09-01..03 incident (see 0051, 0052).
--
--  PR #166 in shurehw/RESTAURANT-APP scoped 21 permissive tenant tables to
--  `organization_id IN (select user_org_ids())`. That is correct multi-tenant
--  behaviour and is NOT changed here. But it assumes every legitimate reader
--  holds an `organization_users` row, and the counting staff do not:
--
--    pati@initiatecare.com      manager        0 org memberships
--    createdbyanna@gmail.com    counter        0
--    jonathancastorena@yahoo.com counter       0
--    kelly.curtin@live.com      counter        0
--    gm.poppy.test@hwoodgroup.com venue_manager 0
--
--  Measured against production as the `authenticated` role with a real
--  auth.uid claim, Pati could see:
--      master_items          0 of 21,480     <-- empty catalog, nothing to count
--      venues                0 of 35
--      everything else (all kount_*, master_item_upcs, upc_mappings) fine
--
--  That is why the phone showed "Items in inventory" blank: an audit can be
--  started, but there is no catalog behind it.
--
--  WHY NOT JUST ADD THEM TO THE ORG: 391 policies key on organization_users
--  and only 69 of them check the membership `role`, so even a `readonly` or
--  `inventory` membership would grant access through the other 322. Counting
--  staff are deliberately kept EXTERNAL to the tenant; their authorisation
--  comes from the counting app's own `app_users` table instead.
--
--  This is not a new pattern for these tables — `master_items` already
--  carries `master_items_insert_corporate` and `master_items_update_corporate`
--  keyed on app_users + the JWT email. This adds the matching SELECT.
--
--  ADDITIVE ONLY. RLS policies are OR-ed, so the tenant policy is untouched
--  and still governs org members; this simply adds a second, narrower path
--  for the counting app's own users. Scoped to The h.wood Group's rows only,
--  so the other orgs' venues stay invisible. Reversible with DROP POLICY.
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`.
-- =============================================================================

begin;

-- The organization that owns the beverage catalog the counting app reads.
-- All 21,480 master_items and 30 of the 35 venues belong to it; the remaining
-- 5 venues belong to other tenants and stay hidden by omission.
--   13dacb8a-d2b5-42b8-bcc3-50bc372c0a41 = "The h.wood Group"

drop policy if exists master_items_select_counting_app on public.master_items;
create policy master_items_select_counting_app
  on public.master_items
  for select
  to authenticated
  using (
    organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid
    and exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
    )
  );

drop policy if exists venues_select_counting_app on public.venues;
create policy venues_select_counting_app
  on public.venues
  for select
  to authenticated
  using (
    organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid
    and exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
    )
  );

-- Telemetry: kount_client_errors kept its corporate-only SELECT policy but
-- lost its INSERT one, so the phone's logClientError has been failing since
-- the sweep. That is why the 2026-09-06 outage produced no error record at
-- all and had to be diagnosed from a screenshot. INSERT for authenticated
-- only — anon writes are deliberately not restored.
drop policy if exists kount_client_errors_insert on public.kount_client_errors;
create policy kount_client_errors_insert
  on public.kount_client_errors
  for insert
  to authenticated
  with check (true);

commit;

-- ── Verification ────────────────────────────────────────────────────────────
--  As the `authenticated` role with a counting user's real auth.uid claim,
--  master_items should return 21480 and venues 30 (not 35).
--  Org members must be unaffected: they still see the same rows via the
--  tenant policy. A user in NEITHER app_users nor the org must still see 0.
