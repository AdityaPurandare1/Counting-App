-- =============================================================================
--  0176_kount_price_check   (the weekly price check of the bible items, admin v1.23)
--
--  The user (2026-11-17): "a checker / sourcer kind of a module that check for each
--  BOH and FOH item if its being purchased right ? by right i mean the correct price.
--  the only requirement is that it has to be the exact same item mentioned in the
--  bible. all specs have to match exactly. It should run weekly and scan the internet
--  for those specific items. If there is a website which doesnt really have those
--  labelled as such but need a quote tag them as quote required and I can work on
--  getting the quote". Every bible item weekly; the model on OpenRouter.
--
--    kount_pc_items     one row per item in the current bibles (one per manufacturer
--                       item #, across venues), re-read by each run; checkable = it has
--                       an item #; bought = we have a purchase price (checked first)
--    kount_pc_checks    every check: the exact offers, quote-only sellers, rejected
--                       near-matches, our price per piece, the verdict, cost
--    kount_pc_runs      one per week: items done, spend against the weekly budget
--    kount_pc_settings  on/off, model, weekly budget, the overpaying threshold
--
--  kount-price-check does the work (service role). People read with the Order
--  tracker or Order prices permission; they tag quotes (kount_pc_set_quote) and
--  change the settings (kount_pc_set_settings, Order tracker only).
--
--  pg_cron: 'kount-price-check-weekly' Saturday 03:00 UTC (7 pm PST / 8 pm PDT)
--  starts a run; 'kount-price-check-work' every 3 min while items are due checks a
--  few at a time. Both only while switched on (off until the first item is tested).
-- =============================================================================
begin;

create table if not exists public.kount_pc_settings (
  id int primary key default 1 check (id = 1),
  enabled boolean not null default false,
  model text not null default 'anthropic/claude-sonnet-5.5',
  weekly_budget_usd numeric not null default 200 check (weekly_budget_usd >= 0),
  overpay_pct numeric not null default 10 check (overpay_pct > 0 and overpay_pct < 100),
  per_tick int not null default 5 check (per_tick between 1 and 8),
  updated_at timestamptz not null default now(),
  updated_by text
);
insert into public.kount_pc_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.kount_pc_runs (
  id uuid primary key default gen_random_uuid(),
  trigger text not null,
  model text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  items_total int not null default 0,
  items_done int not null default 0,
  cost_usd numeric not null default 0,
  budget_usd numeric,
  stopped text
);

create table if not exists public.kount_pc_items (
  id uuid primary key default gen_random_uuid(),
  item_key text not null unique,
  item_no text, manufacturer text, item_name text, description text, size text,
  specs jsonb not null default '{}'::jsonb,
  sources jsonb not null default '[]'::jsonb,
  bible_price text, bible_link text,
  checkable boolean not null default true,
  bought boolean not null default false,
  active boolean not null default true,
  due_at timestamptz, claimed_at timestamptz, attempts int not null default 0,
  last_check_id uuid, last_status text, last_checked_at timestamptz,
  quote_state text check (quote_state in ('requested', 'received')),
  quote_vendor text, quote_price numeric, quote_note text, quote_by text, quote_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists kount_pc_items_due on public.kount_pc_items (due_at) where due_at is not null;

create table if not exists public.kount_pc_checks (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.kount_pc_items(id) on delete cascade,
  run_id uuid references public.kount_pc_runs(id) on delete set null,
  checked_at timestamptz not null default now(),
  status text not null check (status in ('overpaying', 'ok', 'market_only', 'quote_required', 'not_found', 'no_item_no', 'error')),
  our_unit_price numeric, purchases jsonb not null default '[]'::jsonb,
  best_unit_price numeric, best_vendor text, best_url text, savings_pct numeric,
  offers jsonb not null default '[]'::jsonb,
  quote_vendors jsonb not null default '[]'::jsonb,
  rejected jsonb not null default '[]'::jsonb,
  notes text, model text, cost_usd numeric, searches int, error text, raw_text text
);
create index if not exists kount_pc_checks_item on public.kount_pc_checks (item_id, checked_at desc);

alter table public.kount_pc_settings enable row level security;
alter table public.kount_pc_runs enable row level security;
alter table public.kount_pc_items enable row level security;
alter table public.kount_pc_checks enable row level security;
do $$
declare t text;
begin
  foreach t in array array['kount_pc_settings', 'kount_pc_runs', 'kount_pc_items', 'kount_pc_checks'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using '
      || '(public.kount_has_feature(''purchasing:order-tracker'') or public.kount_has_feature(''purchasing:order-prices''))', t || '_read', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- the function's bookkeeping (service role only)
create or replace function public.kount_pc_claim(p_n int)
returns setof public.kount_pc_items language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'service role only' using errcode = '42501'; end if;
  return query
  update public.kount_pc_items i set claimed_at = now()
   where i.id in (select c.id from public.kount_pc_items c
                   where c.active and c.checkable and c.due_at <= now()
                     and (c.claimed_at is null or c.claimed_at < now() - interval '15 minutes')
                   order by c.bought desc, c.due_at, c.item_key
                   limit greatest(1, least(p_n, 8))
                   for update skip locked)
  returning i.*;
end
$fn$;

create or replace function public.kount_pc_run_add(p_run uuid, p_cost numeric, p_done int)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'service role only' using errcode = '42501'; end if;
  update public.kount_pc_runs set cost_usd = cost_usd + coalesce(p_cost, 0), items_done = items_done + coalesce(p_done, 0) where id = p_run;
end
$fn$;

-- a person: the quote for an item ('requested' / 'received' with its price; null clears it)
create or replace function public.kount_pc_set_quote(p_item uuid, p_state text, p_vendor text, p_price numeric, p_note text)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if public.kount_has_feature('purchasing:order-tracker') is not true and public.kount_has_feature('purchasing:order-prices') is not true then
    raise exception 'The price check needs the Order tracker or Order prices permission' using errcode = '42501';
  end if;
  if p_state is not null and p_state not in ('requested', 'received') then raise exception 'state must be requested or received'; end if;
  if p_state = 'received' and (p_price is null or p_price <= 0) then raise exception 'a received quote needs its price per piece'; end if;
  update public.kount_pc_items set quote_state = p_state,
         quote_vendor = case when p_state is null then null else nullif(trim(p_vendor), '') end,
         quote_price = case when p_state = 'received' then p_price else null end,
         quote_note = case when p_state is null then null else nullif(trim(p_note), '') end,
         quote_by = case when p_state is null then null else auth.jwt() ->> 'email' end,
         quote_at = case when p_state is null then null else now() end,
         updated_at = now()
   where id = p_item;
  if not found then raise exception 'No such item'; end if;
end
$fn$;

create or replace function public.kount_pc_set_settings(p_enabled boolean, p_budget numeric, p_overpay numeric, p_model text)
returns void language plpgsql security definer set search_path to 'public', 'pg_temp' as $fn$
begin
  if public.kount_has_feature('purchasing:order-tracker') is not true then
    raise exception 'Changing the price check needs the Order tracker permission' using errcode = '42501';
  end if;
  if p_model is not null and p_model not in ('anthropic/claude-sonnet-5.5', 'anthropic/claude-opus-5.5', 'anthropic/claude-haiku-5.5') then
    raise exception 'model must be Sonnet 5.5, Opus 5.5 or Haiku 5.5';
  end if;
  update public.kount_pc_settings set enabled = coalesce(p_enabled, enabled), weekly_budget_usd = coalesce(p_budget, weekly_budget_usd),
         overpay_pct = coalesce(p_overpay, overpay_pct), model = coalesce(p_model, model), updated_at = now(), updated_by = auth.jwt() ->> 'email'
   where id = 1;
end
$fn$;

revoke all on function public.kount_pc_claim(int) from public, anon, authenticated;
revoke all on function public.kount_pc_run_add(uuid, numeric, int) from public, anon, authenticated;
grant execute on function public.kount_pc_claim(int) to service_role;
grant execute on function public.kount_pc_run_add(uuid, numeric, int) to service_role;
revoke all on function public.kount_pc_set_quote(uuid, text, text, numeric, text) from public, anon;
revoke all on function public.kount_pc_set_settings(boolean, numeric, numeric, text) from public, anon;
grant execute on function public.kount_pc_set_quote(uuid, text, text, numeric, text) to authenticated;
grant execute on function public.kount_pc_set_settings(boolean, numeric, numeric, text) to authenticated;

-- the schedule (the same call as the mail pull's: anon JWT for the gateway + the cron secret)
select cron.schedule('kount-price-check-weekly', '0 3 * * 6', $cmd$
  select net.http_post(
           url := 'https://mnraeesscqsaappkaldb.supabase.co/functions/v1/kount-price-check',
           headers := jsonb_strip_nulls(jsonb_build_object('Content-Type', 'application/json',
             'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'kount_edge_anon_jwt'),
             'x-kount-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'kount_order_mail_cron'))),
           body := '{"action":"weekly"}'::jsonb, timeout_milliseconds := 10000)
   where exists (select 1 from public.kount_pc_settings where id = 1 and enabled)
  $cmd$);

select cron.schedule('kount-price-check-work', '*/3 * * * *', $cmd$
  select net.http_post(
           url := 'https://mnraeesscqsaappkaldb.supabase.co/functions/v1/kount-price-check',
           headers := jsonb_strip_nulls(jsonb_build_object('Content-Type', 'application/json',
             'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'kount_edge_anon_jwt'),
             'x-kount-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'kount_order_mail_cron'))),
           body := '{"action":"work"}'::jsonb, timeout_milliseconds := 10000)
   where exists (select 1 from public.kount_pc_settings where id = 1 and enabled)
     and exists (select 1 from public.kount_pc_items where active and checkable and due_at <= now()
                    and (claimed_at is null or claimed_at < now() - interval '15 minutes'))
  $cmd$);

commit;
