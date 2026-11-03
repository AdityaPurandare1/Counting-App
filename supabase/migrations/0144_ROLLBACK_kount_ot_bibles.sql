-- ROLLBACK for 0144_kount_ot_bibles: the bibles table and the 50 MB limit go (files stay in storage under bibles/).
begin;
drop table if exists public.kount_ot_bibles;
update storage.buckets set file_size_limit = 20971520 where id = 'kount-order-docs';
commit;
