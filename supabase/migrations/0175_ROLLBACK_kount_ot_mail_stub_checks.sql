-- Rollback for 0175_kount_ot_mail_stub_checks: the hourly stub check job removed. The function's
-- {action:'stub_check'} stays harmless (nothing calls it); last_run.stub_check is dropped by the next morning pull.
begin;
select cron.unschedule('kount-order-mail-stubs');
commit;
