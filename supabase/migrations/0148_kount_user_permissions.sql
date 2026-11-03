-- =============================================================================
--  0148_kount_user_permissions   (roles + per-person permissions — the data)
--
--  The user (2026-11-03), with a screenshot of a User Access page (roles with a
--  PRIMARY one, then projects with "Allowed n/m" and their features): "This is
--  how i want the permission to change as well for everything in the system.
--  For the people with current accesses donot change anything give them the
--  exact permissions they have but moving forward I should be able to give
--  permissions to each one like this". Decided with them: roles are TEMPLATES
--  (ticking a role adds its permissions; then a person's ticks are their own),
--  several roles per person with one primary, desktop + database first.
--
--    kount_features         the permission catalog ("project:feature"), seeded
--                           from Counting-Admin src/lib/permissions.ts (one source;
--                           its test compares this seed)
--    kount_role_templates   what each role starts with = exactly what that role
--                           could do before (routes, screens, database gates)
--    app_users.roles        all of a person's roles; app_users.role stays the
--                           PRIMARY one (the phone and every gate still read it)
--    app_users.features     the person's own permission keys
--    kount_has_feature(k)   the check the database gates use (0149); a Keva
--                           platform admin (global corporate) has the corporate set
--
--  NOTHING CHANGES HERE: every person gets their role's template, and no gate
--  reads the new columns until 0149.
-- =============================================================================
begin;

create table if not exists public.kount_features (
  key           text primary key check (key ~ '^[a-z]+:[a-z0-9-]+$'),
  project       text not null,
  project_label text not null,
  label         text not null,
  description   text not null,
  sort          int  not null
);
create table if not exists public.kount_role_templates (
  role        text not null check (role in ('admin', 'corporate', 'manager', 'counter', 'venue_manager')),
  feature_key text not null references public.kount_features (key) on delete cascade,
  primary key (role, feature_key)
);
alter table public.kount_features enable row level security;
alter table public.kount_role_templates enable row level security;
drop policy if exists kount_features_read on public.kount_features;
create policy kount_features_read on public.kount_features for select to authenticated using (true);
drop policy if exists kount_role_templates_read on public.kount_role_templates;
create policy kount_role_templates_read on public.kount_role_templates for select to authenticated using (true);
revoke all on public.kount_features, public.kount_role_templates from anon, authenticated;
grant select on public.kount_features, public.kount_role_templates to authenticated;

insert into public.kount_features (key, project, project_label, label, description, sort) values
  ('audit:view', 'audit', 'Audit', 'Venues, variance & history', 'Venues, Variance, Item history, Recount and Summary for their venues', 10),
  ('audit:overview', 'audit', 'Audit', 'Overview', 'The audit overview: every venue''s counts at a glance', 20),
  ('audit:counts', 'audit', 'Audit', 'Counts', 'Open counts, close Count 1, finish a count, drill into items', 30),
  ('audit:edit-counts', 'audit', 'Audit', 'Correct counts', 'Change a counted quantity after the count (their venues)', 40),
  ('audit:delete-lines', 'audit', 'Audit', 'Delete count lines', 'Remove a count line from an audit', 50),
  ('audit:manage', 'audit', 'Audit', 'Manage audits', 'Cancel, reopen, reactivate and delete audits; dismiss recounts; clear stale audits', 60),
  ('audit:costs', 'audit', 'Audit', 'Costs in audit reports', 'Item costs in the month-end audit report', 70),
  ('team:issues', 'team', 'Team', 'Issues tracker', 'See and resolve the issues counters raise', 80),
  ('team:ask-ai', 'team', 'Team', 'Ask AI', 'Ask questions about counts and variance', 90),
  ('team:ask-ai-orders', 'team', 'Team', 'Ask AI about orders', 'Ask AI about orders, payments, stock and the venue bibles', 100),
  ('admin:approvals', 'admin', 'Admin', 'Approvals', 'Approve or reject new barcodes and items', 110),
  ('admin:force-approve', 'admin', 'Admin', 'Force-approve barcodes', 'Commit a barcode directly when Approve fails', 120),
  ('admin:stock', 'admin', 'Admin', 'Stock on hand', 'Stock on hand by venue', 130),
  ('admin:reports', 'admin', 'Admin', 'Reports', 'Variance and audit reports', 140),
  ('admin:transfers', 'admin', 'Admin', 'Transfers', 'Record transfers between venues', 150),
  ('admin:transfers-manage', 'admin', 'Admin', 'Delete any transfer', 'Delete transfers other people recorded', 160),
  ('admin:food-count', 'admin', 'Admin', 'Food count', 'Upload a food count (their venues)', 170),
  ('admin:catalog', 'admin', 'Admin', 'Catalog', 'Items, barcodes, merges and imports', 180),
  ('admin:venue-settings', 'admin', 'Admin', 'Venue settings', 'Venues, zones and how each venue counts', 190),
  ('purchasing:order-tracker', 'purchasing', 'Purchasing', 'Order tracker', 'Orders, the Inbox, warehouse stock and the bibles', 200),
  ('purchasing:order-prices', 'purchasing', 'Purchasing', 'Order prices', 'Prices paid on orders and quotes', 210),
  ('purchasing:liquor-wine', 'purchasing', 'Purchasing', 'Liquor & wine prices', 'Liquor and wine bottle prices and spend', 220),
  ('access:all-venues', 'access', 'Access', 'All venues', 'Sees and runs every venue (corporate access); otherwise only the venues picked', 230),
  ('access:users', 'access', 'Access', 'User access', 'Add users; change roles, permissions and venues', 240),
  ('phone:count', 'phone', 'Counting app', 'Count', 'Count and scan at their venues on the phone', 250),
  ('phone:run', 'phone', 'Counting app', 'Run counts', 'Start, close and submit counts at their venues', 260)
on conflict (key) do update set project = excluded.project, project_label = excluded.project_label, label = excluded.label, description = excluded.description, sort = excluded.sort;

insert into public.kount_role_templates (role, feature_key) values
  ('admin', 'audit:view'),
  ('admin', 'audit:overview'),
  ('admin', 'audit:counts'),
  ('admin', 'audit:edit-counts'),
  ('admin', 'audit:delete-lines'),
  ('admin', 'audit:manage'),
  ('admin', 'audit:costs'),
  ('admin', 'team:issues'),
  ('admin', 'team:ask-ai'),
  ('admin', 'team:ask-ai-orders'),
  ('admin', 'admin:approvals'),
  ('admin', 'admin:force-approve'),
  ('admin', 'admin:stock'),
  ('admin', 'admin:reports'),
  ('admin', 'admin:transfers'),
  ('admin', 'admin:transfers-manage'),
  ('admin', 'admin:food-count'),
  ('admin', 'admin:catalog'),
  ('admin', 'admin:venue-settings'),
  ('admin', 'purchasing:order-tracker'),
  ('admin', 'purchasing:order-prices'),
  ('admin', 'purchasing:liquor-wine'),
  ('admin', 'access:all-venues'),
  ('admin', 'access:users'),
  ('admin', 'phone:count'),
  ('admin', 'phone:run'),
  ('corporate', 'audit:view'),
  ('corporate', 'audit:overview'),
  ('corporate', 'audit:counts'),
  ('corporate', 'audit:edit-counts'),
  ('corporate', 'audit:delete-lines'),
  ('corporate', 'audit:manage'),
  ('corporate', 'audit:costs'),
  ('corporate', 'team:issues'),
  ('corporate', 'team:ask-ai'),
  ('corporate', 'team:ask-ai-orders'),
  ('corporate', 'admin:approvals'),
  ('corporate', 'admin:force-approve'),
  ('corporate', 'admin:stock'),
  ('corporate', 'admin:reports'),
  ('corporate', 'admin:transfers'),
  ('corporate', 'admin:transfers-manage'),
  ('corporate', 'admin:food-count'),
  ('corporate', 'admin:catalog'),
  ('corporate', 'admin:venue-settings'),
  ('corporate', 'purchasing:order-tracker'),
  ('corporate', 'purchasing:order-prices'),
  ('corporate', 'purchasing:liquor-wine'),
  ('corporate', 'access:all-venues'),
  ('corporate', 'phone:count'),
  ('corporate', 'phone:run'),
  ('venue_manager', 'audit:view'),
  ('venue_manager', 'audit:overview'),
  ('venue_manager', 'audit:counts'),
  ('venue_manager', 'team:issues'),
  ('venue_manager', 'team:ask-ai'),
  ('venue_manager', 'admin:approvals'),
  ('venue_manager', 'admin:stock'),
  ('venue_manager', 'admin:reports'),
  ('venue_manager', 'admin:transfers'),
  ('venue_manager', 'audit:edit-counts'),
  ('manager', 'audit:view'),
  ('manager', 'audit:overview'),
  ('manager', 'audit:counts'),
  ('manager', 'team:issues'),
  ('manager', 'team:ask-ai'),
  ('manager', 'admin:approvals'),
  ('manager', 'admin:stock'),
  ('manager', 'admin:reports'),
  ('manager', 'admin:transfers'),
  ('manager', 'audit:costs'),
  ('manager', 'admin:food-count'),
  ('manager', 'phone:count'),
  ('manager', 'phone:run'),
  ('counter', 'phone:count')
on conflict do nothing;

-- a set of roles -> their permissions, in catalog order (the union of the templates)
create or replace function public.kount_template_for(p_roles text[])
returns text[]
language sql
stable
set search_path = public
as $$
  select coalesce(array_agg(f.key order by f.sort), '{}')
    from public.kount_features f
   where exists (select 1 from public.kount_role_templates t where t.feature_key = f.key and t.role = any (p_roles));
$$;

alter table public.app_users add column if not exists roles text[];
alter table public.app_users add column if not exists features text[];

-- everyone as they are: their role, its template
update public.app_users set roles = array[role] where roles is null;
update public.app_users set features = public.kount_template_for(roles) where features is null;

alter table public.app_users alter column roles set not null;
alter table public.app_users alter column features set not null;
alter table public.app_users drop constraint if exists app_users_roles_check;
alter table public.app_users add constraint app_users_roles_check
  check (cardinality(roles) > 0 and roles <@ array['admin', 'corporate', 'manager', 'counter', 'venue_manager'] and role = any (roles));

-- a new person (the invite path sends a role only) starts with their roles' templates; a role changed ALONE
-- (the old edit path) takes that role's template, as a role change always did; unknown keys are refused
create or replace function public.kount_app_users_access()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  bad text;
begin
  if tg_op = 'UPDATE' and new.role is distinct from old.role
     and new.roles is not distinct from old.roles and new.features is not distinct from old.features then
    new.roles := array[new.role];
    new.features := public.kount_template_for(new.roles);
  end if;
  if new.roles is null or cardinality(new.roles) = 0 then new.roles := array[new.role]; end if;
  if not (new.role = any (new.roles)) then new.roles := array[new.role] || new.roles; end if;
  if new.features is null then new.features := public.kount_template_for(new.roles); end if;
  select k into bad from unnest(new.features) k where not exists (select 1 from public.kount_features f where f.key = k) limit 1;
  if bad is not null then raise exception 'unknown permission: %', bad using errcode = '22023'; end if;
  return new;
end $$;

drop trigger if exists app_users_access on public.app_users;
create trigger app_users_access before insert or update on public.app_users
  for each row execute function public.kount_app_users_access();

-- a Keva platform admin: corporate everywhere (the second half of kount_is_corporate, on its own)
create or replace function public.kount_keva_global_corporate()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.organization_users ou
      join public.kount_role_map m on m.keva_role = ou.role
     where ou.user_id = auth.uid() and ou.is_active is true and m.global_corporate
       and split_part(lower(coalesce(auth.jwt() ->> 'email', '')), '@', 2) in (select d.domain from public.kount_keva_email_domains d));
$$;

-- the caller has this permission: their own list, or the corporate set for a Keva platform admin
create or replace function public.kount_has_feature(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
           select 1 from public.app_users u
            where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and u.is_active = true and p_key = any (u.features))
      or (exists (select 1 from public.kount_role_templates t where t.role = 'corporate' and t.feature_key = p_key)
          and public.kount_keva_global_corporate());
$$;

revoke all on function public.kount_template_for(text[]) from public, anon;
revoke all on function public.kount_keva_global_corporate() from public, anon;
revoke all on function public.kount_has_feature(text) from public, anon;
grant execute on function public.kount_template_for(text[]) to authenticated;
grant execute on function public.kount_keva_global_corporate() to authenticated;
grant execute on function public.kount_has_feature(text) to authenticated;

commit;
