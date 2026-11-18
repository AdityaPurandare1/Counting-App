-- =============================================================================
--  0177_kount_venue_accounting_stage   (which accounting mailbox a venue's payment requests go to, admin v1.25)
--
--  The user (2026-11-18): "enable me to tag venues as preopening and operating so that emails are sent to the
--  correct accounting email. The hwoodap email is for operating and hwoodga is for preopening ... currently all
--  venues are operating".
--
--    kount_venues.accounting_stage   'operating'  -> payment requests to hwoodap@iqbackoffice.com
--                                    'preopening' -> payment requests to hwoodga@iqbackoffice.com
--  Every venue starts as operating (the default). Set on the admin's Venue settings, under the table's existing
--  policies. The sent-to-accounting check (0174) already finds e-mails to either mailbox.
-- =============================================================================
begin;

alter table public.kount_venues add column if not exists accounting_stage text not null default 'operating';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'kount_venues_accounting_stage_check') then
    alter table public.kount_venues add constraint kount_venues_accounting_stage_check check (accounting_stage in ('operating', 'preopening'));
  end if;
end $$;
comment on column public.kount_venues.accounting_stage is
  'Accounting mailbox for its payment requests (0177): operating -> hwoodap@iqbackoffice.com, preopening -> hwoodga@iqbackoffice.com';

commit;
