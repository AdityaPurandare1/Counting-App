-- =============================================================================
--  0124_jonah_little_luck_counter   (DATA, access)
--
--  2026-11-02, at Aditya's request: jonah@initiatecare.com (Initiate Care)
--  as a counter at Little Luck (v11). Login created first through the Auth
--  admin API with a temporary password (email confirmed, apps=['kount'], no
--  email sent), then this app_users row and an audit-log entry.
--  ROLLBACK: delete from app_users where email = 'jonah@initiatecare.com';
--            (remove the login in the admin's Users screen if it should go)
-- =============================================================================
begin;

insert into public.app_users (email, name, role, venue_ids, is_active, job_title)
values ('jonah@initiatecare.com', 'Jonah (Initiate Care)', 'counter', array['v11'], true, 'Counter, Little Luck')
on conflict (email) do update
   set role = excluded.role, venue_ids = excluded.venue_ids, is_active = true,
       job_title = excluded.job_title, updated_at = now();

insert into public.kount_admin_audit_log (actor_email, action, target_email, ok, details)
values ('apurandare@hwoodgroup.com', 'invite', 'jonah@initiatecare.com', true,
        '{"role":"counter","venue_ids":["v11"],"via":"0124 login + temp password, no email (Claude, on request)"}');

do $$ begin
  if not exists (select 1 from public.app_users a join auth.users u on lower(u.email) = a.email
                  where a.email = 'jonah@initiatecare.com' and a.is_active and a.role = 'counter'
                    and a.venue_ids = array['v11'] and u.email_confirmed_at is not null) then
    raise exception '0124: Jonah is not ready to sign in at Little Luck';
  end if;
end $$;

select email, name, role, venue_ids from public.app_users where email = 'jonah@initiatecare.com';
commit;
