-- ROLLBACK for 0166: venue-limited order tracker users may write for their venues again (0165's rules).
begin;

drop policy if exists kount_ot_orders_insert on public.kount_ot_orders;
create policy kount_ot_orders_insert on public.kount_ot_orders for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));

drop policy if exists kount_ot_orders_update on public.kount_ot_orders;
create policy kount_ot_orders_update on public.kount_ot_orders for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_order_mine(id))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));

drop policy if exists kount_ot_orders_delete on public.kount_ot_orders;
create policy kount_ot_orders_delete on public.kount_ot_orders for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_order_mine(id));

drop policy if exists kount_ot_lines_insert on public.kount_ot_lines;
create policy kount_ot_lines_insert on public.kount_ot_lines for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));

drop policy if exists kount_ot_lines_update on public.kount_ot_lines;
create policy kount_ot_lines_update on public.kount_ot_lines for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));

drop policy if exists kount_ot_lines_delete on public.kount_ot_lines;
create policy kount_ot_lines_delete on public.kount_ot_lines for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[]) or (venue_id is null and public.kount_ot_order_venue(order_id) = any ((select public.kount_ot_scope())::text[]))));

drop policy if exists kount_ot_documents_write on public.kount_ot_documents;
create policy kount_ot_documents_write on public.kount_ot_documents for all to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));

drop policy if exists kount_ot_tracking_insert on public.kount_ot_tracking;
create policy kount_ot_tracking_insert on public.kount_ot_tracking for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_visible(order_id)));

drop policy if exists kount_ot_tracking_update on public.kount_ot_tracking;
create policy kount_ot_tracking_update on public.kount_ot_tracking for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));

drop policy if exists kount_ot_tracking_delete on public.kount_ot_tracking;
create policy kount_ot_tracking_delete on public.kount_ot_tracking for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or public.kount_ot_order_mine(order_id)));

drop policy if exists kount_ot_bibles_write on public.kount_ot_bibles;
create policy kount_ot_bibles_write on public.kount_ot_bibles for all to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])))
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and ((select public.kount_ot_scope()) is null or venue_id = any ((select public.kount_ot_scope())::text[])));

drop policy if exists kount_ot_items_insert on public.kount_ot_items;
create policy kount_ot_items_insert on public.kount_ot_items for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')));

drop policy if exists kount_order_docs_write on storage.objects;
create policy kount_order_docs_write on storage.objects for insert to authenticated
  with check (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')));

drop policy if exists kount_order_docs_update on storage.objects;
create policy kount_order_docs_update on storage.objects for update to authenticated
  using (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_object_visible(name))
  with check (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_object_visible(name));

drop policy if exists kount_order_docs_delete on storage.objects;
create policy kount_order_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and public.kount_ot_object_visible(name));

create or replace function public.kount_ot_object_visible(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select x.s is null
      or exists (select 1 from public.kount_ot_documents d where d.storage_path = p_name and public.kount_ot_order_mine(d.order_id))
      or exists (select 1 from public.kount_ot_bibles b where b.storage_path = p_name and b.venue_id = any (x.s))
      or (not exists (select 1 from public.kount_ot_documents d where d.storage_path = p_name)
          and not exists (select 1 from public.kount_ot_bibles b where b.storage_path = p_name)
          and not exists (select 1 from public.kount_ot_inbox i where i.storage_path = p_name))
    from (select public.kount_ot_scope() as s) x;
$$;
commit;
