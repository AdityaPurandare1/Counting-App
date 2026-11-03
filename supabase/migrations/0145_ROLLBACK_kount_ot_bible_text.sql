-- ROLLBACK for 0145_kount_ot_bible_text: the text copies go (the bibles themselves are untouched).
begin;
alter table public.kount_ot_bibles drop column if exists text_index;
commit;
