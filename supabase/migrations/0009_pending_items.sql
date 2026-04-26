-- =============================================================================
--  kΩunt — pending items submitted by counters/managers (0009)
-- =============================================================================
--  Mirrors the upc_mappings approval flow but for *new catalog items*. A
--  counter on the floor finds a bottle that isn't in purchase_items and
--  needs to log it; instead of dead-ending into a CUSxxx localStorage row
--  that never reaches admin, they submit a pending row here. Admin (or
--  manager) then approves — which triggers a real purchase_items insert
--  and links the pending row back via purchase_item_id — or rejects with
--  an optional reason.
--
--  Status lifecycle:
--    pending  → approved   (mints purchase_items row, fills purchase_item_id)
--    pending  → rejected   (no purchase_items insert, reason captured)
--
--  Counters can read their own submissions; admin/manager can review all.
--  Permissive dev RLS matches the rest of this app's tables.
-- =============================================================================

create table if not exists public.kount_pending_items (
  id            uuid primary key default gen_random_uuid(),
  name          text  not null,
  brand         text,
  category      text,
  subcategory   text,
  size          text,
  upc           text,
  notes         text,

  submitted_by_email text not null,
  submitted_by_name  text,
  submitted_at       timestamptz not null default now(),

  -- Optional context: the audit a counter was running when they hit the gap.
  -- Helps the admin understand "why is this here" without hunting through logs.
  audit_id      uuid references public.kount_audits(id) on delete set null,

  status        text not null default 'pending'
                check (status in ('pending', 'approved', 'rejected')),

  reviewed_by_email text,
  reviewed_by_name  text,
  reviewed_at       timestamptz,
  reject_reason     text,

  -- Set on approval — the purchase_items row that was minted from this submission.
  purchase_item_id  uuid references public.purchase_items(id) on delete set null
);

create index if not exists kount_pending_items_status_idx
  on public.kount_pending_items (status, submitted_at desc);
create index if not exists kount_pending_items_submitter_idx
  on public.kount_pending_items (submitted_by_email);
create index if not exists kount_pending_items_audit_idx
  on public.kount_pending_items (audit_id);

-- Realtime so the admin Approvals screen + phone notifications update live.
do $$ begin
  begin execute 'alter publication supabase_realtime add table public.kount_pending_items';
  exception when duplicate_object then null; end;
end $$;

alter table public.kount_pending_items enable row level security;

-- Permissive dev RLS — rotate when we tighten the rest of the app.
drop policy if exists "kount_pending_items open select" on public.kount_pending_items;
create policy "kount_pending_items open select"
  on public.kount_pending_items for select using (true);

drop policy if exists "kount_pending_items open insert" on public.kount_pending_items;
create policy "kount_pending_items open insert"
  on public.kount_pending_items for insert with check (true);

drop policy if exists "kount_pending_items open update" on public.kount_pending_items;
create policy "kount_pending_items open update"
  on public.kount_pending_items for update using (true);


-- -----------------------------------------------------------------------------
-- approve_pending_item(p_pending_id, p_admin_email, p_admin_name)
--   Flips the row to 'approved', mints a purchase_items row from the pending
--   data, and back-fills purchase_item_id. Returns the new purchase_items.id
--   on success so the caller can link it into upc_mappings if needed.
-- -----------------------------------------------------------------------------
create or replace function public.approve_pending_item(
  p_pending_id uuid,
  p_admin_email text,
  p_admin_name  text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.kount_pending_items;
  new_id uuid;
begin
  update public.kount_pending_items
     set status            = 'approved',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now()
   where id     = p_pending_id
     and status = 'pending'
  returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Pending item not found or already finalized');
  end if;

  -- Mint the catalog row. Leave is_active default and let the admin curate
  -- carried separately via kount_carried_items (the existing flow).
  insert into public.purchase_items(name, brand, category, subcategory, upc, size)
  values (rec.name, rec.brand, rec.category, rec.subcategory, rec.upc, rec.size)
  returning id into new_id;

  update public.kount_pending_items
     set purchase_item_id = new_id
   where id = p_pending_id;

  return jsonb_build_object('ok', true, 'pending_id', rec.id, 'purchase_item_id', new_id);
end;
$$;


-- -----------------------------------------------------------------------------
-- reject_pending_item(p_pending_id, p_admin_email, p_admin_name, p_reason)
-- -----------------------------------------------------------------------------
create or replace function public.reject_pending_item(
  p_pending_id uuid,
  p_admin_email text,
  p_admin_name  text default null,
  p_reason      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.kount_pending_items;
begin
  update public.kount_pending_items
     set status            = 'rejected',
         reviewed_by_email = p_admin_email,
         reviewed_by_name  = coalesce(p_admin_name, p_admin_email),
         reviewed_at       = now(),
         reject_reason     = p_reason
   where id     = p_pending_id
     and status = 'pending'
  returning * into rec;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Pending item not found or already finalized');
  end if;

  return jsonb_build_object('ok', true, 'pending_id', rec.id);
end;
$$;


grant execute on function public.approve_pending_item(uuid, text, text)        to anon;
grant execute on function public.reject_pending_item(uuid, text, text, text)   to anon;


-- -----------------------------------------------------------------------------
-- Verification queries (run after apply):
--   select count(*) from public.kount_pending_items;
--   select * from pg_proc where proname in ('approve_pending_item','reject_pending_item');
-- -----------------------------------------------------------------------------
