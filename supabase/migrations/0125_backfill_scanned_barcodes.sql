-- =============================================================================
--  0125_backfill_scanned_barcodes   (DATA)
--
--  2026-11-02, at Aditya's request: add barcodes that were scanned in earlier
--  counts but never made it into master_item_upcs (the table the phone
--  resolves scans from). Sources:
--    * kount_entries with method 'barcode', a upc and a master_item_id, from
--      submitted or active audits;
--    * upc_mappings rows marked 'approved' whose master link never landed.
--  A barcode is added only when it is unambiguous: a 6-14 digit code (same
--  normalisation as the phone: digits only, leading zeros dropped), pointing
--  at ONE active item across every scan, and not already linked to anything.
--  Skipped on purpose (dry run 11/2): 242 already linked, 50 already linked
--  to a different item (mostly twin items or another size), 3 scanned as two
--  different items (e.g. Orgeat 375ml vs 750ml), QR-code URLs, and codes that
--  only point at archived items.
--  ROLLBACK: delete from master_item_upcs where source = 'scan_backfill_2026_11_02';
-- =============================================================================
begin;

with scans as (
  select regexp_replace(regexp_replace(e.upc, '\D', '', 'g'), '^0+', '') as norm, e.upc as raw, e.master_item_id
    from public.kount_entries e join public.kount_audits a on a.id = e.audit_id
   where e.method = 'barcode' and e.upc is not null and e.master_item_id is not null
     and a.status in ('submitted', 'active')
  union all
  select regexp_replace(regexp_replace(u.barcode_raw, '\D', '', 'g'), '^0+', ''), u.barcode_raw, u.master_item_id
    from public.upc_mappings u
   where u.status = 'approved' and u.master_item_id is not null
),
valid as (
  select s.* from scans s join public.master_items m on m.id = s.master_item_id and m.is_active
   where length(s.norm) between 6 and 14
),
per as (
  select norm, min(raw) as raw, min(master_item_id::text)::uuid as master_item_id,
         count(distinct master_item_id) as masters
    from valid group by norm
)
insert into public.master_item_upcs (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
select p.master_item_id, p.raw, p.norm, 'scan_backfill_2026_11_02',
       'Backfilled from barcodes scanned in past counts (0125)', 'apurandare@hwoodgroup.com'
  from per p
 where p.masters = 1
   and not exists (select 1 from public.master_item_upcs x where x.upc_normalized = p.norm);

do $$
declare n int;
begin
  select count(*) into n from public.master_item_upcs where source = 'scan_backfill_2026_11_02';
  if n = 0 or n > 40 then
    raise exception '0125: expected roughly 18 backfilled barcodes, got %', n;
  end if;
end $$;

select m.name, x.upc_normalized
  from public.master_item_upcs x join public.master_items m on m.id = x.master_item_id
 where x.source = 'scan_backfill_2026_11_02' order by m.name;
commit;
