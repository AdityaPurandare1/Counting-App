-- =============================================================================
--  0060_kount_venue_invoice_costs
--
--  Derive each venue's unit costs from ITS OWN invoice lines, automatically.
--
--  WHY
--  0059 gave the audit report per-venue costs, but every row in that table was
--  typed in from Alphabet's opening trackers. That is right for August and
--  wrong from the first price change. The company-wide catalog cost is no
--  better: it is "whichever sync wrote purchase_items.avg_cost last", which is
--  how a Nice Guy CASE price ($188.34) became Poppy's Disaronno BOTTLE price
--  and how Poppy's whole tequila shelf is still on June prices. The 2026-10-05
--  Alphabet-vs-Poppy cost audit found 21 products 20%+ apart; the stale and
--  mis-unit'd ones were all on the catalog side.
--
--  WHAT
--  kount_refresh_venue_invoice_costs(venue, days, apply): for one counting
--  venue, take the NEWEST invoice line per catalog item from that venue's own
--  invoices (bridged through kount_venues.ops_venue_id, the 0056 link), and
--  normalise it to a per-unit cost. Normalisation is ONLY attempted when the
--  line carries a case size (invoice_lines.cu_qty) — Craftable's unit_cost is
--  the CASE price, and dividing by a guessed pack is exactly the bug this
--  replaces, so a line without cu_qty is skipped, never guessed.
--
--  GUARDRAILS (every row gets a status; only 'ok%' rows are ever written)
--    · reject: non-positive         — bad line
--    · review: >2.5x from catalog   — unit mismatch or a real repricing; a
--                                      human decides, the job does not
--    · ok: no catalog cost          — nothing to compare against
--    · ok                           — within 2.5x of the catalog cost
--  Manual rows win: the new is_manual column marks the 0059 hand-entered rows
--  (true) and this job's rows (false). The job never overwrites a manual row.
--
--  HOW TO RUN
--    select * from kount_refresh_venue_invoice_costs('v5', 120, false);  -- dry run, Poppy
--    select * from kount_refresh_venue_invoice_costs('v5', 120, true);   -- apply
--  Nightly scheduling (pg_cron) is deliberately NOT done here: cron.job is
--  shared with KevaOS and should be added with their ETL owner in the loop.
--
--  REVERSIBLE: delete from kount_venue_cost_overrides where not is_manual;
--              drop function kount_refresh_venue_invoice_costs; then
--              alter table ... drop column is_manual.
-- =============================================================================

alter table public.kount_venue_cost_overrides
  add column if not exists is_manual boolean not null default true;
comment on column public.kount_venue_cost_overrides.is_manual is
  'true = typed in by a person (wins); false = derived from the venue''s own invoice lines by kount_refresh_venue_invoice_costs';

create or replace function public.kount_refresh_venue_invoice_costs(
  p_venue_id text,
  p_days     int     default 120,
  p_apply    boolean default false
)
returns table (
  master_item_id uuid,
  item           text,
  invoice_date   date,
  invoice_number text,
  vendor         text,
  case_cost      numeric,
  cu_qty         numeric,
  unit_cost      numeric,
  catalog_cost   numeric,
  ratio          numeric,
  manual_cost    numeric,
  status         text
)
language plpgsql
security definer
set search_path = public
as $$
-- The RETURNS TABLE columns are PL/pgSQL variables; without this, the
-- `on conflict (venue_id, master_item_id)` below is "ambiguous".
#variable_conflict use_column
declare
  v_ops uuid;
begin
  select kv.ops_venue_id into v_ops from kount_venues kv where kv.id = p_venue_id;
  if v_ops is null then
    raise exception 'kount venue % has no ops_venue_id (see migration 0056)', p_venue_id;
  end if;

  create temp table _kvic on commit drop as
  with lines as (
    select coalesce(l.master_item_id, p.master_item_id) as mid,
           i.invoice_date, i.invoice_number, v.name as vendor,
           l.unit_cost as case_cost, l.cu_qty,
           round((l.unit_cost / l.cu_qty)::numeric, 4) as per_unit,
           row_number() over (partition by coalesce(l.master_item_id, p.master_item_id)
                              order by i.invoice_date desc, l.created_at desc nulls last, l.id desc) as rn
    from invoice_lines l
    join invoices i on i.id = l.invoice_id
    left join purchase_items p on p.id = l.item_id
    left join vendors v on v.id = i.vendor_id
    where i.venue_id = v_ops
      and i.invoice_date >= current_date - p_days
      and l.unit_cost > 0
      and l.cu_qty > 0
      and not coalesce(l.is_ignored, false)
      and coalesce(l.master_item_id, p.master_item_id) is not null
  ),
  newest as (select * from lines where rn = 1),
  cat as (
    select distinct on (pi.master_item_id) pi.master_item_id, pi.avg_cost
    from purchase_items pi where pi.avg_cost > 0
    order by pi.master_item_id, pi.updated_at desc nulls last, pi.id desc
  )
  select n.mid, m.name as item, n.invoice_date, n.invoice_number, n.vendor, n.case_cost, n.cu_qty, n.per_unit,
         c.avg_cost as catalog_cost,
         round((n.per_unit / nullif(c.avg_cost, 0))::numeric, 2) as ratio,
         o.cost_per_unit as manual_cost,
         case
           when n.per_unit <= 0 then 'reject: non-positive'
           when o.is_manual then 'skip: manual row exists'
           when c.avg_cost is null then 'ok: no catalog cost'
           when n.per_unit > c.avg_cost * 2.5 or n.per_unit < c.avg_cost / 2.5 then 'review: >2.5x from catalog'
           else 'ok'
         end as status
  from newest n
  join master_items m on m.id = n.mid
   -- Beverage only: the audit report covers the four beverage GL accounts
   -- (bar consumables are excluded but priced for the Cost Basis sheet).
   -- Without this the job happily prices "IT Software" and "Chicken Tenders".
   and m.category ~* 'liquor|wine|beer|beverage|consumable'
  left join cat c on c.master_item_id = n.mid
  left join kount_venue_cost_overrides o on o.venue_id = p_venue_id and o.master_item_id = n.mid;

  if p_apply then
    insert into kount_venue_cost_overrides (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, updated_at)
    select p_venue_id, k.mid, k.per_unit,
           format('%s invoice #%s %s: %s x %s = $%s/case (auto)', k.vendor, k.invoice_number, k.invoice_date, k.cu_qty, k.per_unit, k.case_cost),
           'kount_refresh_venue_invoice_costs', false, now()
    from _kvic k
    where k.status like 'ok%'
    on conflict (venue_id, master_item_id) do update
      set cost_per_unit = excluded.cost_per_unit, source = excluded.source,
          set_by = excluded.set_by, is_manual = false, updated_at = now()
      where kount_venue_cost_overrides.is_manual = false;
  end if;

  return query
  select k.mid, k.item, k.invoice_date, k.invoice_number, k.vendor, k.case_cost, k.cu_qty, k.per_unit,
         k.catalog_cost, k.ratio, k.manual_cost, k.status
  from _kvic k
  order by k.status, k.item;
end $$;

revoke all on function public.kount_refresh_venue_invoice_costs(text, int, boolean) from public, anon, authenticated;

-- Verification: column present, function present, no existing row flipped to auto.
select
  (select count(*) from information_schema.columns where table_name = 'kount_venue_cost_overrides' and column_name = 'is_manual') as has_is_manual,
  (select count(*) from pg_proc where proname = 'kount_refresh_venue_invoice_costs') as fn,
  (select count(*) from public.kount_venue_cost_overrides where not is_manual) as auto_rows_now;
