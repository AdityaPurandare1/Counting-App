-- Rollback for 0082_little_luck_wine_sake.
-- Removes Little Luck's pre-opening wine/sake load. Masters are DEACTIVATED
-- rather than deleted: by the time anyone runs this they may already have been
-- counted, and deleting a master that kount_entries references would orphan a
-- real count.
begin;

delete from public.kount_venue_cost_overrides
 where venue_id = 'v11'
   and source like 'Little Luck pre-opening sheet 2026-10-18%';

delete from public.kount_carried_items
 where notes like 'Little Luck pre-opening%';

update public.master_items
   set is_active = false
 where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'
   and category = 'Wine Cost'
   and id in (select master_item_id from public.kount_venue_cost_overrides
               where venue_id = 'v11' and source like 'Little Luck pre-opening%')
   and not exists (select 1 from public.kount_entries e where e.master_item_id = master_items.id);

select 'rolled back 0082' as status;
commit;
