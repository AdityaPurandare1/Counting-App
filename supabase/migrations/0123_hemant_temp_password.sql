-- =============================================================================
--  0123_hemant_temp_password   (DATA, audit log only)
--
--  2026-10-31, at Aditya's request: Hemant Makwana (counter, Lady Delilah)
--  given a new temporary password through the Auth admin API, no email. His
--  own password from 10/29 no longer works. Records the action in the admin
--  audit log; nothing else changes.
-- =============================================================================
begin;

insert into public.kount_admin_audit_log (actor_email, action, target_email, ok, details)
values ('apurandare@hwoodgroup.com', 'reset_password', 'hmakwana23.hm@gmail.com', true,
        '{"via":"0123 new temp password, no email (Claude, on request)"}');

select actor_email, action, target_email, ok from public.kount_admin_audit_log
 where target_email = 'hmakwana23.hm@gmail.com' order by occurred_at desc limit 1;
commit;
