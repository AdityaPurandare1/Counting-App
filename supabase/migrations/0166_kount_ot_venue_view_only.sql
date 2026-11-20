-- =============================================================================
--  0166_kount_ot_venue_view_only   (SECURITY: order tracker by venue, view only)
--
--  2026-11-10, Aditya, right after 0165: "the managers just need to be able to
--  view, orders will still come from my email". So a person with Order tracker
--  but WITHOUT All venues (kount_ot_scope() not null) only READS their venues'
--  orders, lines, documents, tracking, history, bibles and the whole warehouse --
--  exactly 0165's reads, unchanged. Every write 0165 opened to "their venues"
--  (orders, lines, documents, tracking, bibles, a new catalog item, uploads /
--  replacing / removing files in kount-order-docs) now needs All venues, and the
--  fresh-upload allowance in kount_ot_object_visible goes (they don't upload).
--  kount_ot_add_tracking / kount_ot_apply_document run as the caller, so these
--  policies refuse them for a venue-limited person too. Nothing changes for
--  All-venues people (every rule below is "All venues" for them, as before).
--  ROLLBACK: 0166_ROLLBACK_kount_ot_venue_view_only.sql (back to 0165's writes)
-- =============================================================================
begin;

drop policy if exists kount_ot_orders_insert on public.kount_ot_orders;
create policy kount_ot_orders_insert on public.kount_ot_orders for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_orders_update on public.kount_ot_orders;
create policy kount_ot_orders_update on public.kount_ot_orders for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_orders_delete on public.kount_ot_orders;
create policy kount_ot_orders_delete on public.kount_ot_orders for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_lines_insert on public.kount_ot_lines;
create policy kount_ot_lines_insert on public.kount_ot_lines for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_lines_update on public.kount_ot_lines;
create policy kount_ot_lines_update on public.kount_ot_lines for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_lines_delete on public.kount_ot_lines;
create policy kount_ot_lines_delete on public.kount_ot_lines for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_documents_write on public.kount_ot_documents;
create policy kount_ot_documents_write on public.kount_ot_documents for all to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_tracking_insert on public.kount_ot_tracking;
create policy kount_ot_tracking_insert on public.kount_ot_tracking for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_tracking_update on public.kount_ot_tracking;
create policy kount_ot_tracking_update on public.kount_ot_tracking for update to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_tracking_delete on public.kount_ot_tracking;
create policy kount_ot_tracking_delete on public.kount_ot_tracking for delete to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_bibles_write on public.kount_ot_bibles;
create policy kount_ot_bibles_write on public.kount_ot_bibles for all to authenticated
  using ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_ot_items_insert on public.kount_ot_items;
create policy kount_ot_items_insert on public.kount_ot_items for insert to authenticated
  with check ((select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_order_docs_write on storage.objects;
create policy kount_order_docs_write on storage.objects for insert to authenticated
  with check (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_order_docs_update on storage.objects;
create policy kount_order_docs_update on storage.objects for update to authenticated
  using (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null)
  with check (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

drop policy if exists kount_order_docs_delete on storage.objects;
create policy kount_order_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'kount-order-docs' and (select public.kount_has_feature('purchasing:order-tracker')) and (select public.kount_ot_scope()) is null);

create or replace function public.kount_ot_object_visible(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select x.s is null
      or exists (select 1 from public.kount_ot_documents d where d.storage_path = p_name and public.kount_ot_order_mine(d.order_id))
      or exists (select 1 from public.kount_ot_bibles b where b.storage_path = p_name and b.venue_id = any (x.s))
    from (select public.kount_ot_scope() as s) x;
$$;

select 'policies' as k, count(*)::text as v from pg_policies
 where (schemaname = 'public' and tablename like 'kount_ot%') or (schemaname = 'storage' and policyname like 'kount_order_docs%');
commit;
