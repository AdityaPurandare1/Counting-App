-- =============================================================================
--  0132_kount_order_tracker   (TABLES + STORAGE)
--
--  The admin "Order tracker" tab (Counting-Admin v0.79, Purchasing section):
--  orders for custom / OS&E items (to-go bags, napkins, glassware...) through
--  the same line lifecycle the desktop Order Tracker used --
--    QUOTED -> ORDERED -> CONFIRMED -> IN_PRODUCTION -> SHIPPED -> DELIVERED
--    -> INVOICED -> PAID   (CANCELLED ends a line early)
--  -- plus warehouse stock for the items it tracks: a delivered order is
--  RECEIVED into stock, venues draw it down through RELEASES (e.g. 3-4 cases of
--  Delilah to-go bags a month), and a COUNT resets on-hand to what was counted.
--  Quote / confirmation / invoice / shipping PDFs are read by the
--  kount-read-purchase-doc Edge Function and kept in the private
--  'kount-order-docs' bucket. The "Order prices" tab reads the same lines.
--
--  ACCESS: admin + corporate only, everywhere (UI route, these policies, the
--  bucket, the Edge Function). kount_is_corporate() is the gate, compared with
--  `is true` so a NULL can never let a row through.
--
--  Kount-owned tables only (kount_ prefix); nothing references KevaOS tables.
--  Venue columns hold the counting venue id ('v1'...) as free text.
--
--  ROLLBACK: 0132_ROLLBACK_kount_order_tracker.sql (drops all of it, data too).
-- =============================================================================
begin;

-- ── items the tracker knows (catalog of custom / OS&E products) ──────────────
create table if not exists public.kount_ot_items (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(btrim(name)) > 0),
  sku             text,
  vendor_name     text,
  category        text,
  -- what one unit of qty means on orders and in stock: case, each, box, roll...
  unit            text not null default 'case',
  -- pieces per unit (e.g. 250 bags per case) -- informational, for case prices
  pack_size       numeric check (pack_size is null or pack_size > 0),
  lead_time_days  integer check (lead_time_days is null or lead_time_days >= 0),
  -- reorder when on-hand falls to this many units (optional; else lead-time based)
  reorder_point   numeric check (reorder_point is null or reorder_point >= 0),
  track_stock     boolean not null default true,
  notes           text,
  is_active       boolean not null default true,
  created_by      text default (auth.jwt() ->> 'email'),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index if not exists kount_ot_items_name_sku_uq
  on public.kount_ot_items (lower(btrim(name)), coalesce(lower(btrim(sku)), '')) where is_active;

-- ── orders (one per PO / vendor order) ──────────────────────────────────────
create table if not exists public.kount_ot_orders (
  id            uuid primary key default gen_random_uuid(),
  order_number  text,
  vendor_name   text not null check (length(btrim(vendor_name)) > 0),
  venue_id      text,          -- counting venue the order is for, if one
  deliver_to    text not null default 'warehouse' check (deliver_to in ('warehouse', 'venue')),
  ordered_on    date,
  expected_on   date,
  notes         text,
  completed_at  timestamptz,   -- a real order that is finished
  archived_at   timestamptz,   -- never a real order (test, duplicate)
  created_by    text default (auth.jwt() ->> 'email'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists kount_ot_orders_number_idx on public.kount_ot_orders (lower(order_number));
create index if not exists kount_ot_orders_vendor_idx on public.kount_ot_orders (lower(vendor_name));

-- ── order lines: THE unit that carries lifecycle status ─────────────────────
create table if not exists public.kount_ot_lines (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.kount_ot_orders (id) on delete cascade,
  item_id          uuid references public.kount_ot_items (id) on delete set null,
  description      text not null check (length(btrim(description)) > 0),
  sku              text,
  qty              numeric not null default 0 check (qty >= 0),
  unit             text,
  unit_price       numeric check (unit_price is null or unit_price >= 0),
  status           text not null default 'ORDERED' check (status in
                     ('QUOTED', 'ORDERED', 'CONFIRMED', 'IN_PRODUCTION', 'SHIPPED', 'DELIVERED', 'INVOICED', 'PAID', 'CANCELLED')),
  status_at        timestamptz not null default now(),
  -- how the latest status change happened; copied into kount_ot_events by the trigger
  status_source    text not null default 'manual' check (status_source in ('manual', 'document')),
  status_note      text,
  quote_number     text,
  invoice_number   text,
  invoice_date     date,
  tracking_number  text,
  expected_on      date,
  sort             integer not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists kount_ot_lines_order_idx on public.kount_ot_lines (order_id);
create index if not exists kount_ot_lines_item_idx on public.kount_ot_lines (item_id);
create index if not exists kount_ot_lines_invoice_idx on public.kount_ot_lines (lower(invoice_number)) where invoice_number is not null;

-- ── audit trail of status changes (written ONLY by the trigger below) ───────
create table if not exists public.kount_ot_events (
  id           bigint generated always as identity primary key,
  -- set null, not cascade: removing a line or an order must not erase its trail
  order_id     uuid references public.kount_ot_orders (id) on delete set null,
  line_id      uuid references public.kount_ot_lines (id) on delete set null,
  from_status  text,
  to_status    text not null,
  source       text not null default 'manual',
  note         text,
  by_email     text,
  at           timestamptz not null default now()
);
create index if not exists kount_ot_events_line_idx on public.kount_ot_events (line_id, at);
create index if not exists kount_ot_events_order_idx on public.kount_ot_events (order_id, at);

-- ── documents (quotes, confirmations, invoices, shipping notices) ───────────
create table if not exists public.kount_ot_documents (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid references public.kount_ot_orders (id) on delete set null,
  kind          text not null check (kind in ('quote', 'confirmation', 'invoice', 'shipping', 'other')),
  doc_number    text,
  doc_date      date,
  vendor_name   text,
  total         numeric,
  file_name     text,
  storage_path  text,
  parsed        jsonb,
  uploaded_by   text default (auth.jwt() ->> 'email'),
  created_at    timestamptz not null default now()
);
create index if not exists kount_ot_documents_order_idx on public.kount_ot_documents (order_id);

-- ── warehouse stock movements ───────────────────────────────────────────────
--   receipt  +qty  (a delivered line, line_id set)
--   release  -qty  (sent to a venue, venue_id set)
--   count    =qty  (on-hand counted; later moves apply on top of it)
create table if not exists public.kount_ot_stock_moves (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references public.kount_ot_items (id) on delete cascade,
  moved_on    date not null default current_date,
  kind        text not null check (kind in ('receipt', 'release', 'count')),
  qty         numeric not null check (qty >= 0),
  venue_id    text,
  line_id     uuid references public.kount_ot_lines (id) on delete set null,
  note        text,
  created_by  text default (auth.jwt() ->> 'email'),
  created_at  timestamptz not null default now()
);
create index if not exists kount_ot_stock_moves_item_idx on public.kount_ot_stock_moves (item_id, moved_on);
create index if not exists kount_ot_stock_moves_line_idx on public.kount_ot_stock_moves (line_id) where line_id is not null;

-- ── triggers ────────────────────────────────────────────────────────────────
create or replace function public.kount_ot_touch()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $fn$
begin
  new.updated_at := now();
  return new;
end
$fn$;

create or replace function public.kount_ot_line_status_stamp()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $fn$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.status_at := now();
  end if;
  return new;
end
$fn$;

-- SECURITY DEFINER so the audit row is written even though clients have no
-- INSERT on kount_ot_events -- the trail cannot be forged or edited from the app.
create or replace function public.kount_ot_line_status_event()
returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.kount_ot_events (order_id, line_id, from_status, to_status, source, note, by_email)
    values (new.order_id, new.id, case when tg_op = 'UPDATE' then old.status end, new.status,
            coalesce(new.status_source, 'manual'), new.status_note, auth.jwt() ->> 'email');
  end if;
  return null;
end
$fn$;
revoke all on function public.kount_ot_line_status_event() from public, anon, authenticated;

-- who created a row comes from the caller's login, not from what the browser sends
create or replace function public.kount_ot_stamp_creator()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $fn$
declare v_email text := auth.jwt() ->> 'email';
begin
  if v_email is not null then
    if tg_table_name = 'kount_ot_documents' then new.uploaded_by := v_email; else new.created_by := v_email; end if;
  end if;
  return new;
end
$fn$;

drop trigger if exists kount_ot_items_touch on public.kount_ot_items;
create trigger kount_ot_items_touch before update on public.kount_ot_items
  for each row execute function public.kount_ot_touch();
drop trigger if exists kount_ot_orders_touch on public.kount_ot_orders;
create trigger kount_ot_orders_touch before update on public.kount_ot_orders
  for each row execute function public.kount_ot_touch();
drop trigger if exists kount_ot_lines_touch on public.kount_ot_lines;
create trigger kount_ot_lines_touch before update on public.kount_ot_lines
  for each row execute function public.kount_ot_touch();
drop trigger if exists kount_ot_lines_stamp on public.kount_ot_lines;
create trigger kount_ot_lines_stamp before update on public.kount_ot_lines
  for each row execute function public.kount_ot_line_status_stamp();
drop trigger if exists kount_ot_lines_event on public.kount_ot_lines;
create trigger kount_ot_lines_event after insert or update of status on public.kount_ot_lines
  for each row execute function public.kount_ot_line_status_event();
do $$
declare t text;
begin
  foreach t in array array['kount_ot_items', 'kount_ot_orders', 'kount_ot_documents', 'kount_ot_stock_moves'] loop
    -- format args: (trigger name, table name)
    execute format('drop trigger if exists %I on public.%I', t || '_stamp_creator', t);
    execute format('create trigger %I before insert on public.%I for each row execute function public.kount_ot_stamp_creator()', t || '_stamp_creator', t);
  end loop;
end $$;

-- ── access: admin + corporate only ──────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['kount_ot_items', 'kount_ot_orders', 'kount_ot_lines', 'kount_ot_documents', 'kount_ot_stock_moves'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on table public.%I to authenticated', t);
    -- format args: (policy name, table name) -- in that order
    execute format('drop policy if exists %I on public.%I', t || '_corporate', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.kount_is_corporate() is true) with check (public.kount_is_corporate() is true)',
                   t || '_corporate', t);
  end loop;
end $$;

-- the audit trail: read-only to the app
alter table public.kount_ot_events enable row level security;
revoke all on table public.kount_ot_events from public, anon, authenticated;
grant select on table public.kount_ot_events to authenticated;
drop policy if exists kount_ot_events_corporate_read on public.kount_ot_events;
create policy kount_ot_events_corporate_read on public.kount_ot_events
  for select to authenticated using (public.kount_is_corporate() is true);

-- ── apply a reviewed document in ONE transaction ────────────────────────────
-- The document review used to write order -> items -> lines -> PDF row as
-- separate calls; a failure part-way left lines applied with Save still
-- enabled, so a retry created a second order and counted the invoice twice.
-- Now the PDF is uploaded first (docs/<document id>.pdf, independent of the
-- order) and this function does everything else atomically. The document id
-- is fixed per review, so re-sending a document that already saved is refused.
-- SECURITY INVOKER: the caller's own RLS applies (admin + corporate only).
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
  if public.kount_is_corporate() is not true then
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
  insert into public.kount_ot_documents (id, order_id, kind, doc_number, doc_date, vendor_name, total, file_name, storage_path, parsed)
  values ((p->'document'->>'id')::uuid, v_order, p->'document'->>'kind', nullif(p->'document'->>'doc_number', ''),
          nullif(p->'document'->>'doc_date', '')::date, nullif(p->'document'->>'vendor_name', ''),
          nullif(p->'document'->>'total', '')::numeric, nullif(p->'document'->>'file_name', ''),
          nullif(p->'document'->>'storage_path', ''), p->'document'->'parsed');
  return v_order;
end
$fn$;
revoke all on function public.kount_ot_apply_document(jsonb) from public, anon;
grant execute on function public.kount_ot_apply_document(jsonb) to authenticated;

-- ── private bucket for the documents ────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kount-order-docs', 'kount-order-docs', false, 20971520, array['application/pdf', 'image/png', 'image/jpeg'])
on conflict (id) do nothing;

drop policy if exists kount_order_docs_read on storage.objects;
create policy kount_order_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'kount-order-docs' and public.kount_is_corporate() is true);
drop policy if exists kount_order_docs_write on storage.objects;
create policy kount_order_docs_write on storage.objects for insert to authenticated
  with check (bucket_id = 'kount-order-docs' and public.kount_is_corporate() is true);
drop policy if exists kount_order_docs_update on storage.objects;
create policy kount_order_docs_update on storage.objects for update to authenticated
  using (bucket_id = 'kount-order-docs' and public.kount_is_corporate() is true)
  with check (bucket_id = 'kount-order-docs' and public.kount_is_corporate() is true);
drop policy if exists kount_order_docs_delete on storage.objects;
create policy kount_order_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'kount-order-docs' and public.kount_is_corporate() is true);

commit;

-- -----------------------------------------------------------------------------
--  VERIFY (rolled back): a manager reads 0 rows and cannot insert; an admin can;
--  a status change writes one kount_ot_events row; anon has no table grants.
-- -----------------------------------------------------------------------------
