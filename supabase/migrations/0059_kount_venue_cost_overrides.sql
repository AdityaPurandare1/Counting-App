-- =============================================================================
--  0059_kount_venue_cost_overrides
--
--  Per-VENUE unit costs for the audit report.
--
--  WHY
--  A catalog item has exactly one cost company-wide: the audit report and
--  compute_avt_for_audit both read the newest purchase_items.avg_cost per
--  master_items row, and kount_cost_overrides (the 2026-06-30 pin table) is
--  keyed on master_item_id alone. There is no way to say "Alphabet pays $27.75
--  for Ketel One 1L" without also repricing Poppy's 62 bottles of it. That
--  became a real problem on 2026-10-05: Alphabet's opening-invoice prices
--  (the "8.28.26 Alphabet Beverage INVENTORY - Batch Costed" tracker) differ
--  from the LA catalog costs on ~50 shared items, and Aditya's instruction was
--  explicit — Alphabet's numbers must change, nobody else's.
--
--  WHAT
--  One row per (counting venue, catalog item). When present, the audit report
--  values that venue's counted quantity at cost_per_unit instead of the
--  catalog cost. Nothing else reads this table yet: compute_avt_for_audit
--  still uses the catalog cost (Alphabet's variance is not meaningful until
--  its R365 invoice lines are item-linked anyway), and purchase_items is NOT
--  touched — unlike kount_cost_overrides there is no trigger here, so a
--  venue price can never leak into the shared catalog.
--
--  WHO CAN READ IT
--  Same shape as the 0055 venue scoping: corporate sees everything, a manager
--  or counter sees only their venues (kount_can_see_venue). No anon access —
--  this is a financial input. Writes are CLI/service only for now; an admin
--  UI can get an INSERT/UPDATE policy later if someone needs one.
--
--  REVERSIBLE: drop table public.kount_venue_cost_overrides;  (nothing else
--  depends on it; the admin treats a missing table as "no overrides" only if
--  the select errors — see auditReportData.ts — so drop the code first.)
-- =============================================================================

create table if not exists public.kount_venue_cost_overrides (
  venue_id        text        not null references public.kount_venues(id)  on delete cascade,
  master_item_id  uuid        not null references public.master_items(id)  on delete cascade,
  cost_per_unit   numeric     not null check (cost_per_unit >= 0),
  -- Where the number came from, for the next person who asks why Alphabet's
  -- Hennessy is $48.50 when the catalog says $40: e.g. "Alphabet Batch Costed
  -- sheet (SGWS 2026-08-07)" or "Alphabet R365 invoice #1234 2026-09-18".
  source          text,
  set_by          text,
  updated_at      timestamptz not null default now(),
  primary key (venue_id, master_item_id)
);

comment on table public.kount_venue_cost_overrides is
  'Per-venue unit cost used by the admin audit report in place of the catalog cost. No trigger, never written back to purchase_items.';

alter table public.kount_venue_cost_overrides enable row level security;

drop policy if exists kount_venue_cost_overrides_select on public.kount_venue_cost_overrides;
create policy kount_venue_cost_overrides_select
  on public.kount_venue_cost_overrides
  for select
  to authenticated
  using (public.kount_is_corporate() or public.kount_can_see_venue(venue_id));

revoke all on public.kount_venue_cost_overrides from anon, public;
grant select on public.kount_venue_cost_overrides to authenticated;
grant all on public.kount_venue_cost_overrides to service_role;

-- Verification: expect 1 policy, RLS on, anon with no privileges.
select
  (select count(*) from pg_policy where polrelid = 'public.kount_venue_cost_overrides'::regclass) as policies,
  (select relrowsecurity from pg_class where oid = 'public.kount_venue_cost_overrides'::regclass) as rls_on,
  (select count(*) from information_schema.role_table_grants
     where table_name = 'kount_venue_cost_overrides' and grantee = 'anon') as anon_grants;
