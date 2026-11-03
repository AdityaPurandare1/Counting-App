-- =============================================================================
--  0144_kount_ot_bibles   (each venue's OS&E bible, shown as in Excel)
--
--  The user (2026-11-03): "make a tab ... bibles" — select the venue and its bible
--  is shown "with images and links ... exactly how it looks in the excel sheet".
--  The bible workbooks (Little Luck, Alphabet, The Nice Guy, Delilah LA / Miami /
--  Dallas, Bird Streets; up to 25 MB with pictures in their cells) are stored as
--  files and drawn in the admin from the workbook itself.
--
--    kount_ot_bibles   one row per uploaded bible file; a new upload of a venue's
--                      bible keeps the earlier ones (is_current = false)
--    bucket kount-order-docs  file size limit 20 MB -> 50 MB (Bird Streets' is 25)
--
--  Admin + corporate only, like every kount_ot_* table (0132's policy).
-- =============================================================================
begin;

create table if not exists public.kount_ot_bibles (
  id            uuid primary key default gen_random_uuid(),
  venue_id      text not null,
  title         text not null check (length(btrim(title)) > 0),
  file_name     text not null,
  storage_path  text not null,
  size_bytes    bigint,
  content_hash  text,
  is_current    boolean not null default true,
  uploaded_by   text default (auth.jwt() ->> 'email'),
  created_at    timestamptz not null default now()
);
create index if not exists kount_ot_bibles_venue_idx on public.kount_ot_bibles (venue_id, is_current);

alter table public.kount_ot_bibles enable row level security;
revoke all on table public.kount_ot_bibles from public, anon, authenticated;
grant select, insert, update, delete on table public.kount_ot_bibles to authenticated;
drop policy if exists kount_ot_bibles_corporate on public.kount_ot_bibles;
create policy kount_ot_bibles_corporate on public.kount_ot_bibles for all to authenticated
  using (public.kount_is_corporate() is true) with check (public.kount_is_corporate() is true);

update storage.buckets set file_size_limit = 52428800 where id = 'kount-order-docs';

commit;
