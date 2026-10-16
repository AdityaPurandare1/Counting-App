-- Rollback for 0080_little_luck_setup_parity. Restores Little Luck (v11) to
-- the pre-0080 defaults. Guarded on the values 0080 set, so re-running after
-- someone has since changed them deliberately is a no-op.
begin;

update public.kount_venues
   set depletion_source = 'pos_check_items',
       purchase_mapping = 'none'
 where id = 'v11'
   and depletion_source = 'item_day_facts'
   and purchase_mapping = 'venue_item_map';

select id, name, depletion_source, purchase_mapping
  from public.kount_venues where id = 'v11';

commit;
