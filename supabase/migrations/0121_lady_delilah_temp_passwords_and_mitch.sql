-- =============================================================================
--  0121_lady_delilah_temp_passwords_and_mitch   (DATA, access)
--
--  2026-10-29, at Aditya's request: no invite emails, temporary passwords
--  instead (set through the Auth admin API, email marked confirmed, so the
--  phone's email + password sign-in works right away):
--    * Guerwindy Duma  (counter, v14) -- had an unaccepted invite; temp password set
--    * William Castillo (counter, v14) -- login created with a temp password
--      (his 0120 invite never went out: rate limit, retries stopped)
--    * Mitch Cynamon, Initiate Care -- NEW manager at Lady Delilah (v14),
--      login created with a temp password
--  Hemant Makwana accepted his 0120 invite and set his own password; untouched.
--  ROLLBACK: delete from app_users where email = 'mitch@initiatecare.com';
--            (remove logins in the admin's Users screen if they should go)
-- =============================================================================
begin;

insert into public.app_users (email, name, role, venue_ids, is_active, job_title)
values ('mitch@initiatecare.com', 'Mitch Cynamon', 'manager', array['v14'], true, 'Initiate Care, Lady Delilah')
on conflict (email) do update
   set name = excluded.name, role = excluded.role, venue_ids = excluded.venue_ids,
       is_active = true, job_title = excluded.job_title, updated_at = now();

insert into public.kount_admin_audit_log (actor_email, action, target_email, ok, details)
values ('apurandare@hwoodgroup.com', 'reset_password', 'dumaguerwindyfery@gmail.com', true, '{"via":"0121 temp password (Claude, on request)","email_confirmed":true}'),
       ('apurandare@hwoodgroup.com', 'invite', 'william@initiatecare.com', true, '{"role":"counter","venue_ids":["v14"],"via":"0121 login + temp password, no email (Claude, on request)"}'),
       ('apurandare@hwoodgroup.com', 'invite', 'mitch@initiatecare.com', true, '{"role":"manager","venue_ids":["v14"],"via":"0121 login + temp password, no email (Claude, on request)"}');

do $$ begin
  if (select count(*)
        from public.app_users a
        join auth.users u on lower(u.email) = a.email
       where a.email in ('dumaguerwindyfery@gmail.com', 'william@initiatecare.com', 'mitch@initiatecare.com', 'hmakwana23.hm@gmail.com')
         and a.is_active and 'v14' = any(a.venue_ids)
         and u.email_confirmed_at is not null and u.encrypted_password is not null and u.encrypted_password <> '') <> 4 then
    raise exception '0121: expected 4 Lady Delilah logins ready for password sign-in';
  end if;
end $$;

select a.email, a.name, a.role, a.venue_ids, (u.email_confirmed_at is not null) as can_sign_in
  from public.app_users a join auth.users u on lower(u.email) = a.email
 where 'v14' = any(a.venue_ids) order by a.role, a.email;
commit;
