-- =============================================================================
--  0083_app_users_job_title   (SCHEMA, additive, display-only)
--
--  Adds app_users.job_title so a person's actual job ("Executive Chef",
--  "Senior Bar Manager", "Finance") can be recorded alongside their PERMISSION
--  role, which is a different thing.
--
--  WHY NOT NEW ROLES
--  Asked for "corporate but only Little Luck". That cannot be expressed:
--  role='corporate' hard-overrides venue scoping to ALL venues in the phone
--    counting-app.html:7779  venueIds: r.role === 'corporate' ? 'all' : (r.venue_ids || [])
--    counting-app.html:7965  same rule on the profile-hydrate path
--  and every venue-scoped user in prod is manager / counter / venue_manager
--  (all 10 corporate+admin users have empty venue_ids).
--
--  Adding real roles would touch 91 role checks in counting-app.html, 19 RLS
--  policies naming 'corporate', 6 SECURITY DEFINER functions gating on role,
--  the app_users CHECK constraint and the admin-user-mgmt whitelist. 0075 had
--  to patch 15 policies just to introduce the single 'admin' role. That is a
--  deliberate piece of work, not something to attempt while a count is live.
--
--  So: job_title carries the label, the existing venue-scoped 'manager' role
--  carries the permissions, and a real permission redesign stays a separate
--  decision. NOTHING reads job_title for authorization -- it is display only.
--
--  ROLLBACK: 0083_ROLLBACK_app_users_job_title.sql
-- =============================================================================
begin;

alter table public.app_users add column if not exists job_title text;

comment on column public.app_users.job_title is
  'Display-only job title (e.g. Executive Chef). NEVER used for authorization - permissions come from role + venue_ids.';

select column_name from information_schema.columns
 where table_schema='public' and table_name='app_users' and column_name='job_title';

commit;
