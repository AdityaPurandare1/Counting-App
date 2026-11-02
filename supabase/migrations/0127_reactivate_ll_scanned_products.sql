-- =============================================================================
--  0127_reactivate_ll_scanned_products   (DATA, shared catalog)
--
--  2026-11-02, Little Luck live count LL-342, at Aditya's request. 39 bottles
--  the counters scanned exist in the catalog only as rows archived on
--  2026-04-14 whose merged_into_id leads nowhere live (dead end or loop), so
--  the phone (which hides archived items) read every scan as unknown, the
--  counter typed the name, and 45 LL-342 entries ended up tied to no catalog
--  item. The barcodes still point at those archived rows.
--
--  1. Reactivates the 39 (is_active true, merged_into_id cleared) and fills
--     base_size/base_unit from the size in the name where missing, so the
--     variance can treat them as bottles. Originals kept in
--     _mig0127_reactivated.
--  2. Ties LL-342 barcode entries that have no master to the active item the
--     barcode now resolves to. Originals in _mig0127_entry_links.
--  3. 8 barcodes filed under one archived product but scanned by the counter
--     as another, live product: moved to the counter's choice ("trust the
--     scan"). Originals in _mig0127_upc_repoint. One of the 8, 81753837815
--     (filed under the archived Belvedere 1L), was scanned as BOTH "Belvedere
--     (Generic) (L)" and "BELVEDERE ORGANIC VODKA LT", so it is left alone
--     for someone to check the bottle: 7 move.
--  4. Pending barcode links from today whose item is live are approved.
--  ROLLBACK: 0127_ROLLBACK_reactivate_ll_scanned_products.sql
-- =============================================================================
begin;

create table if not exists public._mig0127_reactivated (
  id uuid primary key, prev_merged_into uuid, prev_base_size numeric, prev_base_unit text, prev_updated_at timestamptz);
create table if not exists public._mig0127_entry_links (entry_id uuid primary key, master_item_id uuid not null);
create table if not exists public._mig0127_upc_repoint (upc_normalized text primary key, old_master uuid not null, new_master uuid not null);
alter table public._mig0127_reactivated enable row level security;
alter table public._mig0127_entry_links enable row level security;
alter table public._mig0127_upc_repoint enable row level security;
revoke all on public._mig0127_reactivated, public._mig0127_entry_links, public._mig0127_upc_repoint from anon, authenticated;

-- 1. Reactivate the archived owners of the 39 scanned barcodes.
with codes as (select unnest(array[
  '195893031092','195893154296','649188900483','674545000001','674545000322','674545000414','721059002387',
  '7502234420324','7502234420331','787269005006','80686813019','80686935230','80686957119','80686958055',
  '811538013628','816136021556','816136027909','81753810849','81753829414','818844022856','850008649011',
  '850008649035','850033013207','850057569223','85156610419','852322824082','85246139424','857932007009',
  '860001753493','860006713454','86891054001','87229127381','87236565008','87236701109','87236950927',
  '88110070052','88110110307','88110140052','898563002629']) as norm),
owners as (
  select distinct m.id, m.merged_into_id, m.base_size, m.base_unit, m.updated_at, m.name
    from codes c join public.master_item_upcs x on x.upc_normalized = c.norm
    join public.master_items m on m.id = x.master_item_id
   where not m.is_active
)
insert into public._mig0127_reactivated (id, prev_merged_into, prev_base_size, prev_base_unit, prev_updated_at)
select id, merged_into_id, base_size, base_unit, updated_at from owners
on conflict (id) do nothing;

update public.master_items m
   set is_active = true, merged_into_id = null, updated_at = now(),
       base_size = coalesce(m.base_size,
                     case when m.name ~* '(\d+(\.\d+)?)\s*ml\M' then (substring(m.name from '(?i)(\d+(?:\.\d+)?)\s*ml\M'))::numeric
                          when m.name ~* '(\d+(\.\d+)?)\s*l\M'  then (substring(m.name from '(?i)(\d+(?:\.\d+)?)\s*l\M'))::numeric * 1000
                          else null end),
       base_unit = coalesce(m.base_unit, case when m.name ~* '\d\s*(ml|l)\M' then 'ml' else null end)
  from public._mig0127_reactivated r
 where r.id = m.id;

-- 3. The 8 conflicts: move the barcode to the live item the counter chose.
with picks as (
  select regexp_replace(regexp_replace(e.upc, '\D', '', 'g'), '^0+', '') as norm, min(e.master_item_id::text)::uuid as picked
    from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
   where a.join_code = 'LL-342' and a.venue_id = 'v11' and e.method = 'barcode' and e.master_item_id is not null
     and regexp_replace(regexp_replace(e.upc, '\D', '', 'g'), '^0+', '') in
         ('811538011471','81753836436','81753837815','81753839611','818844022849','82000752967','87236950026','88110158606')
   group by 1 having count(distinct e.master_item_id) = 1
)
insert into public._mig0127_upc_repoint (upc_normalized, old_master, new_master)
select x.upc_normalized, x.master_item_id, p.picked
  from public.master_item_upcs x join picks p on p.norm = x.upc_normalized
  join public.master_items live on live.id = p.picked and live.is_active
 where x.master_item_id <> p.picked
on conflict (upc_normalized) do nothing;

update public.master_item_upcs x
   set master_item_id = b.new_master,
       notes = coalesce(x.notes || ' | ', '') || '0127: moved to the item the counter scanned it as at Little Luck 11/2'
  from public._mig0127_upc_repoint b
 where b.upc_normalized = x.upc_normalized and x.master_item_id = b.old_master;

-- 2. Tie LL-342 barcode entries with no master to what the barcode now resolves to.
with ent as (
  select e.id as entry_id, x.master_item_id
    from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
    join public.master_item_upcs x on x.upc_normalized = regexp_replace(regexp_replace(e.upc, '\D', '', 'g'), '^0+', '')
    join public.master_items m on m.id = x.master_item_id and m.is_active
   where a.join_code = 'LL-342' and a.venue_id = 'v11' and e.method = 'barcode' and e.master_item_id is null
)
insert into public._mig0127_entry_links (entry_id, master_item_id)
select entry_id, master_item_id from ent on conflict (entry_id) do nothing;

update public.kount_entries e
   set master_item_id = l.master_item_id
  from public._mig0127_entry_links l
 where l.entry_id = e.id and e.master_item_id is null;

-- 4. Today's pending links whose item is live: approve them and file the barcode.
insert into public.master_item_upcs (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
select u.master_item_id, u.barcode_raw, u.barcode_normalized, 'scan_pending_approved_0127',
       'Approved in 0127 (pending link from the Little Luck count 11/2)', 'apurandare@hwoodgroup.com'
  from public.upc_mappings u join public.master_items m on m.id = u.master_item_id and m.is_active
 where u.status = 'pending' and u.created_at > '2026-11-02'
   and not exists (select 1 from public.master_item_upcs x where x.upc_normalized = u.barcode_normalized and x.master_item_id <> u.master_item_id)
on conflict (upc_normalized) do nothing;

update public.upc_mappings u
   set status = 'approved', reviewed_by_email = 'apurandare@hwoodgroup.com', reviewed_by_name = 'Aditya Purandare (0127)', reviewed_at = now()
  from public.master_item_upcs x
 where u.status = 'pending' and u.created_at > '2026-11-02'
   and x.upc_normalized = u.barcode_normalized and x.master_item_id = u.master_item_id;

do $$
declare react int; links int; moved int; still_unlinked int;
begin
  select count(*) into react from public.master_items m join public._mig0127_reactivated r on r.id = m.id where m.is_active;
  select count(*) into links from public._mig0127_entry_links;
  select count(*) into moved from public._mig0127_upc_repoint;
  select count(*) into still_unlinked from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
   where a.join_code = 'LL-342' and e.method = 'barcode' and e.master_item_id is null;
  raise notice '0127: reactivated %, entries tied %, barcodes moved %, barcode entries still unlinked %', react, links, moved, still_unlinked;
  if react <> 39 or moved <> 7 then
    raise exception '0127: expected 39 reactivated and 7 moved, got % and %', react, moved;
  end if;
end $$;

select 'reactivated' as what, m.name as item, m.base_size::text || ' ' || coalesce(m.base_unit, '') as size, null::text as detail
  from public.master_items m join public._mig0127_reactivated r on r.id = m.id
union all
select 'moved', n.name, null, 'was ' || o.name
  from public._mig0127_upc_repoint b join public.master_items o on o.id = b.old_master join public.master_items n on n.id = b.new_master
union all
select 'entries tied', m.name, null, count(*)::text || ' entr' || case when count(*) = 1 then 'y' else 'ies' end
  from public._mig0127_entry_links l join public.master_items m on m.id = l.master_item_id group by m.name
union all
select 'approved', u.item_name, null, u.barcode_normalized from public.upc_mappings u where u.reviewed_by_name = 'Aditya Purandare (0127)'
order by 1, 2;
commit;
