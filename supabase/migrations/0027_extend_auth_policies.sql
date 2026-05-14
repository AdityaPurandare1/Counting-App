-- =============================================================================
--  0027_extend_auth_policies
--
--  Adds `to authenticated` mirror policies for the kount-related tables that
--  were only `to anon` before Path B switched the phone (and admin) to
--  Supabase Auth. After that switch the phone's REST calls carry a real
--  user JWT with role='authenticated' — which doesn't match `to anon`
--  policies, so inserts started failing with 42501 "row violates RLS".
--
--  Symptom that drove this: counter scans a barcode, phone tries to
--  insert into public.upc_mappings, gets HTTP 403 / 42501 even though
--  the user is signed in as corporate. Same potential failure on the
--  newer Path B tables (master_item_upcs, master_item_upcs_review) and
--  on kount_venue_zones.
--
--  Earlier migration 0016 did the equivalent fix for the audit/entries
--  tables; this is the catch-up for the tables that came after.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- upc_mappings  (anon_* policies mirror the same check expressions)
-- -----------------------------------------------------------------------------
drop policy if exists "auth_insert_upc_mappings" on public.upc_mappings;
create policy "auth_insert_upc_mappings"
  on public.upc_mappings for insert to authenticated
  with check (
    submitted_by_email is not null
    and submitted_by_name is not null
    and status in ('pending', 'approved')
  );

drop policy if exists "auth_read_upc_mappings" on public.upc_mappings;
create policy "auth_read_upc_mappings"
  on public.upc_mappings for select to authenticated using (true);

drop policy if exists "auth_update_upc_mapping_stats" on public.upc_mappings;
create policy "auth_update_upc_mapping_stats"
  on public.upc_mappings for update to authenticated using (true) with check (true);

-- -----------------------------------------------------------------------------
-- master_item_upcs  (mirror dev_* anon policies for authenticated)
-- -----------------------------------------------------------------------------
drop policy if exists "auth_master_item_upcs_select" on public.master_item_upcs;
create policy "auth_master_item_upcs_select"
  on public.master_item_upcs for select to authenticated using (true);

drop policy if exists "auth_master_item_upcs_insert" on public.master_item_upcs;
create policy "auth_master_item_upcs_insert"
  on public.master_item_upcs for insert to authenticated with check (true);

drop policy if exists "auth_master_item_upcs_update" on public.master_item_upcs;
create policy "auth_master_item_upcs_update"
  on public.master_item_upcs for update to authenticated using (true) with check (true);

drop policy if exists "auth_master_item_upcs_delete" on public.master_item_upcs;
create policy "auth_master_item_upcs_delete"
  on public.master_item_upcs for delete to authenticated using (true);

-- -----------------------------------------------------------------------------
-- master_item_upcs_review  (mirror dev_* anon policies for authenticated)
-- -----------------------------------------------------------------------------
drop policy if exists "auth_master_item_upcs_review_select" on public.master_item_upcs_review;
create policy "auth_master_item_upcs_review_select"
  on public.master_item_upcs_review for select to authenticated using (true);

drop policy if exists "auth_master_item_upcs_review_insert" on public.master_item_upcs_review;
create policy "auth_master_item_upcs_review_insert"
  on public.master_item_upcs_review for insert to authenticated with check (true);

drop policy if exists "auth_master_item_upcs_review_update" on public.master_item_upcs_review;
create policy "auth_master_item_upcs_review_update"
  on public.master_item_upcs_review for update to authenticated using (true) with check (true);

drop policy if exists "auth_master_item_upcs_review_delete" on public.master_item_upcs_review;
create policy "auth_master_item_upcs_review_delete"
  on public.master_item_upcs_review for delete to authenticated using (true);

-- -----------------------------------------------------------------------------
-- kount_venue_zones  (mirror dev_* anon policies for authenticated)
-- -----------------------------------------------------------------------------
drop policy if exists "auth_kount_venue_zones_select" on public.kount_venue_zones;
create policy "auth_kount_venue_zones_select"
  on public.kount_venue_zones for select to authenticated using (true);

drop policy if exists "auth_kount_venue_zones_insert" on public.kount_venue_zones;
create policy "auth_kount_venue_zones_insert"
  on public.kount_venue_zones for insert to authenticated with check (true);

drop policy if exists "auth_kount_venue_zones_delete" on public.kount_venue_zones;
create policy "auth_kount_venue_zones_delete"
  on public.kount_venue_zones for delete to authenticated using (true);

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------
--   select polname, polroles::regrole[]
--     from pg_policy
--    where polrelid in (
--      'public.upc_mappings'::regclass,
--      'public.master_item_upcs'::regclass,
--      'public.master_item_upcs_review'::regclass,
--      'public.kount_venue_zones'::regclass
--    )
--    order by polrelid::regclass::text, polname;
--
-- Should now show paired anon + authenticated policies on each table.
