-- =============================================================================
--  0137_kount_ot_lifecycle_tracking   (h.wood's own order cycle + tracking numbers)
--
--  1. The user (2026-11-02): "It will be requested, then ordered, then quoted,
--     then invoiced, then paid, then shipped, then delivered, then received."
--     E&E and the custom vendors are PREPAID — invoiced and paid before they
--     ship. kount_ot_lines.status becomes exactly that cycle:
--       REQUESTED -> ORDERED -> QUOTED -> INVOICED -> PAID -> SHIPPED
--       -> DELIVERED -> RECEIVED        (CANCELLED ends a line early)
--     replacing 0132's QUOTED -> ORDERED -> CONFIRMED -> IN_PRODUCTION ->
--     SHIPPED -> DELIVERED -> INVOICED -> PAID. No line existed yet when this
--     was written (0 orders, 0 lines), so nothing is re-mapped; CONFIRMED and
--     IN_PRODUCTION would become ORDERED.
--  2. kount_ot_tracking: tracking numbers per order, from vendor emails (the
--     morning pull reads E&E's "here's the tracking ..." replies), shipping
--     notices or by hand; kount_ot_add_tracking adds them, moves the order's
--     lines that are not shipped yet to SHIPPED, and closes the inbox row —
--     one transaction. Admin + corporate (and the pull, as the service role).
--  ROLLBACK: 0137_ROLLBACK_kount_ot_lifecycle_tracking.sql
-- =============================================================================
begin;

-- ── 1. the cycle ────────────────────────────────────────────────────────────
alter table public.kount_ot_lines drop constraint if exists kount_ot_lines_status_check;
update public.kount_ot_lines set status = 'ORDERED' where status in ('CONFIRMED', 'IN_PRODUCTION');
alter table public.kount_ot_lines add constraint kount_ot_lines_status_check check (status in
  ('REQUESTED', 'ORDERED', 'QUOTED', 'INVOICED', 'PAID', 'SHIPPED', 'DELIVERED', 'RECEIVED', 'CANCELLED'));
alter table public.kount_ot_lines alter column status set default 'REQUESTED';

-- ── 2. tracking numbers ─────────────────────────────────────────────────────
create table if not exists public.kount_ot_tracking (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references public.kount_ot_orders (id) on delete cascade,
  tracking_number  text not null check (length(btrim(tracking_number)) > 0),
  carrier          text,
  source           text not null default 'manual' check (source in ('email', 'document', 'manual')),
  message_id       text,
  conversation_id  text,
  note             text,
  created_by       text default (auth.jwt() ->> 'email'),
  created_at       timestamptz not null default now(),
  unique (order_id, tracking_number)
);
create index if not exists kount_ot_tracking_order_idx on public.kount_ot_tracking (order_id);
alter table public.kount_ot_tracking enable row level security;
revoke all on table public.kount_ot_tracking from public, anon, authenticated;
grant select, insert, update, delete on table public.kount_ot_tracking to authenticated;
drop policy if exists kount_ot_tracking_corporate on public.kount_ot_tracking;
create policy kount_ot_tracking_corporate on public.kount_ot_tracking for all to authenticated
  using (public.kount_is_corporate() is true) with check (public.kount_is_corporate() is true);

-- add tracking numbers to an order (and ship its lines) in one transaction
create or replace function public.kount_ot_add_tracking(p jsonb)
returns integer
language plpgsql
security invoker
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_order uuid := nullif(p->>'order_id', '')::uuid;
  v_note  text := coalesce(nullif(p->>'note', ''), 'Tracking from email');
  v_n     integer := 0;
  v_all   text;
  r       jsonb;
begin
  if public.kount_is_corporate() is not true and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'The order tracker is limited to admin and corporate users' using errcode = '42501';
  end if;
  if v_order is null or not exists (select 1 from public.kount_ot_orders o where o.id = v_order and o.archived_at is null) then
    raise exception 'kount_ot_add_tracking: order not found';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p->'numbers', '[]'::jsonb)) loop
    continue when nullif(btrim(r->>'number'), '') is null;
    insert into public.kount_ot_tracking (order_id, tracking_number, carrier, source, message_id, conversation_id, note)
    values (v_order, upper(btrim(r->>'number')), nullif(r->>'carrier', ''), coalesce(nullif(p->>'source', ''), 'email'),
            nullif(p->>'message_id', ''), nullif(p->>'conversation_id', ''), v_note)
    on conflict (order_id, tracking_number) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  -- a tracking number means it shipped: every line not shipped yet moves to SHIPPED (forward only)
  if coalesce((p->>'ship_lines')::boolean, true) then
    update public.kount_ot_lines l set status = 'SHIPPED', status_source = 'document', status_note = v_note
     where l.order_id = v_order and l.status in ('REQUESTED', 'ORDERED', 'QUOTED', 'INVOICED', 'PAID');
  end if;
  select string_agg(t.tracking_number, ', ' order by t.created_at) into v_all from public.kount_ot_tracking t where t.order_id = v_order;
  update public.kount_ot_lines l set tracking_number = left(v_all, 300)
   where l.order_id = v_order and l.tracking_number is null and l.status <> 'CANCELLED';
  if nullif(p->>'inbox_id', '') is not null then
    update public.kount_ot_inbox set state = 'applied', order_id = v_order,
           decision = coalesce(nullif(p->>'decision', ''), decision),
           decided_by = coalesce(auth.jwt() ->> 'email', 'morning mail pull')
     where id = (p->>'inbox_id')::uuid;
  end if;
  return v_n;
end
$fn$;
revoke all on function public.kount_ot_add_tracking(jsonb) from public, anon;
grant execute on function public.kount_ot_add_tracking(jsonb) to authenticated, service_role;

commit;
