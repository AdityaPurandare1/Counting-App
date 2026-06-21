-- =============================================================================
--  0042_recounts_replica_identity_full
--
--  kount_recounts realtime (the audit channel subscribes with filter
--  audit_id=eq.<id>) was dropping UPDATE/DELETE events: the table had
--  REPLICA IDENTITY default (PK only), so the WAL old-row carried only `id`,
--  not `audit_id` — Supabase Realtime couldn't evaluate the audit_id filter on
--  UPDATE/DELETE and dropped those events. So Count-2 recount edits/removals
--  did not propagate to other counters' devices. FULL replicates all columns
--  so the filter matches. (kount_entries/kount_members are already FULL;
--  kount_audits filters on id=PK so default is fine there.)
--
--  Apply: supabase db query --linked --file supabase/migrations/0042_recounts_replica_identity_full.sql
--  Idempotent.
-- =============================================================================
alter table public.kount_recounts replica identity full;

-- verify
select c.relname,
  case c.relreplident when 'f' then 'FULL' else c.relreplident::text end as replica_identity
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='kount_recounts';
