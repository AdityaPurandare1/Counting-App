-- =============================================================================
--  0089_create_new_products_on_count_close   (FUNCTION + TRIGGER)
--
--  The photo-mode rule, as Aditya defined it:
--    a counter photographs a bottle -> the AI reads the label -> the details
--    are filled in -> if it is a NEW product it is STORED -> when the count is
--    closed, ALL the stored new products are created together.
--
--  WHAT EXISTED BEFORE, AND WHY IT NEVER WORKED
--    * Storing needed a manual "Suggest" tap per bottle (easy to skip -- the
--      10/18 Little Luck count recorded ZERO photo entries).
--    * Each stored item then waited for an admin to approve it one at a time.
--      34 pending items are sitting unapproved today, 11 tied to past counts.
--    * The counted entry itself was saved with NO master_item_id, so it was
--      invisible to variance, costing and history (0084 had to repair five).
--
--  WHAT THIS DOES
--    kount_create_new_products_for_audit(audit) walks the audit's UNLINKED
--    entries, finds the stored new product for each name, creates the catalog
--    item, carries it, attaches its barcode, marks the stored row approved,
--    and links the entries. A trigger runs it when a count closes.
--
--  DRIVEN FROM THE ENTRIES, NOT FROM pending.audit_id -- deliberately.
--    kount_pending_items has a GLOBAL unique index on lower(name) where
--    status='pending' (migration 0010). If an older count already stored a
--    product of the same name, the new count's store collides and leaves NO
--    row carrying this audit's id. Matching unlinked entries to pending rows
--    by name catches that case; filtering on audit_id would silently miss it.
--    Only names that were actually STORED become products -- a typo typed
--    into manual entry is not promoted into the shared catalog.
--
--  WHEN IT RUNS: on Count 1 close AND on final submit.
--    Aditya's rule says "after the count is submitted". Variance, however, is
--    computed at Count 1 close (closeCount1 awaits the count1_closed_at update,
--    THEN calls compute_avt_for_audit), and compute only sums entries that
--    carry a master_item_id. Creating products only at final submit would
--    leave every photographed wine out of the Count 1 variance and the recount
--    list. So it runs at both: Count 1 close creates everything counted so
--    far, final submit catches anything photographed during the recount. The
--    function is idempotent (it only touches still-pending rows and still-
--    unlinked entries), so running twice is safe. Because the trigger runs
--    inside the same UPDATE that closes the count, the products exist and the
--    entries are linked BEFORE compute_avt_for_audit is called.
--
--  IT MUST NEVER BLOCK A COUNT FROM CLOSING.
--    It runs inside the closing UPDATE's transaction, so an unhandled error
--    would roll back the close itself. Every product is processed in its own
--    exception block (one bad row is skipped and reported, the rest proceed),
--    the barcode attach has its own block (the 0086 house-made guard may
--    legitimately refuse it), and the trigger swallows anything left over.
--
--  Not callable by app users: EXECUTE is revoked; it runs only from the
--  trigger (as its owner) or by hand from a migration for a backfill.
--
--  ROLLBACK: 0089_ROLLBACK_create_new_products_on_count_close.sql
-- =============================================================================

begin;

create or replace function public.kount_create_new_products_for_audit(p_audit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org        uuid;
  v_names      text[];
  v_name       text;
  p            public.kount_pending_items;
  v_master     uuid;
  v_composed   text;
  v_size       numeric;
  v_unit       text;
  v_m          text[];
  v_upc        text;
  v_linked     int;
  v_created    int := 0;
  v_linked_all int := 0;
  v_skipped    jsonb := '[]'::jsonb;
begin
  -- Same org resolution approve_pending_item uses: the catalog's main org.
  select organization_id into v_org
    from public.master_items
   where organization_id is not null
   group by organization_id
   order by count(*) desc
   limit 1;

  select array_agg(distinct lower(btrim(e.item_name)))
    into v_names
    from public.kount_entries e
   where e.audit_id = p_audit_id
     and e.master_item_id is null
     and btrim(coalesce(e.item_name, '')) <> '';

  if v_names is null then
    return jsonb_build_object('ok', true, 'audit_id', p_audit_id, 'created', 0, 'linked', 0, 'skipped', v_skipped);
  end if;

  foreach v_name in array v_names loop
    begin
      -- The stored new product for this name: prefer one stored by THIS count.
      select * into p
        from public.kount_pending_items k
       where k.status = 'pending'
         and lower(btrim(k.name)) = v_name
       order by (k.audit_id = p_audit_id) desc nulls last, k.submitted_at
       limit 1;
      if not found then
        continue;            -- typed but never stored as a new product: leave it
      end if;

      if p.category is null or p.category not in (
        'Wine Cost', 'wine', 'Wine', 'Liquor Cost', 'liquor', 'Liquor',
        'Beer Cost', 'beer', 'N/A Beverage Cost', 'non_alcoholic_beverage',
        'Bar Consumables', 'bar_consumable', 'Bar Supplies'
      ) then
        v_skipped := v_skipped || jsonb_build_object('name', p.name, 'reason', 'out-of-scope category: ' || coalesce(p.category, 'null'));
        continue;
      end if;

      -- Name. The photo flow already stores the full identity
      -- ("Brand Name Vintage Size"); older manual suggestions stored the parts.
      -- Only add brand or size when they are not already in the name, so a
      -- new-style row is used verbatim and never becomes "... 750ml 750ml".
      v_composed := btrim(p.name);
      if p.brand is not null and btrim(p.brand) <> ''
         and position(lower(btrim(p.brand)) in lower(v_composed)) = 0 then
        v_composed := btrim(p.brand) || ' ' || v_composed;
      end if;
      if p.size is not null and btrim(p.size) <> ''
         and position(lower(regexp_replace(p.size, '\s+', '', 'g')) in lower(regexp_replace(v_composed, '\s+', '', 'g'))) = 0 then
        v_composed := v_composed || ' ' || btrim(p.size);
      end if;
      v_composed := regexp_replace(v_composed, '\s+', ' ', 'g');

      v_size := null; v_unit := null;
      v_m := regexp_match(coalesce(p.size, ''), '(\d+(?:\.\d+)?)\s*(ml|cl|l|oz|each|ea)', 'i');
      if v_m is not null then
        v_size := v_m[1]::numeric;
        v_unit := lower(v_m[2]);
        if v_unit = 'cl' then v_size := v_size * 10; v_unit := 'ml'; end if;
      end if;

      -- Reuse / reactivate on the catalog's unique key rather than duplicate
      -- (0081 found "missing" items that were really inactive rows).
      insert into public.master_items (name, category, subcategory, base_size, base_unit, organization_id, is_active)
      values (v_composed, p.category, p.subcategory, v_size, v_unit, v_org, true)
      on conflict (organization_id, name, category) do update set is_active = true
      returning id into v_master;
      v_created := v_created + 1;

      -- Barcode in its own block: the 0086 trigger refuses a manufacturer
      -- UPC on a (Prep)/(Batch) item, and a UPC already on another product is
      -- left alone. Neither may stop the product being created.
      v_upc := regexp_replace(regexp_replace(btrim(coalesce(p.upc, '')), '[^0-9]', '', 'g'), '^0+', '');
      if v_upc <> '' then
        begin
          insert into public.master_item_upcs (master_item_id, upc_raw, upc_normalized, source, notes, added_by_email)
          values (v_master, btrim(p.upc), v_upc, 'scan_approved',
                  'Created at count close from a photo/suggested new product', 'system@count-close')
          on conflict (upc_normalized) do nothing;
        exception when others then
          v_skipped := v_skipped || jsonb_build_object('name', p.name, 'reason', 'barcode not attached: ' || sqlerrm);
        end;
      end if;

      insert into public.kount_carried_items (master_item_id, added_by_email, added_by_name, notes)
      select v_master, 'system@count-close', 'Count close', 'New product created at count close'
       where not exists (select 1 from public.kount_carried_items c where c.master_item_id = v_master);

      update public.kount_pending_items
         set status = 'approved', master_item_id = v_master,
             reviewed_by_email = 'system@count-close', reviewed_by_name = 'Count close',
             reviewed_at = now()
       where id = p.id;

      update public.kount_entries e
         set master_item_id = v_master
       where e.audit_id = p_audit_id
         and e.master_item_id is null
         and lower(btrim(e.item_name)) = v_name;
      get diagnostics v_linked = row_count;
      v_linked_all := v_linked_all + v_linked;

    exception when others then
      -- One bad product is skipped, never the whole close.
      v_skipped := v_skipped || jsonb_build_object('name', v_name, 'reason', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('ok', true, 'audit_id', p_audit_id,
    'created', v_created, 'linked', v_linked_all, 'skipped', v_skipped);
end;
$function$;

revoke execute on function public.kount_create_new_products_for_audit(uuid) from public, anon, authenticated;

create or replace function public.kount_new_products_on_close_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r jsonb;
begin
  begin
    r := public.kount_create_new_products_for_audit(new.id);
    if (r ->> 'created')::int > 0 or jsonb_array_length(r -> 'skipped') > 0 then
      raise notice 'kount: new products at close of %: %', new.id, r;
    end if;
  exception when others then
    -- Belt and braces: closing the count always wins.
    raise warning 'kount: creating new products at close of % failed: %', new.id, sqlerrm;
  end;
  return new;
end;
$function$;

drop trigger if exists kount_new_products_on_close on public.kount_audits;
create trigger kount_new_products_on_close
  after update of count1_closed_at, status on public.kount_audits
  for each row
  when (
    (old.count1_closed_at is null and new.count1_closed_at is not null)
    or (old.status is distinct from 'submitted' and new.status = 'submitted')
  )
  execute function public.kount_new_products_on_close_trg();

select (select count(*) from pg_trigger where tgname = 'kount_new_products_on_close' and not tgisinternal) trigger_installed,
       (select count(*) from pg_proc where proname = 'kount_create_new_products_for_audit') fn_installed;

commit;
