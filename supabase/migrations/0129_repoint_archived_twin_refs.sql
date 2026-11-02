-- =============================================================================
--  0129_repoint_archived_twin_refs   (DATA, shared; RESUMABLE, run until 0 left)
--
--  2026-11-02. 1,207 products have a live newer row while their archived
--  same-name twin (merged_into_id -> the live row) still holds the purchase
--  lines, prices and KevaOS movements (an earlier merge archived both sides
--  and left the data on the dead side). compute_avt prices by the live row,
--  so recomputing Poppy/Alphabet reports today drops ~40% of inventory value.
--
--  For each such pair this runs KevaOS's own merge routine
--  repoint_master_refs(dead, survivor) (purchase_items, invoice_lines,
--  menu_item_recipe_map, recipe_items, procurement_movements + balances,
--  pour overrides, venue_item_settings) and moves the Kount rows it doesn't
--  cover (venue prices, barcodes, carried list, venue catalog, entries).
--
--  Batched: each run handles up to 20 pairs that still have rows on the
--  dead side, inside one transaction, and prints how many pairs remain.
--  Re-run until 'pairs_remaining' is 0. Every repoint is logged in
--  master_item_merge_repoints (reason '0129') and _mig0129_kount_repoints.
--  ROLLBACK: 0129_ROLLBACK_repoint_archived_twin_refs.sql (Kount rows + the
--            KevaOS rows via the repoint log).
-- =============================================================================
begin;

create table if not exists public._mig0129_kount_repoints (id bigserial primary key, table_name text, row_key text, old_master uuid, new_master uuid);
create table if not exists public._mig0129_pairs (low_id uuid primary key, canon_id uuid not null, done_at timestamptz);
alter table public._mig0129_kount_repoints enable row level security;
alter table public._mig0129_pairs enable row level security;
revoke all on public._mig0129_kount_repoints, public._mig0129_pairs from anon, authenticated;

insert into public._mig0129_pairs (low_id, canon_id)
select l.id, c.id
  from public.master_items l join public.master_items c on c.id = l.merged_into_id
 where not l.is_active and c.is_active and lower(l.name) = lower(c.name) and l.id <> c.id
on conflict (low_id) do nothing;

create temp table _batch on commit drop as
  select p.low_id, p.canon_id from public._mig0129_pairs p
   where p.done_at is null
     and (exists (select 1 from public.purchase_items x where x.master_item_id = p.low_id)
       or exists (select 1 from public.invoice_lines x where x.master_item_id = p.low_id)
       or exists (select 1 from public.procurement_movements x where x.master_item_id = p.low_id)
       or exists (select 1 from public.procurement_theoretical_balances x where x.master_item_id = p.low_id)
       or exists (select 1 from public.kount_venue_cost_overrides x where x.master_item_id = p.low_id)
       or exists (select 1 from public.master_item_upcs x where x.master_item_id = p.low_id)
       or exists (select 1 from public.kount_carried_items x where x.master_item_id = p.low_id)
       or exists (select 1 from public.kount_venue_catalog x where x.master_item_id = p.low_id)
       or exists (select 1 from public.kount_entries x where x.master_item_id = p.low_id)
       or exists (select 1 from public.venue_item_settings x where x.master_item_id = p.low_id))
   order by p.low_id limit 20;

-- Kount rows first (keyed uniqueness handled: move when the survivor lacks one, else drop the dead side's).
insert into public._mig0129_kount_repoints (table_name, row_key, old_master, new_master)
select 'kount_venue_cost_overrides', o.venue_id, b.low_id, b.canon_id from public.kount_venue_cost_overrides o join _batch b on b.low_id = o.master_item_id
 where not exists (select 1 from public.kount_venue_cost_overrides k where k.venue_id = o.venue_id and k.master_item_id = b.canon_id);
update public.kount_venue_cost_overrides o set master_item_id = b.canon_id from _batch b
 where b.low_id = o.master_item_id and not exists (select 1 from public.kount_venue_cost_overrides k where k.venue_id = o.venue_id and k.master_item_id = b.canon_id);
delete from public.kount_venue_cost_overrides o using _batch b where b.low_id = o.master_item_id;

insert into public._mig0129_kount_repoints (table_name, row_key, old_master, new_master)
select 'master_item_upcs', x.upc_normalized, b.low_id, b.canon_id from public.master_item_upcs x join _batch b on b.low_id = x.master_item_id;
update public.master_item_upcs x set master_item_id = b.canon_id, notes = coalesce(x.notes || ' | ', '') || '0129: moved from archived twin'
  from _batch b where b.low_id = x.master_item_id;

insert into public._mig0129_kount_repoints (table_name, row_key, old_master, new_master)
select 'kount_carried_items', ci.id::text, b.low_id, b.canon_id from public.kount_carried_items ci join _batch b on b.low_id = ci.master_item_id
 where not exists (select 1 from public.kount_carried_items k where k.master_item_id = b.canon_id);
update public.kount_carried_items ci set master_item_id = b.canon_id from _batch b
 where b.low_id = ci.master_item_id and not exists (select 1 from public.kount_carried_items k where k.master_item_id = b.canon_id);
delete from public.kount_carried_items ci using _batch b where b.low_id = ci.master_item_id;

insert into public._mig0129_kount_repoints (table_name, row_key, old_master, new_master)
select 'kount_venue_catalog', v.venue_id, b.low_id, b.canon_id from public.kount_venue_catalog v join _batch b on b.low_id = v.master_item_id
 where not exists (select 1 from public.kount_venue_catalog k where k.venue_id = v.venue_id and k.master_item_id = b.canon_id);
update public.kount_venue_catalog v set master_item_id = b.canon_id from _batch b
 where b.low_id = v.master_item_id and not exists (select 1 from public.kount_venue_catalog k where k.venue_id = v.venue_id and k.master_item_id = b.canon_id);
delete from public.kount_venue_catalog v using _batch b where b.low_id = v.master_item_id;

insert into public._mig0129_kount_repoints (table_name, row_key, old_master, new_master)
select 'kount_entries', e.id::text, b.low_id, b.canon_id from public.kount_entries e join _batch b on b.low_id = e.master_item_id;
update public.kount_entries e set master_item_id = b.canon_id from _batch b where b.low_id = e.master_item_id;

-- KevaOS rows via the sanctioned routine.
do $$
declare r record; n int;
begin
  for r in select low_id, canon_id from _batch loop
    n := public.repoint_master_refs(r.low_id, r.canon_id, '0129');
  end loop;
end $$;

update public._mig0129_pairs p set done_at = now() from _batch b where b.low_id = p.low_id;

select (select count(*) from _batch) as pairs_this_run,
       (select count(*) from public._mig0129_pairs where done_at is null
          and (exists (select 1 from public.purchase_items x where x.master_item_id = low_id)
            or exists (select 1 from public.invoice_lines x where x.master_item_id = low_id)
            or exists (select 1 from public.procurement_movements x where x.master_item_id = low_id)
            or exists (select 1 from public.kount_venue_cost_overrides x where x.master_item_id = low_id)
            or exists (select 1 from public.master_item_upcs x where x.master_item_id = low_id))) as pairs_remaining,
       (select count(*) from public.master_item_merge_repoints where reason = '0129') as kevaos_rows_repointed_total,
       (select count(*) from public._mig0129_kount_repoints) as kount_rows_repointed_total;
commit;
