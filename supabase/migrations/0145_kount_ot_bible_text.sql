-- =============================================================================
--  0145_kount_ot_bible_text   (a searchable text copy of each bible, for Ask AI)
--
--  The user (2026-11-03): Ask AI should give "statuses and details on the
--  orders/bibles we have put in". A bible workbook runs to 25 MB with its
--  pictures, too heavy to open per question; Ask AI searches this text copy
--  instead and sends the matching rows with the question.
--
--    kount_ot_bibles.text_index  { sheets: [{ name, header: [..], rows: [[..]] }] }
--                                (cell text only; written when the bible is first
--                                 opened in the Bibles tab; 0144's 8 filled now)
-- =============================================================================
begin;

alter table public.kount_ot_bibles add column if not exists text_index jsonb;

comment on column public.kount_ot_bibles.text_index is
  'The bible''s cell text by sheet ({sheets: [{name, header, rows}]}), for Ask AI search (0145); null = not built yet';

commit;
