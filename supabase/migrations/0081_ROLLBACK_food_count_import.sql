-- Rollback for 0081_food_count_import.
--
-- NOTE on data: dropping kount_venue_food_items discards each venue's food
-- list (counting unit + pack size). Food AUDITS and their entries are NOT
-- deleted here — they are real counts. If you also want them gone:
--     delete from public.kount_entries
--      where audit_id in (select id from public.kount_audits where audit_kind = 'food');
--     delete from public.kount_audits where audit_kind = 'food';
-- Do that BEFORE dropping the audit_kind column, and only if you are sure.

begin;

drop function if exists public.kount_import_food_count(text, jsonb, timestamptz, boolean, boolean);

drop table if exists public.kount_venue_food_items;

alter table public.kount_entries
  drop column if exists count_unit,
  drop column if exists units_per_case;

alter table public.kount_audits
  drop constraint if exists kount_audits_audit_kind_chk;

alter table public.kount_audits
  drop column if exists audit_kind;

select 'rolled back 0081' as status;

commit;
