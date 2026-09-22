-- 0054_barcode_tables_corporate_delete.sql
--
-- Problem: three RLS policies on the two barcode tables were `using (true)`
-- for {authenticated}:
--     master_item_upcs.auth_master_item_upcs_delete   DELETE
--     master_item_upcs.auth_master_item_upcs_update   UPDATE
--     upc_mappings.auth_update_upc_mapping_stats      UPDATE
-- so ANY signed-in user — a counter at any venue — could delete or rewrite
-- ANY barcode link across all 21k master_items. Not venue-scoped, not role-
-- gated. This is the follow-on deferred when 0048 locked app_users.
--
-- Decision (2026-09-22): only corporate may delete or rewrite a barcode link.
--
-- Every client write site was mapped before changing anything, so nothing
-- the floor depends on breaks:
--   phone  counting-app.html  — INSERT-only on master_item_upcs (4409, 5393,
--          7217) and upc_mappings (4349, 5370, 5477, 11459). Its single
--          UPDATE (4432) demotes ITS OWN just-inserted upc_mappings row to
--          'pending' on a 23505 conflict -> covered by the own-row clause.
--   admin  Approvals.tsx:210 DELETE (force-approve reassign) — the Force
--          button is already `user.role === 'corporate'` in the UI (:299).
--          Approvals.tsx:226 UPDATE upc_mappings — same corporate-only path.
--          Counts.tsx:604 DELETE (linkUpc reassign) — reachable by managers,
--          but the code already aborts safely on a failed delete:
--          alert("Could not unlink UPC ... Nothing was changed."). So a
--          manager can still LINK a barcode to a blank bottle (INSERT) and
--          a reassign fails loudly instead of half-completing. Intended.
--   nobody UPDATEs master_item_upcs anywhere -> corporate-only costs nothing.
--   nothing bumps scan_count/last_scanned_at despite the old policy's name.
--
-- INSERT and SELECT policies are deliberately untouched: linking a barcode
-- to a bottle in hand is how the Alphabet/Little Luck gaps get closed.
--
-- Gate expression is the same app_users-via-JWT check 0052/0053 use.
-- Idempotent: drop-if-exists + create.

begin;

-- ---- master_item_upcs: DELETE / UPDATE -> corporate only ------------------
drop policy if exists auth_master_item_upcs_delete on public.master_item_upcs;
create policy auth_master_item_upcs_delete
  on public.master_item_upcs
  for delete
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and u.role = 'corporate'
    )
  );

drop policy if exists auth_master_item_upcs_update on public.master_item_upcs;
create policy auth_master_item_upcs_update
  on public.master_item_upcs
  for update
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and u.role = 'corporate'
    )
  )
  with check (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and u.role = 'corporate'
    )
  );

-- ---- upc_mappings: UPDATE -> corporate, or the submitter's own row --------
-- Own-row keeps the phone's conflict-demote (its only UPDATE) working for
-- counters; corporate covers the admin force-approve path.
drop policy if exists auth_update_upc_mapping_stats on public.upc_mappings;
create policy auth_update_upc_mapping_stats
  on public.upc_mappings
  for update
  to authenticated
  using (
    lower(submitted_by_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and u.role = 'corporate'
    )
  )
  with check (
    lower(submitted_by_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.is_active = true
         and u.role = 'corporate'
    )
  );

commit;

-- ---- verification (run separately; all writes rolled back) ---------------
-- As a COUNTER (createdbyanna@gmail.com): DELETE real master_item_upcs row
--   -> 0 rows; UPDATE -> 0 rows; INSERT -> succeeds; UPDATE own upc_mappings
--   row -> 1; UPDATE someone else's -> 0.
-- As a MANAGER (dmalouf@hwoodgroup.com): DELETE -> 0; UPDATE -> 0;
--   INSERT -> succeeds.
-- As CORPORATE (apurandare@hwoodgroup.com): DELETE -> 1; UPDATE -> 1.
