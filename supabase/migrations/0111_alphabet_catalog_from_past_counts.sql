-- =============================================================================
--  0111_alphabet_catalog_from_past_counts   (DATA)
--
--  Check of Alphabet's catalog (0109/0110) against its three real counts
--  (ALPHA0 8/28 opening, A-907 9/28, A-595 10/26): 191/211, 196/209 and
--  212/220 counted products were visible. Of the rest:
--  * ADDED (real stock counted before, no invoice link or price, so the
--    nightly refresh would never add it): Agave Nectar 1gal, Casamigos
--    Cristalino 1L and Mount Gay Eclipse 1L (0109 left out their 750ml twins
--    assuming the 1L was in the catalog -- it was not, so both products would
--    have vanished), Casanova di Neri White Label Brunello, Cocktail Onion
--    32oz, Filthy Cocktail Onion 8oz, Cranberry Juice 64fl.oz, Crazy Mountain
--    Lime + Original Lager (N/A beer, 63 each at opening), the blue-cheese
--    stuffed olives, Domaine Bellavoine Maranges, Fabbri Strawberries 1each,
--    Honey 16oz, Liquid Alchemist Passionfruit 375ml, Sprite 12fl.oz,
--    Strawberry Puree 1kg, Tajin 1each, Yamazaki 18yr 750ml.
--  * HIDDEN: 'STRAWBERRIES IN SYRUP FABBRI' (raw name; same product as
--    Fabbri Strawberries 1each).
--  * LEFT OUT on purpose: the 750ml twins of Casamigos Cristalino / Mount Gay
--    / Knob Creek / The Botanist, the two extra canned-lychee rows (A-595's
--    'Lychee, Canned' stays), inactive rows (Tyler Mae Estate 2020, Pimento
--    Stuffed Olives, Jojo TRAINING batch), and the 3L juice pouches (juice
--    counting unit is an open decision with Alphabet).
--  ROLLBACK: delete from kount_venue_catalog where venue_id = 'v12' and added_by = 'claude 2026-10-26 (past counts)';
--            update kount_venue_catalog set hidden = false, hidden_reason = null
--             where venue_id = 'v12' and hidden_reason like 'raw name; same product as Fabbri%';
-- =============================================================================
begin;

insert into public.kount_venue_catalog (venue_id, master_item_id, source, added_by)
select distinct 'v12', coalesce(m.merged_into_id, m.id), 'counted at Alphabet before (ALPHA0 / A-907 / A-595)', 'claude 2026-10-26 (past counts)'
  from public.master_items m
  join public.master_items s on s.id = coalesce(m.merged_into_id, m.id) and s.is_active
 where exists (select 1 from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
                where a.venue_id = 'v12' and a.status <> 'cancelled' and e.master_item_id = m.id)
   and (m.name in ('Agave Nectar 1gal', 'Casamigos Cristalino 1L', 'Mount Gay Ecliplse 1L', 'Cocktail Onion 32oz',
                   'Filthy Cocktail Onion 8oz 8oz', 'Cranberry Juice 64fl.oz', 'Crazy Mountain LIme',
                   'Crazy Mountain Original Lager', 'Fabbri Strawberries 1each', 'Honey 16oz',
                   'Liquid Alchemist Passionfruit 375ml', 'Sprite 12fl.oz', 'Strawberry Puree 1kg', 'Tajin 1each',
                   'Yamazaki 18yr 750ml')
        or m.name like 'Casanova di Neri%White Label%Brunello%'
        or m.name like 'DIVINA OLIVE GREEN STFD W/ BLUE CHS%'
        or m.name like 'Domaine Bellavoine, ''Cuvee Margot'', Maranges%')
on conflict (venue_id, master_item_id) do update set hidden = false, hidden_reason = null;

update public.kount_venue_catalog c
   set hidden = true, hidden_reason = 'raw name; same product as Fabbri Strawberries 1each'
  from public.master_items m
 where c.venue_id = 'v12' and c.master_item_id = m.id and m.name = 'STRAWBERRIES IN SYRUP FABBRI';

select count(*) filter (where not hidden) visible, count(*) filter (where hidden) hidden,
       count(*) filter (where added_by = 'claude 2026-10-26 (past counts)') added_now
  from public.kount_venue_catalog where venue_id = 'v12';
commit;
