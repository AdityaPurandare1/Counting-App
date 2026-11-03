-- ROLLBACK for 0142_kount_ot_other_attachments: the bucket back to PDF + PNG + JPEG, the hash column
-- dropped. 'other' documents already attached stay (kind 'other' is 0132's); their files stay in storage.
begin;
update storage.buckets set allowed_mime_types = array['application/pdf', 'image/png', 'image/jpeg'] where id = 'kount-order-docs';
drop index if exists public.kount_ot_documents_order_hash_uq;
alter table public.kount_ot_documents drop column if exists content_hash;
commit;
