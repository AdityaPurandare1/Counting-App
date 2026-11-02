-- =============================================================================
--  0122_pati_lady_delilah   (DATA, access)
--
--  Opening day 2026-10-31: Pati (Initiate Care, manager) could not start the
--  Lady Delilah count because v14 was not in her venue_ids (v1-v6, v11).
--  Adds v14, at Aditya's request. Also logs the temp-password reset for
--  Guerwindy Duma and William Castillo (never signed in; new passwords set
--  through the Auth admin API the same day, no email).
--  ROLLBACK: update app_users set venue_ids = array_remove(venue_ids, 'v14')
--            where email = 'pati@initiatecare.com';
-- =============================================================================
begin;

update public.app_users
   set venue_ids = venue_ids || array['v14'], updated_at = now()
 where email = 'pati@initiatecare.com' and not ('v14' = any(venue_ids));

insert into public.kount_admin_audit_log (actor_email, action, target_email, ok, details)
values ('apurandare@hwoodgroup.com', 'update_profile', 'pati@initiatecare.com', true, '{"updated_fields":["venue_ids"],"added":"v14","via":"0122 (Claude, on request)"}'),
       ('apurandare@hwoodgroup.com', 'reset_password', 'dumaguerwindyfery@gmail.com', true, '{"via":"0122 new temp password, no email (Claude, on request)"}'),
       ('apurandare@hwoodgroup.com', 'reset_password', 'william@initiatecare.com', true, '{"via":"0122 new temp password, no email (Claude, on request)"}');

do $$ begin
  if not exists (select 1 from public.app_users where email = 'pati@initiatecare.com' and is_active and role = 'manager' and 'v14' = any(venue_ids)) then
    raise exception '0122: Pati does not have Lady Delilah';
  end if;
end $$;

select email, role, venue_ids from public.app_users where email = 'pati@initiatecare.com';
commit;
