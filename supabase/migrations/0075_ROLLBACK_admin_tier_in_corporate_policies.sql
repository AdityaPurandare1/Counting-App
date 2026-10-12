-- ROLLBACK for 0075: restores the policies to their exact pre-0075 text.
begin;

alter policy "venue_scoped_read_kount_avt_reports" on public."kount_avt_reports"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND ((u.role = 'corporate'::text) OR (kount_avt_reports.venue_ids && u.venue_ids))))));

alter policy "venue_scoped_read_kount_avt_rows" on public."kount_avt_rows"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND ((u.role = 'corporate'::text) OR (kount_avt_rows.venue_id = ANY (u.venue_ids)))))));

alter policy "kount_client_errors_select" on public."kount_client_errors"
  using ((EXISTS ( SELECT 1
   FROM app_users
  WHERE ((lower(app_users.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (app_users.role = 'corporate'::text) AND (app_users.is_active = true)))));

alter policy "kount_entries_deleted_log_select_corporate" on public."kount_entries_deleted_log"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((u.email = (auth.jwt() ->> 'email'::text)) AND (u.role = 'corporate'::text)))));

alter policy "auth_master_item_upcs_delete" on public."master_item_upcs"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = 'corporate'::text)))));

alter policy "auth_master_item_upcs_update" on public."master_item_upcs"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = 'corporate'::text)))))
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = 'corporate'::text)))));

alter policy "master_items_insert_corporate" on public."master_items"
  with check (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true))))));

alter policy "master_items_update_corporate" on public."master_items"
  using (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true))))))
  with check (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true))))));

alter policy "new_recipe_ing_map_delete_corporate" on public."new_recipe_ingredient_master_map"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))));

alter policy "new_recipe_ing_map_insert_corporate" on public."new_recipe_ingredient_master_map"
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))));

alter policy "new_recipe_ing_map_update_corporate" on public."new_recipe_ingredient_master_map"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))))
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))));

alter policy "new_recipe_pos_skus_delete_corporate" on public."new_recipe_pos_skus"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))));

alter policy "new_recipe_pos_skus_insert_corporate" on public."new_recipe_pos_skus"
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))));

alter policy "new_recipe_pos_skus_update_corporate" on public."new_recipe_pos_skus"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))))
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = 'corporate'::text) AND (u.is_active = true)))));

alter policy "auth_update_upc_mapping_stats" on public."upc_mappings"
  using (((lower(submitted_by_email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) OR (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = 'corporate'::text))))))
  with check (((lower(submitted_by_email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) OR (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = 'corporate'::text))))));

commit;
