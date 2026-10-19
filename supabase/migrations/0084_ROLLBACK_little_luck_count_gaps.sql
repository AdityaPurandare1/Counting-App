-- Rollback for 0084_little_luck_count_gaps.
-- Un-links the entries first (so nothing references the masters), removes the
-- barcodes and carried flags, then DEACTIVATES rather than deletes the masters
-- -- by now they may be referenced by other venues' counts.
begin;

create temp table _g on commit drop as
select id, name from public.master_items
 where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
   and name in ('Daiyame Shochu 750ml','Mio Sparkling Sake 300ml',
                'Riesling, Von Winning, Forster Ungeheuer, Pfalz, DE 2024',
                'Gruner Veltliner, Weingut Jager, Federspiel, Wachau, AT 2024',
                '(Prep) One Summers Day BATCH');

update public.kount_entries e set master_item_id = null
  from _g, public.kount_audits a
 where a.id = e.audit_id and a.venue_id = 'v11' and e.master_item_id = _g.id;

delete from public.master_item_upcs u using _g
 where u.master_item_id = _g.id
   and u.notes like 'Captured on the Little Luck 2026-10-18 count%';

delete from public.kount_carried_items c using _g
 where c.master_item_id = _g.id and c.notes = 'Little Luck 2026-10-18 count gap';

update public.master_items m set is_active = false
  from _g where m.id = _g.id
   and not exists (select 1 from public.kount_entries e where e.master_item_id = m.id);

select 'rolled back 0084' as status;
commit;
