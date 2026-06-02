-- =============================================================================
--  smoke_compute_avt.sql
--
--  Smoke test for compute_avt_for_audit(p_audit_id uuid) added by
--  migration 0030_kount_avt_computed.sql.
--
--  Strategy:
--    - Pin the historic audit (Poppy / v5, count2_closed_at=2026-05-04).
--    - Pick the most-recent uploaded AVT report covering v5 as the
--      comparison baseline.
--    - Run the RPC, compare actual / start_qty / purchases / depletions /
--      theo side-by-side on item_name (lower+trim), and clean up the
--      computed report at the end so the variance UI is undisturbed.
--
--  psql meta-commands (\set, \gset) don't traverse the Supabase
--  Management API path used by `supabase db query --file`, so this file
--  pins the audit id directly and uses a TEMP TABLE to thread the
--  newly-created computed report id between statements within one
--  session.
--
--  Run:
--    cd c:\Github Projects\Counting-App
--    supabase db query --linked --file supabase/tests/smoke_compute_avt.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Audit + uploaded baseline selection
-- -----------------------------------------------------------------------------
-- We thread state between statements via a TEMP TABLE because the
-- Supabase --file path doesn't honor psql \set / \gset.
drop table if exists _smoke_avt_ctx;
create temp table _smoke_avt_ctx (
  audit_id            uuid,
  uploaded_report_id  uuid,
  computed_report_id  uuid
);

insert into _smoke_avt_ctx (audit_id, uploaded_report_id)
select
  '72249a5d-9626-4414-bdcf-52522a894fbe'::uuid,
  (select id
     from public.kount_avt_reports
    where source = 'uploaded'
      and venue_ids @> array['v5']
    order by uploaded_at desc
    limit 1);

-- Confirm what we're testing against.
select
  audit_id,
  uploaded_report_id,
  (select uploaded_at from public.kount_avt_reports r where r.id = c.uploaded_report_id) as uploaded_at,
  (select row_count   from public.kount_avt_reports r where r.id = c.uploaded_report_id) as uploaded_row_count
  from _smoke_avt_ctx c;

-- -----------------------------------------------------------------------------
-- 1. Run the RPC
-- -----------------------------------------------------------------------------
update _smoke_avt_ctx
   set computed_report_id = public.compute_avt_for_audit(audit_id);

select
  computed_report_id,
  (select row_count from public.kount_avt_reports r where r.id = c.computed_report_id) as computed_row_count,
  (select notes     from public.kount_avt_reports r where r.id = c.computed_report_id) as computed_notes
  from _smoke_avt_ctx c;

-- -----------------------------------------------------------------------------
-- 2. Side-by-side comparison: top 20 rows by abs(theo delta)
-- -----------------------------------------------------------------------------
select
  u.item_name,
  u.actual      as up_actual,    c.actual      as cm_actual,
  u.start_qty   as up_start,     c.start_qty   as cm_start,
  u.purchases   as up_purchases, c.purchases   as cm_purchases,
  u.depletions  as up_depletions, c.depletions as cm_depletions,
  u.theo        as up_theo,      c.theo        as cm_theo,
  round((c.actual - u.actual)::numeric, 4) as actual_delta,
  round((c.theo   - u.theo)::numeric, 4)   as theo_delta
from public.kount_avt_rows u
left join public.kount_avt_rows c
  on c.report_id = (select computed_report_id from _smoke_avt_ctx)
 and lower(trim(c.item_name)) = lower(trim(u.item_name))
where u.report_id = (select uploaded_report_id from _smoke_avt_ctx)
order by abs(coalesce(c.theo, 0) - coalesce(u.theo, 0)) desc nulls last
limit 20;

-- -----------------------------------------------------------------------------
-- 3. Coverage check
-- -----------------------------------------------------------------------------
-- rows in upload that DID get a computed match
select count(*) as matched
  from public.kount_avt_rows u
  join public.kount_avt_rows c
    on c.report_id = (select computed_report_id from _smoke_avt_ctx)
   and lower(trim(c.item_name)) = lower(trim(u.item_name))
 where u.report_id = (select uploaded_report_id from _smoke_avt_ctx);

-- rows in upload that did NOT get matched
select count(*) as upload_unmatched
  from public.kount_avt_rows u
  left join public.kount_avt_rows c
    on c.report_id = (select computed_report_id from _smoke_avt_ctx)
   and lower(trim(c.item_name)) = lower(trim(u.item_name))
 where u.report_id = (select uploaded_report_id from _smoke_avt_ctx)
   and c.report_id is null;

-- rows in computed that did NOT exist in upload
select count(*) as computed_only
  from public.kount_avt_rows c
  left join public.kount_avt_rows u
    on u.report_id = (select uploaded_report_id from _smoke_avt_ctx)
   and lower(trim(u.item_name)) = lower(trim(c.item_name))
 where c.report_id = (select computed_report_id from _smoke_avt_ctx)
   and u.report_id is null;

-- -----------------------------------------------------------------------------
-- 4. Depletion provenance
-- -----------------------------------------------------------------------------
select
  count(*) filter (where depletions is not null and depletions <> 0) as with_depletions,
  count(*) filter (where depletions is null or depletions = 0)       as without_depletions,
  count(*) as total
  from public.kount_avt_rows
 where report_id = (select computed_report_id from _smoke_avt_ctx);

-- -----------------------------------------------------------------------------
-- 5. Cleanup
-- -----------------------------------------------------------------------------
delete from public.kount_avt_rows
 where report_id = (select computed_report_id from _smoke_avt_ctx);

delete from public.kount_avt_reports
 where id = (select computed_report_id from _smoke_avt_ctx);

-- Verify cleanup
select
  (select count(*) from public.kount_avt_reports where id = (select computed_report_id from _smoke_avt_ctx)) as report_rows_after_cleanup,
  (select count(*) from public.kount_avt_rows    where report_id = (select computed_report_id from _smoke_avt_ctx)) as row_rows_after_cleanup;

drop table if exists _smoke_avt_ctx;
