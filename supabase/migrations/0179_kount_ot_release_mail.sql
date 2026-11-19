-- =============================================================================
--  0179_kount_ot_release_mail   (the release engine, admin v1.30)
--
--  The user (2026-11-18): "I order a large batch, then EE stores it, then from that
--  large pile i keep ordering smaller batches as time goes ... 5 cases to be sent to
--  delilah LA / miami ... I only order when the venue is running super low", then
--  "build the engine that tracks them like this please".
--
--  The mail pull (kount-order-mail releasePhase) reads every e-mail h.wood sends E&E
--  and, when it asks E&E to send stock out of storage to a venue, records that
--  release (kind 'release', the venue, the cases) the day it was asked - or the day
--  E&E said it went out. E&E's later delivery invoice (0141's storage line) links to
--  it instead of counting it again, and gives it the exact delivery day.
--
--    kount_ot_release_mail
--        each such e-mail read: who, when, the subject and what was read; state
--          recorded     its releases are in the stock moves (move_ids)
--          review       a release, but the item / cases / venue were not sure - a
--                       person picks them in the Warehouse tab
--          not_release  an e-mail to E&E about something else (a quote, a payment)
--          ignored      a person said it is not a release
--    kount_ot_stock_moves.mail_id
--        the e-mail a release came from (null = typed, an invoice line, a count)
--    kount_ot_mail_account.release_cursor
--        the last e-mail read; the next pull goes on from it (14 days back the first time)
--
--  Read / update = the Order tracker permission, like kount_ot_inbox; only the
--  function inserts.
--
--  ROLLBACK: 0179_ROLLBACK_kount_ot_release_mail.sql
-- =============================================================================
begin;

create table if not exists public.kount_ot_release_mail (
  id                   uuid primary key default gen_random_uuid(),
  message_id           text not null unique,
  conversation_id      text,
  internet_message_id  text,
  sent_at              timestamptz not null,
  sender_email         text,
  sender_name          text,
  subject              text,
  excerpt              text,
  -- what was read: { venue, lines: [{ sku, item, qty, unit }], shipped_on, model }
  read                 jsonb,
  state                text not null default 'review' check (state in ('recorded', 'review', 'not_release', 'ignored')),
  -- why it waits for a person / what was done
  decision             text,
  move_ids             uuid[],
  decided_by           text,
  decided_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists kount_ot_release_mail_state_idx on public.kount_ot_release_mail (state, sent_at desc);

drop trigger if exists kount_ot_release_mail_touch on public.kount_ot_release_mail;
create trigger kount_ot_release_mail_touch before update on public.kount_ot_release_mail
  for each row execute function public.kount_ot_touch();

alter table public.kount_ot_release_mail enable row level security;
revoke all on table public.kount_ot_release_mail from anon;
grant select, update on table public.kount_ot_release_mail to authenticated;
drop policy if exists kount_ot_release_mail_read on public.kount_ot_release_mail;
create policy kount_ot_release_mail_read on public.kount_ot_release_mail for select to authenticated
  using (public.kount_has_feature('purchasing:order-tracker'));
drop policy if exists kount_ot_release_mail_update on public.kount_ot_release_mail;
create policy kount_ot_release_mail_update on public.kount_ot_release_mail for update to authenticated
  using (public.kount_has_feature('purchasing:order-tracker'))
  with check (public.kount_has_feature('purchasing:order-tracker'));

alter table public.kount_ot_stock_moves
  add column if not exists mail_id uuid references public.kount_ot_release_mail (id) on delete set null;
create index if not exists kount_ot_stock_moves_mail_idx on public.kount_ot_stock_moves (mail_id) where mail_id is not null;
comment on column public.kount_ot_stock_moves.mail_id is 'The e-mail asking E&E for this release (0179); null = typed, an invoice line or a count';

alter table public.kount_ot_mail_account add column if not exists release_cursor timestamptz;
comment on column public.kount_ot_mail_account.release_cursor is 'The last e-mail to E&E the release engine read (0179)';

commit;

-- check:
-- select (select count(*) from information_schema.tables where table_name = 'kount_ot_release_mail') as tbl,          -- 1
--        (select count(*) from information_schema.columns where table_name = 'kount_ot_stock_moves' and column_name = 'mail_id') as col,  -- 1
--        (select count(*) from pg_policies where tablename = 'kount_ot_release_mail') as policies;                       -- 2
