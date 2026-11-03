-- ROLLBACK for 0148_kount_user_permissions: back to one role per person (app_users.role is untouched by 0148).
-- Run only after 0149's rollback (its gates call kount_has_feature).
begin;
drop trigger if exists app_users_access on public.app_users;
drop function if exists public.kount_app_users_access();
alter table public.app_users drop constraint if exists app_users_roles_check;
alter table public.app_users drop column if exists features, drop column if exists roles;
drop function if exists public.kount_has_feature(text);
drop function if exists public.kount_keva_global_corporate();
drop function if exists public.kount_template_for(text[]);
drop table if exists public.kount_role_templates;
drop table if exists public.kount_features;
commit;
