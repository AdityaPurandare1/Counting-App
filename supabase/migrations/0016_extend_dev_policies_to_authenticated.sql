-- =============================================================================
--  kΩunt / HWOOD — Phase 3 enabling migration: extend dev policies to
--  the `authenticated` role so Supabase-Auth-signed-in users can read and
--  write the same things anon-key callers already can.
--
--  Background:
--    Migrations 0001–0013 created `dev_*` RLS policies that grant access
--    `to anon`. That was correct when every client used the anon key.
--    Phase 1 of the auth migration added Supabase Auth on the phone +
--    admin: signed-in users now hit Postgres with role='authenticated',
--    not 'anon'. None of the existing `to anon` policies match that role,
--    so RLS silently returns empty results and the apps appear broken
--    after sign-in (no user lookup, no audit reads, no admin CRUD, etc.).
--
--  Each table's policies are wrapped in a DO block that first checks the
--  table exists. This makes the migration safe to run on a project that
--  doesn't have every kount_* table applied — missing tables are skipped
--  with a NOTICE instead of failing the whole script. Same for the RPC
--  GRANTs at the bottom.
-- =============================================================================

-- Helper to keep the per-table blocks readable. Skipped tables log a
-- NOTICE so the operator knows which weren't touched.
create or replace function pg_temp.add_auth_dev_policies(p_table text, p_ops text[])
returns void
language plpgsql
as $$
declare
  op text;
  policy_name text;
  qual text;
begin
  if not exists (select 1 from pg_tables where schemaname='public' and tablename=p_table) then
    raise notice 'skipping % — table not present on this project', p_table;
    return;
  end if;
  foreach op in array p_ops loop
    policy_name := 'auth_dev_' || p_table || '_' || op;
    execute format('drop policy if exists %I on public.%I', policy_name, p_table);
    if op = 'select' then
      qual := 'using (true)';
    elsif op = 'insert' then
      qual := 'with check (true)';
    elsif op = 'update' then
      qual := 'using (true) with check (true)';
    elsif op = 'delete' then
      qual := 'using (true)';
    else
      raise exception 'unknown op: %', op;
    end if;
    execute format(
      'create policy %I on public.%I for %s to authenticated %s',
      policy_name, p_table, op, qual
    );
  end loop;
end;
$$;

-- 0001 tables
select pg_temp.add_auth_dev_policies('kount_audits',         array['select','insert','update','delete']);
select pg_temp.add_auth_dev_policies('kount_members',        array['select','insert','update','delete']);
select pg_temp.add_auth_dev_policies('kount_entries',        array['select','insert','update','delete']);
select pg_temp.add_auth_dev_policies('kount_recounts',       array['select','insert','update','delete']);

-- 0002 tables
select pg_temp.add_auth_dev_policies('kount_avt_reports',    array['select','insert','delete']);
select pg_temp.add_auth_dev_policies('kount_avt_rows',       array['select','insert']);

-- 0003 tables (most critical — login profile lookup goes here)
select pg_temp.add_auth_dev_policies('app_users',            array['select','insert','update','delete']);

-- 0007 tables
select pg_temp.add_auth_dev_policies('kount_carried_items',  array['select','insert','delete']);

-- 0008 tables
select pg_temp.add_auth_dev_policies('kount_venue_zones',    array['select','insert','delete']);

-- 0013 tables
select pg_temp.add_auth_dev_policies('kount_venues',         array['select','insert','update','delete']);


-- RPC grants. Wrapped in a guard so missing functions are skipped with a
-- NOTICE — same robustness story as the policy blocks above.
do $$
declare
  fn text;
  signatures text[] := array[
    'public.approve_upc_mapping(uuid, text, text)',
    'public.reject_upc_mapping(uuid, text, text, text)',
    'public.approve_pending_item(uuid, text, text)',
    'public.reject_pending_item(uuid, text, text, text)',
    'public.approve_pending_item(uuid, text, text, uuid)'
  ];
begin
  foreach fn in array signatures loop
    begin
      execute format('grant execute on function %s to authenticated', fn);
    exception
      when undefined_function then
        raise notice 'skipping grant — function not present: %', fn;
    end;
  end loop;
end $$;

-- Verify (run separately after this script):
-- select count(*) as auth_dev_policy_count from pg_policies where policyname like 'auth_dev_%';
