-- =============================================================================
--  0028_master_items_admin_only
--
--  Locks down master_items writes to corporate admins.
--
--  Before this migration:
--    - RLS off on master_items
--    - anon + authenticated had full INSERT/UPDATE/DELETE grants
--    - Counts.linkUpc, Approvals.forceApprove, and phone-side admin
--      writes all relied on a client-side role check that the DB didn't
--      enforce. A counter (or anyone with the anon key + curl) could
--      mint master_items rows by hand.
--
--  After this migration:
--    - SELECT remains open (the phone reads the catalog as anon during
--      boot, before login)
--    - INSERT and UPDATE require the JWT's email to resolve to an active
--      corporate admin in app_users
--    - DELETE is denied for everyone except the table owner; soft-delete
--      via `is_active = false` is the supported path
--    - approve_pending_item RPC continues to work because it's
--      SECURITY DEFINER and bypasses RLS by design — the role check
--      already lives inside the RPC's own guards
--
--  The same model can be applied later to master_item_upcs / upc_mappings
--  if you want to lock those down too. For now this migration only touches
--  master_items.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Defense layer 1 — revoke write grants from anon. Even with RLS on, a
-- missing-or-permissive policy could let an anon caller through; pulling
-- the grant stops the request before it reaches RLS.
-- -----------------------------------------------------------------------------
revoke insert, update, delete, truncate on public.master_items from anon;

-- -----------------------------------------------------------------------------
-- Defense layer 2 — enable RLS and gate writes by app_users.role
-- -----------------------------------------------------------------------------
alter table public.master_items enable row level security;

-- SELECT: open to anon + authenticated. Catalog needs to be readable by
-- the phone during boot (before login the request goes out under anon)
-- and by every authenticated user after.
drop policy if exists "master_items_select_all" on public.master_items;
create policy "master_items_select_all"
  on public.master_items for select
  to anon, authenticated
  using (true);

-- INSERT: only when the caller's JWT email resolves to an active
-- corporate admin in app_users.
drop policy if exists "master_items_insert_corporate" on public.master_items;
create policy "master_items_insert_corporate"
  on public.master_items for insert
  to authenticated
  with check (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

-- UPDATE: same constraint, both USING (which rows can be targeted) and
-- WITH CHECK (what the row can become).
drop policy if exists "master_items_update_corporate" on public.master_items;
create policy "master_items_update_corporate"
  on public.master_items for update
  to authenticated
  using (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  )
  with check (
    exists (
      select 1 from public.app_users u
       where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
         and u.role = 'corporate'
         and u.is_active = true
    )
  );

-- DELETE: NO policy defined. With RLS on, the absence of a DELETE policy
-- means DELETE is denied for every non-owner role (anon, authenticated,
-- service_role). Soft-delete via is_active=false is the supported path.

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------
-- 1. Confirm RLS on + policies in place:
--      select c.relname, c.relrowsecurity,
--             (select count(*) from pg_policy where polrelid = c.oid) as n_policies
--        from pg_class c where c.oid = 'public.master_items'::regclass;
--      -- expect: relrowsecurity = true, n_policies = 3
--
-- 2. Confirm anon write grants are gone:
--      select privilege_type from information_schema.role_table_grants
--       where table_name = 'master_items' and grantee = 'anon';
--      -- should only show SELECT
--
-- 3. Try to insert as a non-corporate authenticated user (e.g. a
--    counter or manager via the phone JWT). Should fail with 42501 and
--    "new row violates row-level security policy".
--
-- 4. Confirm the approve_pending_item RPC still mints rows — the RPC is
--    SECURITY DEFINER and bypasses RLS.
