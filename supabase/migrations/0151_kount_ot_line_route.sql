-- =============================================================================
--  0151_kount_ot_line_route   (sea -> the warehouse, air -> the venue, per line)
--
--  The user (2026-11-03): "generally what happens is any custom item, if its
--  coming by sea goes to the warehouse, if by air comes to the venue". One order
--  can hold both (CUS-0011: 10 cases by air to Bird Streets, 10 by sea to E&E),
--  so the destination is the LINE's:
--
--    kount_ot_lines.deliver_to   'warehouse' | 'venue' | null (= the order's)
--
--  Trigger kount_ot_lines_route (a line added by the mail pull, by hand or by an
--  import, or its text changed): no destination yet + the text says sea / ocean
--  -> warehouse, air -> venue; and a warehouse line with no stock item links to
--  the one stocked E&E-warehouse item whose SKU it names as a word (BSCHOPSTCK).
--  A destination someone set is never overwritten.
--
--  Backfill: every line that says sea / air (14). The warehouse's Incoming and
--  the Received tick read the line's destination (admin v1.01).
-- =============================================================================
begin;

alter table public.kount_ot_lines add column if not exists deliver_to text check (deliver_to in ('warehouse', 'venue'));
comment on column public.kount_ot_lines.deliver_to is 'Where this line goes (0151): warehouse | venue; null = the order''s. Sea -> warehouse, air -> venue, set from the text when null';

-- 'sea' / 'air' / null from a line's text (whole words: "airlaid" is not air)
create or replace function public.kount_ot_ship_mode(p text)
returns text
language sql
immutable
as $$
  select case when p ~* '\m(sea|ocean)\M' then 'sea' when p ~* '\m(air|airfreight)\M' then 'air' end;
$$;

create or replace function public.kount_ot_line_route()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_mode text := public.kount_ot_ship_mode(new.description);
  v_hit uuid;
  v_n int;
begin
  if new.deliver_to is null and v_mode is not null
     and (tg_op = 'INSERT' or new.description is distinct from old.description) then
    new.deliver_to := case v_mode when 'sea' then 'warehouse' else 'venue' end;
  end if;
  -- into the warehouse: the stock item it names by SKU, when exactly one does
  if new.item_id is null and new.deliver_to = 'warehouse'
     and (tg_op = 'INSERT' or new.description is distinct from old.description or new.deliver_to is distinct from old.deliver_to) then
    select count(*), (array_agg(i.id))[1] into v_n, v_hit
      from public.kount_ot_items i
     where i.is_active and i.track_stock and coalesce(nullif(btrim(i.location), ''), 'E&E warehouse') = 'E&E warehouse'
       and i.sku is not null and length(i.sku) >= 5
       and upper(new.description || ' ' || coalesce(new.sku, '')) ~ ('\m' || regexp_replace(upper(i.sku), '([^A-Z0-9])', '\\\1', 'g') || '\M');
    if v_n = 1 then new.item_id := v_hit; end if;
  end if;
  return new;
end $$;

drop trigger if exists kount_ot_lines_route on public.kount_ot_lines;
create trigger kount_ot_lines_route before insert or update of description, deliver_to on public.kount_ot_lines
  for each row execute function public.kount_ot_line_route();

-- backfill (the trigger fires on this update of deliver_to and links sea lines by SKU)
update public.kount_ot_lines
   set deliver_to = case public.kount_ot_ship_mode(description) when 'sea' then 'warehouse' else 'venue' end
 where deliver_to is null and public.kount_ot_ship_mode(description) is not null;

commit;
