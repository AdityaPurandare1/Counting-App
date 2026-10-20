-- 0092_ROLLBACK_kount_reopen_audit_rpc: drops the function. Audits it already reopened stay reopened.
begin;
drop function if exists public.kount_reopen_audit(uuid);
commit;
