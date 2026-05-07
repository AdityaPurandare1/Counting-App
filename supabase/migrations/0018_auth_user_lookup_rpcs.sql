-- =============================================================================
--  0018_auth_user_lookup_rpcs
--
--  The admin-user-mgmt Edge Function previously used Supabase's
--  admin.auth.admin.listUsers() to find users by email and to enumerate
--  all auth users for the bulk-migration tool. Two problems:
--    1. listUsers paginates through every auth.users row — O(n) per lookup,
--       and on multi-app projects with hundreds of users it occasionally
--       returns "Database error finding users" (Supabase Auth API quirk).
--    2. The 10-page × 200-per-page cap means lookups silently fail past
--       2000 users.
--
--  These two RPCs replace listUsers with direct, indexed Postgres queries.
--  Only the service_role can execute them — anon and authenticated roles
--  must NEVER be able to enumerate auth.users from the client.
-- =============================================================================

-- Single-user lookup by email. Used by handleInvite (link-existing path),
-- handleDisable, handleEnable, handleDelete.
create or replace function public.find_auth_user_by_email(p_email text)
returns table(user_id uuid, user_metadata jsonb)
language sql
security definer
set search_path = public, auth
as $$
  select id, raw_user_meta_data
    from auth.users
   where lower(email) = lower(p_email)
   limit 1;
$$;

revoke execute on function public.find_auth_user_by_email(text) from public;
revoke execute on function public.find_auth_user_by_email(text) from anon;
revoke execute on function public.find_auth_user_by_email(text) from authenticated;
grant  execute on function public.find_auth_user_by_email(text) to service_role;


-- Bulk email enumeration. Used by handleMigrateLegacy to compute the diff
-- between app_users and auth.users. Returns lowered emails only — no IDs,
-- no metadata — to keep the surface area minimal even from service_role.
create or replace function public.list_auth_user_emails()
returns table(email text)
language sql
security definer
set search_path = public, auth
as $$
  select lower(email)
    from auth.users
   where email is not null;
$$;

revoke execute on function public.list_auth_user_emails() from public;
revoke execute on function public.list_auth_user_emails() from anon;
revoke execute on function public.list_auth_user_emails() from authenticated;
grant  execute on function public.list_auth_user_emails() to service_role;


-- Sanity verification (run separately):
-- select user_id, user_metadata
--   from public.find_auth_user_by_email('apurandare@hwoodgroup.com');
-- select count(*) as auth_user_count from public.list_auth_user_emails();
