-- ROLLBACK for 0140_kount_ot_line_venues: kount_ot_apply_document back to 0135's version,
-- line venues dropped (orders keep their own venue; 'x:Multiple venues' orders stay so).
begin;
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
drop index if exists public.kount_ot_lines_venue_idx;
alter table public.kount_ot_lines drop column if exists venue_id;
commit;
