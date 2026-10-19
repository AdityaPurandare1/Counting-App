-- =============================================================================
--  0085_fix_mio_barcode_mislink   (DATA, not schema)
--
--  Barcode 086395521009 (normalised 86395521009) was attached to
--  "(Prep) Phony Negroni BATCH" during the Little Luck 2026-10-18 count,
--  source scan_admin_blank_add, by alexaposner@gmail.com.
--
--  It belongs to Mio Sparkling Sake. Two independent reasons it is wrong where
--  it is: the counter typed that exact code on a "Mio Sparkling Sake" entry in
--  the same count, and a house-made prep BATCH cannot carry a manufacturer UPC
--  at all. 0084 therefore could not attach Mio's code (upc_normalized is
--  unique) and it silently stayed on the batch.
--
--  HOW IT HAPPENED, worth recording: resolveUpcLinkPolicy auto-approves a
--  "blank add" -- an item with no UPC yet -- for ANY role, with no review. That
--  is deliberate and keeps counters fast (~85% of scans), but it means one
--  mis-tap writes a wrong link live. Checked for scale: this is the ONLY
--  prep/batch item in the catalog carrying a UPC, so it is isolated, not
--  systemic.
--
--  Reassignment (as opposed to a blank add) is corporate-only by policy, which
--  is exactly what this migration is doing on corporate's behalf.
--
--  ROLLBACK: 0085_ROLLBACK_fix_mio_barcode_mislink.sql
-- =============================================================================
begin;

update public.master_item_upcs u
   set master_item_id = (select id from public.master_items
                          where name = 'Mio Sparkling Sake 300ml'
                            and organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
                            and is_active limit 1),
       notes = 'Reassigned by 0085 from "(Prep) Phony Negroni BATCH" — a house-made batch cannot hold a manufacturer UPC; counter typed this code on a Mio Sparkling Sake entry in the same count',
       added_by_email = 'apurandare@hwoodgroup.com'
 where u.upc_normalized = '86395521009'
   and exists (select 1 from public.master_items m
                where m.id = u.master_item_id and m.name = '(Prep) Phony Negroni BATCH');

-- Also demote the originating mapping row so the approved cache stops serving
-- the wrong item to every phone.
update public.upc_mappings
   set master_item_id = (select id from public.master_items
                          where name = 'Mio Sparkling Sake 300ml'
                            and organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
                            and is_active limit 1),
       item_name = 'Mio Sparkling Sake 300ml'
 where barcode_normalized = '86395521009'
   and item_name ilike '%negroni%';

select m.name as now_owns, u.upc_normalized
  from public.master_item_upcs u join public.master_items m on m.id = u.master_item_id
 where u.upc_normalized = '86395521009';

commit;
