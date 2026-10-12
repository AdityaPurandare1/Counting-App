-- =============================================================================
--  0075_admin_tier_in_corporate_policies
--
--  The 'admin' role (v0.58, above corporate) is already in kount_is_corporate() and
--  kount_can_see_venue(), but 15 RLS policies still tested u.role = 'corporate' alone.
--  An admin with no venue_ids read NO variance (kount_avt_reports / kount_avt_rows), so the
--  Variance panel said "no variance computed" at every venue, and could not write the catalog,
--  UPC and recipe-link tables these policies guard. Venue-assigned users (Robert, Dean) were
--  never affected.
--
--  Each policy is rewritten from its live text with exactly one change:
--    role = 'corporate'  ->  role = ANY (ARRAY['corporate','admin'])
--  ROLLBACK: 0075_ROLLBACK_admin_tier_in_corporate_policies.sql (exact pre-0075 text).
-- =============================================================================
begin;

alter policy "venue_scoped_read_kount_avt_reports" on public."kount_avt_reports"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND ((u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) OR (kount_avt_reports.venue_ids && u.venue_ids))))));

alter policy "venue_scoped_read_kount_avt_rows" on public."kount_avt_rows"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND ((u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) OR (kount_avt_rows.venue_id = ANY (u.venue_ids)))))));

alter policy "kount_client_errors_select" on public."kount_client_errors"
  using ((EXISTS ( SELECT 1
   FROM app_users
  WHERE ((lower(app_users.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (app_users.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (app_users.is_active = true)))));

alter policy "kount_entries_deleted_log_select_corporate" on public."kount_entries_deleted_log"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((u.email = (auth.jwt() ->> 'email'::text)) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))));

alter policy "auth_master_item_upcs_delete" on public."master_item_upcs"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))));

alter policy "auth_master_item_upcs_update" on public."master_item_upcs"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))))
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text]))))));

alter policy "master_items_insert_corporate" on public."master_items"
  with check (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true))))));

alter policy "master_items_update_corporate" on public."master_items"
  using (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true))))))
  with check (((organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41'::uuid) AND (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((( SELECT auth.jwt() AS jwt) ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true))))));

alter policy "new_recipe_ing_map_delete_corporate" on public."new_recipe_ingredient_master_map"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

alter policy "new_recipe_ing_map_insert_corporate" on public."new_recipe_ingredient_master_map"
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

alter policy "new_recipe_ing_map_update_corporate" on public."new_recipe_ingredient_master_map"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))))
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

alter policy "new_recipe_pos_skus_delete_corporate" on public."new_recipe_pos_skus"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

alter policy "new_recipe_pos_skus_insert_corporate" on public."new_recipe_pos_skus"
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

alter policy "new_recipe_pos_skus_update_corporate" on public."new_recipe_pos_skus"
  using ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))))
  with check ((EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])) AND (u.is_active = true)))));

alter policy "auth_update_upc_mapping_stats" on public."upc_mappings"
  using (((lower(submitted_by_email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) OR (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])))))))
  with check (((lower(submitted_by_email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) OR (EXISTS ( SELECT 1
   FROM app_users u
  WHERE ((lower(u.email) = lower(COALESCE((auth.jwt() ->> 'email'::text), ''::text))) AND (u.is_active = true) AND (u.role = ANY (ARRAY['corporate'::text, 'admin'::text])))))));

do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'public'
              and (coalesce(qual,'') || coalesce(with_check,'')) ~ '''corporate'''
              and (coalesce(qual,'') || coalesce(with_check,'')) !~ '''admin''') then
    raise exception '0075: a policy still grants corporate without admin';
  end if;
end $$;

commit;
