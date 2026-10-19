-- =============================================================================
--  0090_ROLLBACK_fix_0084_sizes
--  Restores the names 0084 gave these four masters and clears base_size /
--  base_unit (0084 never set them). Only do this if the counters' recorded
--  sizes (Daiyame 900ml, Mio 750ml) turn out to be wrong.
-- =============================================================================
begin;

update public.master_items set name = 'Daiyame Shochu 750ml', base_size = null, base_unit = null
 where name = 'Daiyame Shochu 900ml' and organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41';

update public.master_items set name = 'Mio Sparkling Sake 300ml', base_size = null, base_unit = null
 where name = 'Mio Sparkling Sake 750ml' and organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41';

update public.master_items set name = left(name, length(name) - length(' 750ml')), base_size = null, base_unit = null
 where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
   and name in ('Riesling, Von Winning, Forster Ungeheuer, Pfalz, DE 2024 750ml',
                'Gruner Veltliner, Weingut Jager, Federspiel, Wachau, AT 2024 750ml');

commit;
