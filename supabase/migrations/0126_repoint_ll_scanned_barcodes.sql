-- =============================================================================
--  0126_repoint_ll_scanned_barcodes   (DATA)
--
--  2026-11-02, Little Luck count LL-342: 24 "couldn't link" errors on Alexa's
--  phone. Each scanned barcode was already linked in master_item_upcs to an
--  ARCHIVED item (the phone ignores archived items, so the scan read as
--  unknown), and upc_mappings' RLS refused the counter's new link because the
--  barcode "belongs" to that archived item. At Aditya's request ("add those
--  UPCs"), the 20 that are clearly the same product move onto the ACTIVE item
--  the counter picked (e.g. "Casamigos Blanco 1L" (archived) -> "Casamigos
--  Blanco (Generic) (L)"). 8 that look like different products (Bulleit
--  Bourbon vs Rye, Tanqueray No. Ten vs Tanqueray, Belvedere 10 / Organic vs
--  Belvedere, Gran Coramino Repo vs Cristalino, Cuervo Reserva vs Platino,
--  Mount Gay Eclipse Silver vs Eclipse, Volcan Tequila vs X.A Reposado) are
--  NOT moved. Old links are kept in _mig0126_upc_repoint.
--  ROLLBACK: 0126_ROLLBACK_repoint_ll_scanned_barcodes.sql
-- =============================================================================
begin;

create table if not exists public._mig0126_upc_repoint (
  upc_normalized text primary key,
  old_master     uuid not null,
  new_master     uuid not null,
  moved_at       timestamptz not null default now()
);
alter table public._mig0126_upc_repoint enable row level security;
revoke all on public._mig0126_upc_repoint from anon, authenticated;

with picks as (
  select regexp_replace(regexp_replace(e.upc, '\D', '', 'g'), '^0+', '') as norm, e.master_item_id as picked
    from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
   where a.join_code = 'LL-342' and a.venue_id = 'v11' and e.method = 'barcode' and e.master_item_id is not null
),
one as (
  select norm, min(picked::text)::uuid as picked from picks
   where norm in ('195893687015', '80686012139', '87000005549', '856724006008', '856724006107',
                  '856724006336', '856724006206', '89744329615', '80686760405', '80686762409',
                  '80686934059', '80686001201', '88110011406', '9354596006146', '811538012034',
                  '87236002923', '87236001186', '699013000550', '860002743608', '80686958031')
   group by norm having count(distinct picked) = 1
)
insert into public._mig0126_upc_repoint (upc_normalized, old_master, new_master)
select x.upc_normalized, x.master_item_id, o.picked
  from public.master_item_upcs x
  join one o on o.norm = x.upc_normalized
  join public.master_items old on old.id = x.master_item_id and not old.is_active
  join public.master_items new on new.id = o.picked and new.is_active
on conflict (upc_normalized) do nothing;

update public.master_item_upcs x
   set master_item_id = b.new_master,
       notes = coalesce(x.notes || ' | ', '') || '0126: moved from an archived item to the one counted at Little Luck 11/2'
  from public._mig0126_upc_repoint b
 where b.upc_normalized = x.upc_normalized and x.master_item_id = b.old_master;

do $$
declare n int;
begin
  select count(*) into n from public.master_item_upcs x join public._mig0126_upc_repoint b
    on b.upc_normalized = x.upc_normalized and x.master_item_id = b.new_master;
  if n <> 20 then
    raise exception '0126: expected 20 barcodes moved, got %', n;
  end if;
end $$;

select x.upc_normalized, o.name as was, n.name as now
  from public._mig0126_upc_repoint b
  join public.master_item_upcs x on x.upc_normalized = b.upc_normalized
  join public.master_items o on o.id = b.old_master
  join public.master_items n on n.id = b.new_master
 order by n.name;
commit;
