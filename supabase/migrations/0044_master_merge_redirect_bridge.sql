-- 0044_master_merge_redirect_bridge
--
-- Goal (per request): keep R365 / purchase_items pointing at the bare masters,
-- but let those bare (now-archived, folded) masters REDIRECT to their active
-- canonical twin — instead of overwriting purchase_items.master_item_id (which
-- the next R365 sync could undo and which mutates a shared FK KevaOS relies on).
--
-- Design: add master_items.merged_into_id (a tombstone/alias pointer). For each
-- archived master that was folded during dedup, point it at the active canonical
-- master with the same canonical-key (name w/ size stripped) + same size-in-ml.
-- v_effective_receipts then resolves purchases through the redirect, so a purchase
-- routed to a dead twin lands on the live master the counts use.
--
-- Safety: additive nullable column; only archived rows get a value; targets are
-- always active (no chains/cycles). Existing FKs untouched. Re-runnable (idempotent).
-- ROLLBACK: update master_items set merged_into_id=null;  (+ restore 0043 view)

-- 1. the redirect column
alter table master_items add column if not exists merged_into_id uuid references master_items(id);

-- 2. auto-populate: archived -> unique active twin by (canonical-key, size-in-ml)
with norm as (
  select id, is_active,
    btrim(regexp_replace(regexp_replace(lower(name),
      '\y\d+(\.\d+)?\s*(ml|l|lt|liter|cl|fl\.?\s*oz|oz|gal|qt|each|pk|pack|can|btl|bottle|ct)\y','','g'),
      '[^a-z0-9]+',' ','g')) ckey,
    round((case lower(coalesce(base_unit,'ml'))
      when 'l' then base_size*1000 when 'lt' then base_size*1000 when 'liter' then base_size*1000
      when 'gal' then base_size*3785.41 when 'oz' then base_size*29.5735
      when 'floz' then base_size*29.5735 when 'cl' then base_size*10 when 'qt' then base_size*946.35
      else base_size end)::numeric) ml
  from master_items
),
active_by_key as (
  select ckey, ml, count(*) n, (array_agg(id))[1] tgt
  from norm where is_active and ckey <> '' group by ckey, ml
)
update master_items m
set merged_into_id = ak.tgt
from norm a
join active_by_key ak on ak.ckey = a.ckey and ak.ml is not distinct from a.ml
where m.id = a.id
  and a.is_active = false
  and ak.n = 1            -- exactly one active twin -> unambiguous
  and ak.tgt <> m.id
  and m.merged_into_id is null;

-- 3. explicit exceptions (canonical name/word-order differs, so ckey wouldn't match)
update master_items m set merged_into_id = t.id
from master_items t
where m.is_active = false and m.merged_into_id is null and t.is_active
  and (
    (m.name = 'Estrella'                    and t.name = 'Estrella - Bev 12fl.oz') or
    (m.name = 'Dom Perignon Brut Luminous'  and t.name = 'Dom Perignon, ''Luminous Brut'', Champagne') or
    (m.name = 'Red Bull Sugar Free'         and t.name = 'Red Bull Sugar Free 1each') or
    (m.name = 'BIB - Orange Juice'          and t.name = 'BIB - Orange Juice 2.5gal') or
    (m.name = 'BIB - Cranberry'             and t.name = 'BIB - Cranberry 90oz')
  );

-- 4. teach the receipts view to follow the redirect (else keep raw resolved master)
create or replace view public.v_effective_receipts as
 select il.id as invoice_line_id,
    il.invoice_id,
    coalesce(redir.merged_into_id, coalesce(il.master_item_id, pi.master_item_id)) as master_item_id,
    il.item_id as purchase_item_id,
    il.description,
    coalesce(rel.received_qty, il.qty) as effective_qty,
    coalesce(rel.received_uom, pi.base_uom, mi.base_unit) as effective_uom,
    coalesce(rel.unit_cost, il.unit_cost) as effective_unit_cost,
    il.qty as billed_qty,
    il.unit_cost as billed_unit_cost,
    rel.variance_qty,
    rel.variance_pct,
    rel.damaged_qty,
    rel.rejected,
    rel.net_qty,
    rel.id as receiving_event_line_id,
    re.received_at,
    re.status as receiving_status
   from invoice_lines il
     left join receiving_event_lines rel on rel.source_line_type = 'invoice_line'::text and rel.source_line_id = il.id
     left join receiving_events re on re.id = rel.receiving_event_id and re.status <> 'voided'::text
     left join master_items mi on mi.id = il.master_item_id
     left join purchase_items pi on pi.id = il.item_id
     left join master_items redir on redir.id = coalesce(il.master_item_id, pi.master_item_id);
