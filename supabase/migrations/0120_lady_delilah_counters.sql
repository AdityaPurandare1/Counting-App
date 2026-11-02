-- =============================================================================
--  0120_lady_delilah_counters   (DATA, access)
--
--  Counter access at Lady Delilah (v14) for its opening count (10/31), asked
--  for by Aditya on 2026-10-29. Done the way admin-user-mgmt's "invite" does
--  it: Supabase invite email (user_metadata.apps = ['kount'], link to the
--  phone app) sent first via the Auth admin API, then this app_users row and
--  a kount_admin_audit_log entry.
--    * Hemant Makwana    hmakwana23.hm@gmail.com      invited 10/29
--    * Guerwindy Duma    dumaguerwindyfery@gmail.com  invited 10/29
--    * William Castillo  william@initiatecare.com     invite hit the email
--      rate limit (429); his row is provisioned now and the invite is resent
--      separately (the function's invite path upserts on email, so the two
--      meet either way).
--  ROLLBACK: delete from app_users where email in ('hmakwana23.hm@gmail.com',
--            'dumaguerwindyfery@gmail.com', 'william@initiatecare.com');
--            (and remove the auth users in the admin if they should go too)
-- =============================================================================
begin;

insert into public.app_users (email, name, role, venue_ids, is_active, job_title)
values ('hmakwana23.hm@gmail.com',     'Hemant Makwana',   'counter', array['v14'], true, 'Counter, Lady Delilah'),
       ('dumaguerwindyfery@gmail.com', 'Guerwindy Duma',   'counter', array['v14'], true, 'Counter, Lady Delilah'),
       ('william@initiatecare.com',    'William Castillo', 'counter', array['v14'], true, 'Counter, Lady Delilah')
on conflict (email) do update
   set name = excluded.name, role = excluded.role, venue_ids = excluded.venue_ids,
       is_active = true, job_title = excluded.job_title, updated_at = now();

insert into public.kount_admin_audit_log (actor_email, action, target_email, ok, details)
values ('apurandare@hwoodgroup.com', 'invite', 'hmakwana23.hm@gmail.com',     true, '{"role":"counter","venue_ids":["v14"],"via":"0120 (Claude, on request)"}'),
       ('apurandare@hwoodgroup.com', 'invite', 'dumaguerwindyfery@gmail.com', true, '{"role":"counter","venue_ids":["v14"],"via":"0120 (Claude, on request)"}'),
       ('apurandare@hwoodgroup.com', 'invite', 'william@initiatecare.com',    false, '{"role":"counter","venue_ids":["v14"],"via":"0120 (Claude, on request)","note":"invite email rate-limited (429); access row provisioned, invite to resend"}');

do $$ begin
  if (select count(*) from public.app_users
       where email in ('hmakwana23.hm@gmail.com', 'dumaguerwindyfery@gmail.com', 'william@initiatecare.com')
         and role = 'counter' and is_active and venue_ids = array['v14']) <> 3 then
    raise exception '0120: expected 3 Lady Delilah counters';
  end if;
end $$;

select email, name, role, venue_ids, is_active from public.app_users where 'v14' = any(venue_ids) order by role, email;
commit;
