-- =============================================================================
--  0086_block_upc_on_house_made_items   (SCHEMA: trigger)
--
--  Stops a manufacturer barcode from ever being attached to a HOUSE-MADE item.
--
--  WHY
--  On the Little Luck 2026-10-18 count a counter scanned a Mio Sparkling Sake,
--  found no Mio in the catalog, and blank-added the barcode onto
--  "(Prep) Phony Negroni BATCH". resolveUpcLinkPolicy auto-approves a blank add
--  for ANY role with no review -- deliberate, and what keeps ~85% of scans
--  instant -- so the wrong link went live immediately and every phone's
--  approved-UPC cache then served Phony Negroni for that barcode. 0085 cleaned
--  it up; this stops the class of error rather than the instance.
--
--  A house-made prep or batch is produced in the venue. It has no
--  manufacturer, therefore no manufacturer UPC, ever. That makes this a data
--  integrity rule, not a permission rule -- so it belongs here, where no
--  client can bypass it, rather than in the phone's policy function.
--
--  MATCHED ON THE NAME PREFIX, NOT THE WORD "BATCH" -- this distinction is the
--  whole correctness of the guard:
--    blocked : '(Prep) Lemon Juice BATCH', '(Batch) <All> BS Margarita'
--    allowed : 'Batch Bottles W/ Lid', '375ml Batch bottles', 'Four Roses
--              Small Batch' -- real purchasable goods whose NAME merely
--              contains the word. 25 active items are in that second group, so
--              a substring match would have blocked legitimate scanning.
--
--  Deliberately does NOT slow the fast path: a normal product is untouched.
--  The counter sees the raise message surfaced by linkUPCToItem's existing
--  error toast, which is the correct outcome -- pick the real product instead.
--
--  ROLLBACK: 0086_ROLLBACK_block_upc_on_house_made_items.sql
-- =============================================================================

begin;

create or replace function public.kount_block_upc_on_house_made()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_name text;
begin
  select name into v_name from public.master_items where id = new.master_item_id;

  if v_name is not null
     and (v_name ilike '(prep)%' or v_name ilike '(batch)%')
  then
    raise exception
      'Cannot attach barcode % to "%" — it is made in-house, so it has no manufacturer barcode. Scan or pick the purchased product instead.',
      coalesce(new.upc_raw, new.upc_normalized), v_name
      using errcode = '23514';
  end if;

  return new;
end;
$function$;

drop trigger if exists kount_block_upc_on_house_made_trg on public.master_item_upcs;
create trigger kount_block_upc_on_house_made_trg
  before insert or update of master_item_id, upc_normalized
  on public.master_item_upcs
  for each row execute function public.kount_block_upc_on_house_made();

-- Verification: confirm the guard exists and that no house-made item currently
-- holds a UPC (0085 cleared the only one).
select (select count(*) from pg_trigger
         where tgname = 'kount_block_upc_on_house_made_trg' and not tgisinternal) trigger_installed,
       (select count(*) from public.master_item_upcs u
          join public.master_items m on m.id = u.master_item_id
         where m.name ilike '(prep)%' or m.name ilike '(batch)%') house_made_with_upc,
       (select count(*) from public.master_items
         where is_active and name ilike '%batch%'
           and name not ilike '(prep)%' and name not ilike '(batch)%') real_products_still_allowed;

commit;
