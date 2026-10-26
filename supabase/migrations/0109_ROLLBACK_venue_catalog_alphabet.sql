-- 0109_ROLLBACK_venue_catalog_alphabet: Alphabet back to the full catalog, then remove the pieces.
-- (Phones on v2.23 fall back to the full catalog as soon as catalog_mode is not 'invoiced'.)
begin;
update public.kount_venues set catalog_mode = 'all' where catalog_mode = 'invoiced';
select cron.unschedule(jobid) from cron.job where jobname = 'kount-venue-catalog-refresh';
-- Restore the 0089 close-time function by re-running 0089_create_new_products_on_count_close.sql
-- (it no longer references kount_venue_catalog once that file is re-applied), then:
-- drop function if exists public.kount_refresh_venue_catalog(text);
-- drop table if exists public.kount_venue_catalog;
-- alter table public.kount_venues drop constraint if exists kount_venues_catalog_mode_check;
-- alter table public.kount_venues drop column if exists catalog_mode;
commit;
