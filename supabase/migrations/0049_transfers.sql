-- =============================================================================
--  0048_transfers
--
--  Inter-venue stock transfers (e.g. Keys <-> Poppy). Records movements that
--  affect AVT theo: a transfer-IN behaves like a purchase (raises theo at the
--  receiving venue), a transfer-OUT like a depletion (lowers theo at the
--  sending venue). No compute change here -- the shared compute_avt_for_audit
--  is intentionally left untouched (Poppy-only rollout); recompute reads these
--  tables via a one-off query with a transfers arm.
--
--  Apply manually via `supabase db query --linked` -- never `supabase db push`.
-- =============================================================================

begin;

create table if not exists public.transfers (
  id               uuid primary key default gen_random_uuid(),
  transfer_date    date not null,
  from_venue_id    uuid references public.venues(id),
  to_venue_id      uuid references public.venues(id),
  from_venue_name  text,          -- free-text fallback / external counterparty
  to_venue_name    text,
  total_amount     numeric(14,2),
  organization_id  uuid,
  external_source  text,          -- e.g. 'craftable', 'manual-entry'
  note             text,
  created_by_email text,
  created_at       timestamptz not null default now()
);

create table if not exists public.transfer_lines (
  id             uuid primary key default gen_random_uuid(),
  transfer_id    uuid not null references public.transfers(id) on delete cascade,
  master_item_id uuid references public.master_items(id),
  description    text,
  qty            numeric(14,3) not null,   -- in count units (bottles/cans)
  unit_cost      numeric(14,4),
  line_total     numeric(14,2),
  note           text,
  created_at     timestamptz not null default now()
);

create index if not exists idx_transfers_from        on public.transfers(from_venue_id, transfer_date);
create index if not exists idx_transfers_to          on public.transfers(to_venue_id, transfer_date);
create index if not exists idx_transfer_lines_xfer   on public.transfer_lines(transfer_id);
create index if not exists idx_transfer_lines_master on public.transfer_lines(master_item_id);

-- RLS: read-only for authenticated (mirrors the existing kount_* pattern); no
-- write policy, so only service-role / definer functions can mutate.
alter table public.transfers      enable row level security;
alter table public.transfer_lines enable row level security;
create policy transfers_sel      on public.transfers      for select to authenticated using (true);
create policy transfer_lines_sel on public.transfer_lines for select to authenticated using (true);

commit;
