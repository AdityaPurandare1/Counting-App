-- =============================================================================
--  0142_kount_ot_other_attachments   (every attachment of an order's e-mails)
--
--  The user (2026-11-03): quote / invoice PDFs viewable from the Orders list,
--  and "any more attachments that I receive in the email like an excel with
--  tracking numbers inside ... attached as well under [an] other column".
--  The morning pull now keeps a vendor e-mail's non-PDF attachments (Excel,
--  CSV, Word, photos) on the order that e-mail belongs to, as documents of
--  kind 'other' (already allowed since 0132). Tracking numbers in a sheet are
--  added to the order as well.
--
--    storage bucket kount-order-docs  accepts spreadsheets, CSV, Word, images
--    kount_ot_documents.content_hash  sha-256 of the file; the same file is
--                                     attached to an order once
-- =============================================================================
begin;

update storage.buckets
   set allowed_mime_types = array[
     'application/pdf', 'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/heic',
     'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.ms-excel', 'text/csv',
     'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/msword', 'text/plain'
   ]
 where id = 'kount-order-docs';

alter table public.kount_ot_documents add column if not exists content_hash text;
create unique index if not exists kount_ot_documents_order_hash_uq
  on public.kount_ot_documents (order_id, content_hash) where content_hash is not null;

commit;
