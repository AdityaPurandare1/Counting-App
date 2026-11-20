-- ROLLBACK for 0167: the read policies as 0165 wrote them, the permission taken off everyone, then removed.
begin;

drop policy if exists kount_ot_orders_read on public.kount_ot_orders;
create policy kount_ot_orders_read on public.kount_ot_orders for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or public.kount_ot_order_visible(id)));

drop policy if exists kount_ot_lines_read on public.kount_ot_lines;
create policy kount_ot_lines_read on public.kount_ot_lines for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));

drop policy if exists kount_ot_documents_read on public.kount_ot_documents;
create policy kount_ot_documents_read on public.kount_ot_documents for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));

drop policy if exists kount_ot_tracking_read on public.kount_ot_tracking;
create policy kount_ot_tracking_read on public.kount_ot_tracking for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_visible(order_id)));

drop policy if exists kount_ot_bibles_read on public.kount_ot_bibles;
create policy kount_ot_bibles_read on public.kount_ot_bibles for select to authenticated
  using (((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));

drop policy if exists kount_ot_items_read on public.kount_ot_items;
create policy kount_ot_items_read on public.kount_ot_items for select to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices')));

drop policy if exists kount_ot_stock_moves_read on public.kount_ot_stock_moves;
create policy kount_ot_stock_moves_read on public.kount_ot_stock_moves for select to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices')));

drop policy if exists kount_order_docs_read on storage.objects;
create policy kount_order_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'kount-order-docs' and ((select public.kount_has_feature('purchasing:order-tracker')) or (select public.kount_has_feature('purchasing:order-prices'))) and public.kount_ot_object_visible(name));

drop policy if exists kount_ot_events_corporate_read on public.kount_ot_events;
create policy kount_ot_events_corporate_read on public.kount_ot_events for select to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or (public.kount_ot_order_visible(order_id) and (line_id is null or public.kount_ot_line_visible(line_id)))));

update public.app_users set features = array_remove(features, 'purchasing:order-tracker-view')
 where 'purchasing:order-tracker-view' = any (features);
delete from public.kount_features where key = 'purchasing:order-tracker-view';
commit;
