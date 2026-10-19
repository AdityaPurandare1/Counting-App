-- =============================================================================
--  0090_fix_0084_sizes   (DATA)
--
--  Corrects sizes that 0084 GUESSED. When 0084 repaired the five orphan entries
--  from Little Luck's 10/18 count it invented bottle sizes; the counters had
--  recorded the real sizes in issue_notes on those very entries, unused:
--    Daiyame Shochu       0084 said 750ml  -> counter wrote 900ml
--    Mio Sparkling Sake   0084 said 300ml  -> counter wrote 750ml
--  0084 also never set base_size/base_unit on any of its masters, so the
--  AVT's volume normalisation could not apply to them. Set from the counters'
--  notes (and 750ml for the two wines, whose 750ml the counter / bottle stated).
--  Entries reference master_item_id, not the name, so the rename moves nothing.
--  Barcodes stay where they are (Mio's 86395521009 was typed on the 750ml entry).
-- =============================================================================
begin;

update public.master_items set name = 'Daiyame Shochu 900ml', base_size = 900, base_unit = 'ml'
 where name = 'Daiyame Shochu 750ml' and organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41';

update public.master_items set name = 'Mio Sparkling Sake 750ml', base_size = 750, base_unit = 'ml'
 where name = 'Mio Sparkling Sake 300ml' and organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41';

update public.master_items set name = name || ' 750ml', base_size = 750, base_unit = 'ml'
 where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
   and name in ('Riesling, Von Winning, Forster Ungeheuer, Pfalz, DE 2024',
                'Gruner Veltliner, Weingut Jager, Federspiel, Wachau, AT 2024');

select name, base_size::text || base_unit as size from public.master_items
 where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
   and (name like 'Daiyame Shochu%' or name like 'Mio Sparkling Sake%'
        or name like 'Riesling, Von Winning, Forster Ungeheuer%2024%'
        or name like 'Gruner Veltliner, Weingut Jager%2024%')
 order by name;
commit;
