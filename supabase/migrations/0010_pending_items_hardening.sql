-- =============================================================================
--  kΩunt — pending items hardening (0010)
-- =============================================================================
--  Two real-world fixes after 0009 shipped:
--
--  1. approve_pending_item failed silently on tenants where purchase_items
--     has organization_id NOT NULL — the original RPC didn't supply it. The
--     UPDATE flipping status='approved' ran in the same plpgsql block as
--     the INSERT, so the txn rolled back and the caller saw a vague error
--     while the pending row still looked untouched. New version supplies
--     organization_id (caller-provided, or auto-pulled from the most-common
--     value in purchase_items as a fallback) and explicitly sets is_active
--     = true to survive a future NOT NULL on that column too. Existing
--     callers that ignore the new optional parameter still work.
--
--  2. Two counters could double-submit the same item name within the same
--     ~50ms window. The pre-flight SELECT-then-INSERT in the phone has no
--     unique constraint to fall back on. Added a unique partial index on
--     lower(name) where status='pending' so the second INSERT loses with
--     a 23505 — phone surfaces "already pending admin approval" via the
--     same dedupe toast it already has.
-- =============================================================================

-- 1. Unique partial index — case-insensitive, only across rows still in flight.
--    Approved + rejected rows are not constrained, so a counter resubmitting
--    a previously-rejected name still works.
create unique index if not exists kount_pending_items_name_pending_uidx
  on public.kount_pending_items (lower(name))
  where status = 'pending';


-- 2. Replace approve_pending_item with the schema-tolerant version.
--    Drop+recreate (vs CREATE OR REPLACE) so a signature change is clean —
--    the new function adds an optional p_organization_id parameter.
drop function if exists public.approve_pending_item(uuid, text, text);

create or replace function public.approve_pending_item(
  p_pending_id     uuid,
  p_admin_email    text,
  p_admin_name     text default null,
  p_organization_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rec    public.kount_pending_items;
  new_id uuid;
  org_id uuid;
  has_org_col   boolean;
  has_active_col boolean;
begin
  -- Step 1: lock + flip the pending row. Only if it's still pending — the
  -- WHERE on status guards against the race where two admins click Approve
  -- on the same row simultaneously.
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

  -- Step 2: figure out the org id. Caller-supplied wins; otherwise pull the
  -- most-common organization_id off existing purchase_items (single-tenant
  -- prod has exactly one value, so this works without configuration).
  org_id := p_organization_id;

  -- Detect schema flexibly so the RPC works on installs that haven't run the
  -- multi-tenant migration yet (older dev DBs may not have organization_id
  -- or is_active on purchase_items at all).
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'purchase_items' and column_name = 'organization_id'
  ) into has_org_col;
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'purchase_items' and column_name = 'is_active'
  ) into has_active_col;

  if has_org_col and org_id is null then
    -- Most-common org id in the catalog. NULLS are excluded so a partially-
    -- backfilled column doesn't poison the heuristic.
    execute $sql$
      select organization_id
        from public.purchase_items
       where organization_id is not null
       group by organization_id
       order by count(*) desc
       limit 1
    $sql$ into org_id;
  end if;

  -- Step 3: mint the catalog row. Build the column list dynamically so we
  -- don't reference columns that may not exist on the live schema.
  if has_org_col and has_active_col then
    insert into public.purchase_items(name, brand, category, subcategory, upc, size, organization_id, is_active)
    values (rec.name, rec.brand, rec.category, rec.subcategory, rec.upc, rec.size, org_id, true)
    returning id into new_id;
  elsif has_org_col then
    insert into public.purchase_items(name, brand, category, subcategory, upc, size, organization_id)
    values (rec.name, rec.brand, rec.category, rec.subcategory, rec.upc, rec.size, org_id)
    returning id into new_id;
  elsif has_active_col then
    insert into public.purchase_items(name, brand, category, subcategory, upc, size, is_active)
    values (rec.name, rec.brand, rec.category, rec.subcategory, rec.upc, rec.size, true)
    returning id into new_id;
  else
    insert into public.purchase_items(name, brand, category, subcategory, upc, size)
    values (rec.name, rec.brand, rec.category, rec.subcategory, rec.upc, rec.size)
    returning id into new_id;
  end if;

  -- Step 4: link the pending row back to the new catalog row.
  update public.kount_pending_items
     set purchase_item_id = new_id
   where id = p_pending_id;

  return jsonb_build_object(
    'ok',                true,
    'pending_id',        rec.id,
    'purchase_item_id',  new_id,
    'organization_id',   org_id
  );
end;
$$;

grant execute on function public.approve_pending_item(uuid, text, text, uuid) to anon;


-- 3. Sanity probes (run after apply):
--   select indexname from pg_indexes
--    where schemaname='public' and tablename='kount_pending_items';
--   -- should list kount_pending_items_name_pending_uidx
--
--   select organization_id, count(*) from public.purchase_items
--    group by 1 order by count(*) desc;
--   -- single-tenant prod should see exactly one org_id row
--
--   select pg_get_function_identity_arguments(oid) from pg_proc
--    where proname = 'approve_pending_item';
--   -- should now read: p_pending_id uuid, p_admin_email text, p_admin_name text, p_organization_id uuid
