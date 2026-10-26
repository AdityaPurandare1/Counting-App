-- =============================================================================
--  0109_venue_catalog_alphabet   (TABLE + COLUMN + FUNCTIONS + CRON + DATA)
--
--  Alphabet asked (10/26) that counters only be offered what Alphabet actually
--  stocks: on A-595 Robert had "4 different types of Krug to choose from when
--  we only have one", picked a twin, and variance read the real one as missing.
--  The phone searched kount_carried_items, which is GLOBAL (~5.6k rows, every
--  venue's stock).
--
--  * kount_venue_catalog (venue_id, master_item_id, source, ...): a venue's own
--    product list. Readable by anyone who can see the venue (RLS, explicit
--    grant -- KevaOS has dropped implicit ones before).
--  * kount_venues.catalog_mode 'all' (default, every venue today) | 'invoiced'.
--    Only Alphabet (v12) is set to 'invoiced'. Phone v2.23 restricts search, the
--    List tab and photo matching to the catalog when the mode is 'invoiced'.
--  * kount_refresh_venue_catalog(venue): INSERT-ONLY (never removes a row) from
--      - the venue's invoice lines (through merged_into_id, like
--        v_effective_receipts) and its vendor-item / line maps,
--      - the venue's price list (kount_venue_cost_overrides -- for Alphabet
--        built from its distributor invoices: the 8/28 Batch Costed sheet and
--        the nightly invoice auto-costs),
--      - house-made (Prep)/(Batch) items counted at the venue.
--    Invoice lines ALONE gave only 124 products: ~73% of Alphabet's beverage
--    lines are R365 'Missing Vendor Item' placeholders that name no product,
--    and 136 of the 220 products counted on 10/26 (Don Julio 1942, Clase Azul,
--    Hennessy, Fever-Tree...) would have vanished.
--  * Seeded for Alphabet with that refresh plus the products counted on A-595
--    that are real stock with no price yet (beers, sodas, splits, purees, ice,
--    olives...), EXCLUDING twins of a catalog product: the 750ml Casamigos
--    Cristalino / Knob Creek / Mount Gay Eclipse / The Botanist (Alphabet buys
--    and prices the 1L) and the MEP 3L juice pouches (the juices are counted
--    and purchased in litres on the 1L items).
--  * Nightly cron (11:45 UTC) refreshes every 'invoiced' venue, so a newly
--    invoiced product appears without anyone touching it.
--  * kount_create_new_products_for_audit (0089) also adds a product it creates
--    at count close to the venue's catalog when that venue is 'invoiced'.
--  ROLLBACK: 0109_ROLLBACK_venue_catalog_alphabet.sql
-- =============================================================================
begin;

create table if not exists public.kount_venue_catalog (
  venue_id        text        not null references public.kount_venues(id) on delete cascade,
  master_item_id  uuid        not null references public.master_items(id) on delete cascade,
  source          text        not null,
  added_by        text        not null default 'system',
  added_at        timestamptz not null default now(),
  primary key (venue_id, master_item_id)
);
comment on table public.kount_venue_catalog is
  'A venue''s own product list. When kount_venues.catalog_mode = ''invoiced'' the phone offers only these products in search, the List tab and photo matching. Filled by kount_refresh_venue_catalog (insert-only, nightly) and at count close.';

alter table public.kount_venue_catalog enable row level security;
drop policy if exists kount_venue_catalog_select on public.kount_venue_catalog;
create policy kount_venue_catalog_select on public.kount_venue_catalog
  for select to authenticated
  using (public.kount_is_corporate() or public.kount_can_see_venue(venue_id));
revoke all on public.kount_venue_catalog from anon, public;
grant select on public.kount_venue_catalog to authenticated;
grant all on public.kount_venue_catalog to service_role;

alter table public.kount_venues add column if not exists catalog_mode text not null default 'all';
alter table public.kount_venues drop constraint if exists kount_venues_catalog_mode_check;
alter table public.kount_venues add constraint kount_venues_catalog_mode_check check (catalog_mode in ('all', 'invoiced'));

create or replace function public.kount_refresh_venue_catalog(p_venue_id text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ops   uuid;
  v_added integer;
begin
  select kv.ops_venue_id into v_ops from public.kount_venues kv where kv.id = p_venue_id;
  insert into public.kount_venue_catalog (venue_id, master_item_id, source)
  select distinct on (s.mid) p_venue_id, s.mid, s.src
    from (
      select coalesce(redir.merged_into_id, l.master_item_id, pi.master_item_id) as mid, 'invoice' as src
        from public.invoice_lines l
        join public.invoices i on i.id = l.invoice_id
        left join public.purchase_items pi on pi.id = l.item_id
        left join public.master_items redir on redir.id = coalesce(l.master_item_id, pi.master_item_id)
       where v_ops is not null and i.venue_id = v_ops and not coalesce(l.is_ignored, false)
      union all
      select x.master_item_id, 'invoice (matched line)' from public.kount_invoice_line_map x where x.venue_id = p_venue_id
      union all
      select x.master_item_id, 'invoice (vendor item map)' from public.kount_invoice_item_map x where x.venue_id = p_venue_id
      union all
      select o.master_item_id, 'venue price list' from public.kount_venue_cost_overrides o
       where o.venue_id = p_venue_id and o.cost_per_unit > 0
      union all
      select e.master_item_id, 'house-made, counted here'
        from public.kount_entries e
        join public.kount_audits a on a.id = e.audit_id
        join public.master_items m on m.id = e.master_item_id
       where a.venue_id = p_venue_id and (m.name ilike '(prep)%' or m.name ilike '(batch)%')
    ) s
    join public.master_items m on m.id = s.mid
   where s.mid is not null
     and m.is_active
     and m.category in ('Wine Cost', 'wine', 'Wine', 'Liquor Cost', 'liquor', 'Liquor', 'Beer Cost', 'beer',
                        'N/A Beverage Cost', 'non_alcoholic_beverage', 'Bar Consumables', 'bar_consumable', 'Bar Supplies')
   order by s.mid
  on conflict (venue_id, master_item_id) do nothing;
  get diagnostics v_added = row_count;
  return v_added;
end;
$function$;
revoke execute on function public.kount_refresh_venue_catalog(text) from public, anon, authenticated;

-- Alphabet only.
update public.kount_venues set catalog_mode = 'invoiced' where id = 'v12';
select public.kount_refresh_venue_catalog('v12') as refreshed;

insert into public.kount_venue_catalog (venue_id, master_item_id, source, added_by)
select distinct 'v12', e.master_item_id, 'counted at Alphabet on A-595 (10/26)', 'claude 2026-10-26'
  from public.kount_entries e
  join public.master_items m on m.id = e.master_item_id
 where e.audit_id = (select id from public.kount_audits where join_code = 'A-595')
   and m.is_active
   and m.name not in ('Casamigos Cristalino 750ml', 'Knob Creek 750ml', 'Mount Gay Eclipse 750ml', 'The Botanist 750ml',
                      'Mep 3L Lemon*Fresh Juice', 'Mep 3L Lime*Fresh Juice', 'MEP 3L ORANGE FRESH JUICE 3 LT', 'MEP Grapefruit juice 3L 3L')
on conflict (venue_id, master_item_id) do nothing;

-- Nightly refresh of every 'invoiced' venue.
select cron.unschedule(jobid) from cron.job where jobname = 'kount-venue-catalog-refresh';
select cron.schedule('kount-venue-catalog-refresh', '45 11 * * *',
  $cron$select count(*) from public.kount_venues kv cross join lateral (select public.kount_refresh_venue_catalog(kv.id)) x where kv.catalog_mode = 'invoiced' and kv.is_active$cron$);

-- Products created at count close join the venue's catalog (0089 + one statement).
CREATE OR REPLACE FUNCTION public.kount_create_new_products_for_audit(p_audit_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

      -- 0109: a venue on its own catalog gets the product it just counted.
      insert into public.kount_venue_catalog (venue_id, master_item_id, source, added_by)
      select a.venue_id, v_master, 'new product created at count close', 'system@count-close'
        from public.kount_audits a
        join public.kount_venues kv on kv.id = a.venue_id
       where a.id = p_audit_id and kv.catalog_mode = 'invoiced'
      on conflict (venue_id, master_item_id) do nothing;

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

select (select catalog_mode from public.kount_venues where id = 'v12') v12_mode,
       (select count(*) from public.kount_venues where catalog_mode = 'invoiced') invoiced_venues,
       (select count(*) from public.kount_venue_catalog where venue_id = 'v12') v12_catalog,
       (select string_agg(source || '=' || n, ', ') from (select source, count(*) n from public.kount_venue_catalog where venue_id = 'v12' group by 1 order by 2 desc) z) by_source,
       (select count(*) from cron.job where jobname = 'kount-venue-catalog-refresh') cron_job;
commit;
