-- =============================================================================
--  0135_kount_order_mail   (MORNING MAIL PULL for the Order tracker)
--
--  Every morning at 9:00 Pacific the kount-order-mail Edge Function reads the
--  connected Outlook mailbox (Microsoft Graph, delegated Mail.Read through the
--  Order Tracker app registration, one-time device-code sign-in), takes the
--  PDF attachments from the listed vendor domains, stores each in the private
--  'kount-order-docs' bucket, reads it with the same reader as a manual upload
--  (kount-read-purchase-doc / _shared/purchase-doc.ts) and then:
--    * clearly belongs to an existing order (same email thread, PO #, quote #
--      or invoice # from the same vendor), every product line already on the
--      order, no warnings  -> applied automatically (statuses forward only)
--    * anything else (new order, credit memo, warnings) -> waits in the
--      Inbox for one click (state 'pending')
--
--  Tables:
--    kount_ot_mail_account  one row: the mailbox, its Microsoft refresh token
--                           (kept in Vault, never in a column), vendor domains,
--                           the run lock and the last run. Service role only.
--    kount_ot_inbox         one row per PDF found; its id becomes the document
--                           id when saved, so a document can never save twice.
--  kount_ot_documents gains the email it came from (thread matching).
--  kount_ot_apply_document: the service role (the pull) may call it; it marks
--  the inbox row applied in the same transaction.
--  pg_cron 'kount-order-mail-morning': every 10 min in the 16:00 and 17:00 UTC
--  hours; the function itself only works when it is the 9 o'clock hour in Los
--  Angeles (so it is 9am in both PDT and PST).
--
--  ACCESS: admin + corporate (kount_is_corporate() is true) for everything a
--  person sees; the token is readable only by the service role.
--  ROLLBACK: 0135_ROLLBACK_kount_order_mail.sql
-- =============================================================================
begin;

-- ── the connected mailbox (one row, service role only) ──────────────────────
create table if not exists public.kount_ot_mail_account (
  id                      integer primary key default 1 check (id = 1),
  mailbox                 text,
  token_secret_id         uuid,          -- vault.secrets row holding the refresh token
  device_code             text,          -- a sign-in in progress; never leaves the server
  device_code_expires_at  timestamptz,
  connected_by            text,
  connected_at            timestamptz,
  -- PDFs are only taken from these sender domains (h.wood's own vendors)
  vendor_domains          text[] not null default array['eemercantile.co', 'shurehw.com', 'everythingpromo.com', 'kevidko.com', 'notification.intuit.com'],
  -- other external senders of invoice / quote PDFs, by domain + count only, for the person to add
  suggested_domains       jsonb not null default '{}'::jsonb,
  fetched_through         timestamptz,   -- newest received time already looked at
  running_since           timestamptz,   -- the run lock
  last_run                jsonb,
  updated_at              timestamptz not null default now()
);
alter table public.kount_ot_mail_account enable row level security;
revoke all on table public.kount_ot_mail_account from public, anon, authenticated;
insert into public.kount_ot_mail_account (id) values (1) on conflict (id) do nothing;

-- ── every PDF the pull found ────────────────────────────────────────────────
create table if not exists public.kount_ot_inbox (
  id                   uuid primary key default gen_random_uuid(),
  message_id           text not null,
  attachment_id        text not null,
  internet_message_id  text,
  conversation_id      text,
  subject              text,
  sender_email         text,
  sender_name          text,
  received_at          timestamptz,
  file_name            text,
  size_bytes           integer,
  content_hash         text not null,
  storage_path         text not null,
  state                text not null default 'unread' check (state in ('unread', 'pending', 'applied', 'ignored', 'error')),
  parsed               jsonb,
  model                text,
  attempts             integer not null default 0,
  read_error           text,
  decision             text,              -- why it was applied, or why it waits
  order_id             uuid references public.kount_ot_orders (id) on delete set null,
  decided_by           text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (message_id, attachment_id)
);
-- the same PDF forwarded again (AP, a colleague) is the same document
create unique index if not exists kount_ot_inbox_hash_uidx on public.kount_ot_inbox (content_hash);
create index if not exists kount_ot_inbox_state_idx on public.kount_ot_inbox (state, received_at);
alter table public.kount_ot_inbox enable row level security;
revoke all on table public.kount_ot_inbox from public, anon, authenticated;
grant select, update on table public.kount_ot_inbox to authenticated;
drop policy if exists kount_ot_inbox_corporate_read on public.kount_ot_inbox;
create policy kount_ot_inbox_corporate_read on public.kount_ot_inbox for select to authenticated
  using (public.kount_is_corporate() is true);
drop policy if exists kount_ot_inbox_corporate_update on public.kount_ot_inbox;
create policy kount_ot_inbox_corporate_update on public.kount_ot_inbox for update to authenticated
  using (public.kount_is_corporate() is true) with check (public.kount_is_corporate() is true);
drop trigger if exists kount_ot_inbox_touch on public.kount_ot_inbox;
create trigger kount_ot_inbox_touch before update on public.kount_ot_inbox
  for each row execute function public.kount_ot_touch();

-- ── documents remember the email they came from ─────────────────────────────
alter table public.kount_ot_documents
  add column if not exists source_message_id text,
  add column if not exists source_conversation_id text;
create index if not exists kount_ot_documents_thread_idx on public.kount_ot_documents (source_conversation_id)
  where source_conversation_id is not null;

-- ── token (Vault) — service role only ───────────────────────────────────────
-- (inside SECURITY DEFINER current_user is the owner, so the caller is told
--  apart by its JWT role: auth.role() = 'service_role' only for the service key)
create or replace function public.kount_ot_mail_token_get()
returns text language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'service role only' using errcode = '42501'; end if;
  return (select s.decrypted_secret from vault.decrypted_secrets s
           join public.kount_ot_mail_account a on a.token_secret_id = s.id where a.id = 1);
end
$fn$;

create or replace function public.kount_ot_mail_token_set(p_token text, p_mailbox text default null, p_by text default null)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
declare v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'service role only' using errcode = '42501'; end if;
  if nullif(p_token, '') is null then raise exception 'kount_ot_mail_token_set: empty token'; end if;
  select token_secret_id into v_id from public.kount_ot_mail_account where id = 1;
  if v_id is null or not exists (select 1 from vault.secrets where id = v_id) then
    delete from vault.secrets where name = 'kount_order_mail_refresh_token';
    v_id := vault.create_secret(p_token, 'kount_order_mail_refresh_token', 'Microsoft refresh token for the Kount order mail pull (0135)');
  else
    perform vault.update_secret(v_id, p_token);
  end if;
  update public.kount_ot_mail_account set
    token_secret_id = v_id,
    mailbox      = coalesce(p_mailbox, mailbox),
    connected_by = coalesce(p_by, connected_by),
    connected_at = case when p_mailbox is not null then now() else connected_at end,
    device_code = null, device_code_expires_at = null,
    updated_at = now()
  where id = 1;
end
$fn$;

-- disconnect: the person (admin / corporate) or the pull (when Microsoft says the sign-in is gone)
create or replace function public.kount_ot_mail_disconnect()
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if coalesce(auth.role(), '') <> 'service_role' and public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  delete from vault.secrets where id = (select token_secret_id from public.kount_ot_mail_account where id = 1);
  update public.kount_ot_mail_account set token_secret_id = null, mailbox = null, connected_by = null, connected_at = null,
    device_code = null, device_code_expires_at = null, updated_at = now()
  where id = 1;
end
$fn$;

-- the run lock: one pull at a time (a stale lock older than 10 minutes is taken over)
create or replace function public.kount_ot_mail_begin_run()
returns boolean language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'service role only' using errcode = '42501'; end if;
  update public.kount_ot_mail_account set running_since = now(), updated_at = now()
   where id = 1 and (running_since is null or running_since < now() - interval '10 minutes');
  return found;
end
$fn$;

-- the shared secret the morning cron job sends (so the open function URL can't be used to start pulls)
create or replace function public.kount_ot_mail_cron_secret()
returns text language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'service role only' using errcode = '42501'; end if;
  return (select decrypted_secret from vault.decrypted_secrets where name = 'kount_order_mail_cron');
end
$fn$;

-- what the admin shows (no token, no device code)
create or replace function public.kount_ot_mail_status()
returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  return (select jsonb_build_object(
      'mailbox', a.mailbox, 'connected', a.token_secret_id is not null, 'connected_by', a.connected_by, 'connected_at', a.connected_at,
      'signing_in', a.device_code is not null and a.device_code_expires_at > now(),
      'vendor_domains', to_jsonb(a.vendor_domains), 'suggested_domains', a.suggested_domains,
      'fetched_through', a.fetched_through,
      'running', a.running_since is not null and a.running_since > now() - interval '10 minutes',
      'last_run', a.last_run)
    from public.kount_ot_mail_account a where a.id = 1);
end
$fn$;

create or replace function public.kount_ot_mail_set_domains(p_domains text[])
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
declare v text[];
begin
  if public.kount_is_corporate() is not true then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct d order by d), '{}') into v
    from (select lower(btrim(regexp_replace(x, '^.*@', ''))) as d from unnest(coalesce(p_domains, '{}')) x) t
   where d ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' and d not in ('hwoodgroup.com');
  update public.kount_ot_mail_account set vendor_domains = v,
    suggested_domains = suggested_domains - v,
    updated_at = now() where id = 1;
end
$fn$;

revoke all on function public.kount_ot_mail_token_get() from public, anon, authenticated;
revoke all on function public.kount_ot_mail_token_set(text, text, text) from public, anon, authenticated;
revoke all on function public.kount_ot_mail_begin_run() from public, anon, authenticated;
revoke all on function public.kount_ot_mail_cron_secret() from public, anon, authenticated;
grant execute on function public.kount_ot_mail_token_get() to service_role;
grant execute on function public.kount_ot_mail_token_set(text, text, text) to service_role;
grant execute on function public.kount_ot_mail_begin_run() to service_role;
grant execute on function public.kount_ot_mail_cron_secret() to service_role;
revoke all on function public.kount_ot_mail_disconnect() from public, anon;
revoke all on function public.kount_ot_mail_status() from public, anon;
revoke all on function public.kount_ot_mail_set_domains(text[]) from public, anon;
grant execute on function public.kount_ot_mail_disconnect() to authenticated, service_role;
grant execute on function public.kount_ot_mail_status() to authenticated;
grant execute on function public.kount_ot_mail_set_domains(text[]) to authenticated;

-- the cron secret (created once)
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'kount_order_mail_cron') then
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'kount_order_mail_cron',
                                'Shared secret the kount-order-mail-morning cron job sends (0135)');
  end if;
end $$;

-- ── kount_ot_apply_document: the pull may call it; it closes the inbox row ──
create or replace function public.kount_ot_apply_document(p jsonb)
returns uuid
language plpgsql
security invoker
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_order uuid;
  v_note  text := nullif(p->>'note', '');
  v_items jsonb := '{}'::jsonb;
  v_id    uuid;
  v_sort  integer;
  r       jsonb;
begin
  -- the service role is the morning mail pull (it bypasses RLS)
  if public.kount_is_corporate() is not true and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  if nullif(p->'document'->>'id', '') is null then
    raise exception 'kount_ot_apply_document: document.id is required';
  end if;
  if exists (select 1 from public.kount_ot_documents d where d.id = (p->'document'->>'id')::uuid) then
    raise exception 'This document was already saved' using errcode = '23505';
  end if;

  -- 1. the order: an existing one (filling only what it lacks) or a new one
  if nullif(p->>'order_id', '') is not null then
    v_order := (p->>'order_id')::uuid;
    if not exists (select 1 from public.kount_ot_orders o where o.id = v_order) then
      raise exception 'kount_ot_apply_document: order not found';
    end if;
    if p->'order_patch' is not null then
      update public.kount_ot_orders o set
        order_number = coalesce(o.order_number, nullif(p->'order_patch'->>'order_number', '')),
        expected_on  = coalesce(nullif(p->'order_patch'->>'expected_on', '')::date, o.expected_on)
      where o.id = v_order;
    end if;
  else
    insert into public.kount_ot_orders (vendor_name, order_number, venue_id, deliver_to, ordered_on, expected_on)
    values (p->'new_order'->>'vendor_name', nullif(p->'new_order'->>'order_number', ''), nullif(p->'new_order'->>'venue_id', ''),
            coalesce(nullif(p->'new_order'->>'deliver_to', ''), 'warehouse'),
            nullif(p->'new_order'->>'ordered_on', '')::date, nullif(p->'new_order'->>'expected_on', '')::date)
    returning id into v_order;
  end if;

  -- 2. catalog items asked for; an active item with the same name + SKU is reused
  for r in select * from jsonb_array_elements(coalesce(p->'new_items', '[]'::jsonb)) loop
    v_id := null;
    select i.id into v_id from public.kount_ot_items i
     where i.is_active and lower(btrim(i.name)) = lower(btrim(r->>'name'))
       and coalesce(lower(btrim(i.sku)), '') = coalesce(lower(btrim(nullif(r->>'sku', ''))), '')
     limit 1;
    if v_id is null then
      insert into public.kount_ot_items (name, sku, vendor_name, unit, pack_size)
      values (btrim(r->>'name'), nullif(btrim(r->>'sku'), ''), nullif(r->>'vendor_name', ''),
              coalesce(nullif(r->>'unit', ''), 'case'), nullif(r->>'pack_size', '')::numeric)
      returning id into v_id;
    end if;
    v_items := v_items || jsonb_build_object(r->>'key', v_id);
  end loop;

  -- 3. existing lines: only the keys present in each update change
  for r in select * from jsonb_array_elements(coalesce(p->'updates', '[]'::jsonb)) loop
    update public.kount_ot_lines l set
      status          = case when r ? 'status' then r->>'status' else l.status end,
      status_source   = case when r ? 'status' then 'document' else l.status_source end,
      status_note     = case when r ? 'status' then v_note else l.status_note end,
      unit_price      = case when r ? 'unit_price' then (r->>'unit_price')::numeric else l.unit_price end,
      quote_number    = case when r ? 'quote_number' then r->>'quote_number' else l.quote_number end,
      invoice_number  = case when r ? 'invoice_number' then r->>'invoice_number' else l.invoice_number end,
      invoice_date    = case when r ? 'invoice_date' then (r->>'invoice_date')::date else l.invoice_date end,
      tracking_number = case when r ? 'tracking_number' then r->>'tracking_number' else l.tracking_number end,
      expected_on     = case when r ? 'expected_on' then (r->>'expected_on')::date else l.expected_on end,
      item_id         = case when r ? 'item_id' then (r->>'item_id')::uuid
                             when r ? 'item_key' then (v_items->>(r->>'item_key'))::uuid else l.item_id end
    where l.id = (r->>'id')::uuid and l.order_id = v_order;
    if not found then
      raise exception 'kount_ot_apply_document: line % is not on this order', r->>'id';
    end if;
  end loop;

  -- 4. new lines, after the order's existing ones
  select coalesce(max(l.sort) + 1, 0) into v_sort from public.kount_ot_lines l where l.order_id = v_order;
  insert into public.kount_ot_lines (order_id, item_id, description, sku, qty, unit, unit_price, status, status_source, status_note,
                                     quote_number, invoice_number, invoice_date, tracking_number, expected_on, sort)
  select v_order,
         coalesce(nullif(o.x->>'item_id', '')::uuid, (v_items->>(o.x->>'item_key'))::uuid),
         o.x->>'description', nullif(o.x->>'sku', ''), (o.x->>'qty')::numeric, nullif(o.x->>'unit', ''), nullif(o.x->>'unit_price', '')::numeric,
         o.x->>'status', 'document', v_note,
         nullif(o.x->>'quote_number', ''), nullif(o.x->>'invoice_number', ''), nullif(o.x->>'invoice_date', '')::date,
         nullif(o.x->>'tracking_number', ''), nullif(o.x->>'expected_on', '')::date,
         v_sort + (o.n::integer - 1)
  from jsonb_array_elements(coalesce(p->'new_lines', '[]'::jsonb)) with ordinality as o(x, n);

  -- 5. the document row (its PDF is already in the bucket)
  insert into public.kount_ot_documents (id, order_id, kind, doc_number, doc_date, vendor_name, total, file_name, storage_path, parsed,
                                         source_message_id, source_conversation_id)
  values ((p->'document'->>'id')::uuid, v_order, p->'document'->>'kind', nullif(p->'document'->>'doc_number', ''),
          nullif(p->'document'->>'doc_date', '')::date, nullif(p->'document'->>'vendor_name', ''),
          nullif(p->'document'->>'total', '')::numeric, nullif(p->'document'->>'file_name', ''),
          nullif(p->'document'->>'storage_path', ''), p->'document'->'parsed',
          nullif(p->'document'->>'source_message_id', ''), nullif(p->'document'->>'source_conversation_id', ''));

  -- 6. a document from the morning mail pull: its inbox row is done, in the same transaction
  if nullif(p->>'inbox_id', '') is not null then
    update public.kount_ot_inbox set state = 'applied', order_id = v_order,
           decision = coalesce(nullif(p->>'decision', ''), decision),
           decided_by = coalesce(auth.jwt() ->> 'email', 'morning mail pull')
     where id = (p->>'inbox_id')::uuid and state <> 'applied';
    if not found then
      raise exception 'This document was already saved' using errcode = '23505';
    end if;
  end if;
  return v_order;
end
$fn$;
revoke all on function public.kount_ot_apply_document(jsonb) from public, anon;
grant execute on function public.kount_ot_apply_document(jsonb) to authenticated, service_role;

-- ── 9am Pacific, every day (both PDT and PST hours; the function checks LA time) ──
do $$
begin
  if exists (select 1 from cron.job where jobname = 'kount-order-mail-morning') then
    perform cron.unschedule('kount-order-mail-morning');
  end if;
end $$;
select cron.schedule('kount-order-mail-morning', '*/10 16,17 * * *', $cmd$
  select net.http_post(
    url := 'https://mnraeesscqsaappkaldb.supabase.co/functions/v1/kount-order-mail',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-kount-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'kount_order_mail_cron')),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 10000)
$cmd$);

commit;
