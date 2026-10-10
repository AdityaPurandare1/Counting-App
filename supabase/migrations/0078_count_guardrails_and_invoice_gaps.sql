-- =============================================================================
--  0078_count_guardrails_and_invoice_gaps
--
--  Two read-only checks, shown on the phone before Count 1 closes and on the admin audit screen.
--  Opted-in venues only (kount_venues.purchase_mapping = 'venue_item_map': Alphabet, Lady Delilah);
--  every other venue gets no rows. Both are SECURITY DEFINER and gated by kount_can_see_venue.
--
--  kount_invoice_gaps(venue, from, to)
--    Vendors that invoice this venue regularly (beverage GL 53xx lines in >= 4 weeks of the last 120
--    days, and in at least half the weeks since their first invoice) with a week in [from, to) that
--    has no invoice, or whose last invoice is more than 14 days before `to`. The week containing `to`
--    is not judged (still in progress). Found 2026-10-09: Southern Glazer's had no Alphabet invoice
--    for the weeks of 9/14 and 9/21.
--
--  kount_count_guardrails(audit)
--    Compares this count with the venue's previous submitted count:
--      zone_empty          a zone with stock last count has no entries now (A-907 had no Liquor Room)
--      not_counted         an item worth >= $75 last count is absent, and no other size of it was counted
--      size_switch         an item counted now that was not counted last time, while another size of the
--                          same product (same first two words) was counted last time and is absent now
--      low_after_delivery  counted < 25% of the units delivered in the 10 days before the count
--                          (A-907: Diet Coke 6 after 144 arrived)
--      invoice_gap         kount_invoice_gaps for the count's window
--    Warnings only -- nothing is blocked.
--  ROLLBACK: drop both functions (0078_ROLLBACK_count_guardrails_and_invoice_gaps.sql).
-- =============================================================================
begin;

create or replace function public.kount_invoice_gaps(p_venue_id text, p_from date, p_to date default current_date)
returns table(vendor text, status text, missing_weeks text, last_invoice date, weeks_active integer, weeks_total integer)
language plpgsql stable security definer set search_path to 'public' as $fn$
#variable_conflict use_column
declare v_ops uuid; v_map text;
begin
  if not kount_can_see_venue(p_venue_id) then return; end if;
  select kv.ops_venue_id, kv.purchase_mapping into v_ops, v_map from kount_venues kv where kv.id = p_venue_id;
  if v_ops is null or v_map is distinct from 'venue_item_map' or p_to is null then return; end if;
  return query
  with inv as (
    select i.vendor_id, coalesce(v.name, '?') as vname, i.invoice_date as d
      from invoices i left join vendors v on v.id = i.vendor_id
     where i.venue_id = v_ops and i.vendor_id is not null
       and i.invoice_date between p_to - 120 and p_to
       and exists (select 1 from invoice_lines il where il.invoice_id = i.id and il.gl_code ~ '^53')),
  vend as (
    select vendor_id, min(vname) as vname, min(d) as first_d, max(d) as last_d,
           count(distinct date_trunc('week', d::timestamp))::int as wk_active,
           ((date_trunc('week', p_to::timestamp)::date - date_trunc('week', min(d)::timestamp)::date) / 7 + 1)::int as wk_total
      from inv group by vendor_id),
  regular as (select * from vend where wk_active >= 4 and wk_active::numeric / greatest(wk_total, 1) >= 0.5),
  weeks as (
    select r.vendor_id, gs::date as wk
      from regular r,
           generate_series(date_trunc('week', greatest(r.first_d, coalesce(p_from, r.first_d))::timestamp),
                           date_trunc('week', p_to::timestamp) - interval '7 days', interval '7 days') gs),
  missing as (
    select w.vendor_id, string_agg(to_char(w.wk, 'Mon DD'), ', ' order by w.wk) as mw, count(*) as n
      from weeks w
     where not exists (select 1 from inv where inv.vendor_id = w.vendor_id and date_trunc('week', inv.d::timestamp)::date = w.wk)
     group by w.vendor_id)
  select r.vname,
         case when coalesce(m.n, 0) > 0 then 'missing weeks' when r.last_d < p_to - 14 then 'overdue' else 'ok' end,
         coalesce('week of ' || m.mw, ''), r.last_d, r.wk_active, r.wk_total
    from regular r left join missing m on m.vendor_id = r.vendor_id
   order by (coalesce(m.n, 0) = 0), r.vname;
end $fn$;

create or replace function public.kount_count_guardrails(p_audit_id uuid)
returns table(kind text, message text, sort_value numeric)
language plpgsql stable security definer set search_path to 'public' as $fn$
#variable_conflict use_column
declare v_venue text; v_ops uuid; v_map text; v_end timestamptz; v_prev uuid; v_prev_close timestamptz;
begin
  select a.venue_id, kv.ops_venue_id, kv.purchase_mapping, coalesce(a.count2_closed_at, a.completed_at, a.count1_closed_at, now())
    into v_venue, v_ops, v_map, v_end
    from kount_audits a join kount_venues kv on kv.id = a.venue_id where a.id = p_audit_id;
  if v_venue is null or v_map is distinct from 'venue_item_map' or not kount_can_see_venue(v_venue) then return; end if;

  select a.id, coalesce(a.count2_closed_at, a.completed_at, a.count1_closed_at) into v_prev, v_prev_close
    from kount_audits a
   where a.venue_id = v_venue and a.id <> p_audit_id and a.status = 'submitted'
     and coalesce(a.count2_closed_at, a.completed_at, a.count1_closed_at) < v_end
   order by coalesce(a.count2_closed_at, a.completed_at, a.count1_closed_at) desc limit 1;

  return query
  with cur as (select e.master_item_id as mid, e.zone, sum(e.qty) as q from kount_entries e
                where e.audit_id = p_audit_id and e.master_item_id is not null and not e.is_recount group by 1, 2),
       prv as (select e.master_item_id as mid, e.zone, sum(e.qty) as q from kount_entries e
                where v_prev is not null and e.audit_id = v_prev and e.master_item_id is not null and not e.is_recount group by 1, 2),
       cur_i as (select mid, sum(q) as q from cur group by 1),
       prv_i as (select mid, sum(q) as q from prv group by 1),
       cost as (select o.master_item_id as mid, o.cost_per_unit as c from kount_venue_cost_overrides o where o.venue_id = v_venue),
       nm as (select m.id, m.name, lower(split_part(m.name, ' ', 1) || ' ' || split_part(m.name, ' ', 2)) as stem
                from master_items m where m.id in (select mid from cur_i union select mid from prv_i)),
  zone_empty as (
    select 'zone_empty'::text as kind,
           format('%s: %s items there last count, nothing counted there now', z.zone, z.n) as message, z.n::numeric as sort_value
      from (select zone, count(*) as n from prv where q > 0 group by zone) z
     where not exists (select 1 from cur where cur.zone = z.zone)),
  size_switch as (
    select 'size_switch'::text, format('%s counted (%s), but last count used %s (%s). Same product in a different size?',
                                      nc.name, round(c.q, 1), np.name, round(p.q, 1)), c.q
      from cur_i c join nm nc on nc.id = c.mid
      join prv_i p on p.mid <> c.mid and p.q > 0
      join nm np on np.id = p.mid and np.stem = nc.stem
     where coalesce((select q from prv_i x where x.mid = c.mid), 0) = 0
       and not exists (select 1 from cur_i c2 where c2.mid = p.mid)),
  not_counted as (
    select 'not_counted'::text, format('%s: %s last count ($%s), not counted now', n.name, round(p.q, 1), round(p.q * co.c)), p.q * co.c
      from prv_i p join nm n on n.id = p.mid join cost co on co.mid = p.mid
     where p.q > 0 and p.q * co.c >= 75
       and not exists (select 1 from cur_i where cur_i.mid = p.mid)
       and not exists (select 1 from cur_i c join nm nc on nc.id = c.mid where nc.stem = n.stem)
     order by p.q * co.c desc limit 15),
  deliv as (
    select x.mid, sum(x.u) as u, min(x.d) as first_d from (
      select lm.master_item_id as mid, lm.units as u, i.invoice_date as d
        from kount_invoice_line_map lm join invoice_lines il on il.id = lm.invoice_line_id join invoices i on i.id = il.invoice_id
       where lm.venue_id = v_venue and i.invoice_date between v_end::date - 10 and v_end::date
      union all
      select vm.master_item_id, il.qty * case when coalesce(vm.units_per_case, 1) > 1 and coalesce(co.c, 0) > 0
                                                and il.unit_cost / vm.units_per_case between co.c / 2.5 and co.c * 2.5
                                              then vm.units_per_case else 1 end, i.invoice_date
        from kount_invoice_item_map vm
        join invoice_lines il on il.item_id = vm.purchase_item_id
        join invoices i on i.id = il.invoice_id and i.venue_id = v_ops
        left join cost co on co.mid = vm.master_item_id
       where vm.venue_id = v_venue and i.invoice_date between v_end::date - 10 and v_end::date
         and not exists (select 1 from kount_invoice_line_map l2 where l2.venue_id = v_venue and l2.invoice_line_id = il.id)) x
    group by x.mid),
  low as (
    select 'low_after_delivery'::text,
           format('%s: %s counted, but %s arrived since %s. Cases entered as bottles, or stock missed?',
                  n.name, round(c.q, 1), round(d.u), to_char(d.first_d, 'Mon DD')), d.u
      from deliv d join cur_i c on c.mid = d.mid join master_items n on n.id = d.mid
     where d.u >= 12 and c.q < 0.25 * d.u),
  gaps as (select * from kount_invoice_gaps(v_venue, coalesce(v_prev_close::date, v_end::date - 30), v_end::date))
  select * from zone_empty
  union all select * from size_switch
  union all select * from not_counted
  union all select * from low
  union all select 'invoice_gap'::text, format('%s: no invoice for the %s', g.vendor, g.missing_weeks), null::numeric from gaps g where g.status = 'missing weeks'
  union all select 'invoice_gap'::text, format('%s: last invoice %s, more than two weeks ago', g.vendor, to_char(g.last_invoice, 'Mon DD')), null::numeric from gaps g where g.status = 'overdue';
end $fn$;

revoke all on function public.kount_invoice_gaps(text, date, date) from public, anon;
revoke all on function public.kount_count_guardrails(uuid) from public, anon;
grant execute on function public.kount_invoice_gaps(text, date, date) to authenticated;
grant execute on function public.kount_count_guardrails(uuid) to authenticated;
notify pgrst, 'reload schema';

commit;
