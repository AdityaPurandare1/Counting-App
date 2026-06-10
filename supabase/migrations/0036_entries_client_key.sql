-- =============================================================================
--  0036_entries_client_key
--
--  Idempotent entry-sync support for the phone.
--
--  Problem: when the phone POSTs a count entry and the RESPONSE is lost
--  (tunnel/wifi drop after the server committed), the client retries. The
--  merge-key upsert (audit_id, zone, item, is_recount) then treats the retry
--  as a NEW scan of the same item and double-merges qty (5 + 5 = 10 instead
--  of 5). With a client-generated key, the replay can detect the
--  already-committed row instead.
--
--  Mechanism: the phone sends its local entry id (a per-tap UUID/string
--  minted BEFORE the first send and reused on every retry) as
--  client_entry_id. The partial unique index on (audit_id, client_entry_id)
--  makes a replayed insert fail with 23505; the client catches it and looks
--  up the committed row by (audit_id, client_entry_id), adopting its id
--  instead of re-merging qty. (NOT ON CONFLICT: PostgreSQL only infers a
--  partial unique index as an arbiter when the conflict target includes the
--  WHERE predicate, which PostgREST does not send — so the real flow is
--  insert → 23505 → lookup.)
--  Scoped per audit so phones don't need globally-unique ids; partial
--  (WHERE client_entry_id IS NOT NULL) so legacy rows and old clients that
--  don't send the column are unaffected.
--
--  Schema-only and additive — no behavior change until the phone client
--  starts sending client_entry_id.
--
--  Apply manually via `supabase db query --linked` — repo migrations are NOT
--  CLI-tracked; never `supabase db push`.
--
--  Idempotent: IF NOT EXISTS on both statements.
-- =============================================================================

alter table public.kount_entries
  add column if not exists client_entry_id text;

create unique index if not exists kount_entries_client_key
  on public.kount_entries (audit_id, client_entry_id)
  where client_entry_id is not null;

comment on column public.kount_entries.client_entry_id is
  'Phone-local entry id, minted before first send and reused on retries. Unique per audit (partial index kount_entries_client_key) so a replay after a lost response detects the already-committed row instead of double-merging qty. NULL for legacy rows and clients that predate 0036.';

-- -----------------------------------------------------------------------------
-- Verification (run after applying)
-- -----------------------------------------------------------------------------
--
--   select count(*) from kount_entries where client_entry_id is not null;
--   -- expect 0 immediately after apply (no client sends it yet)
--
--   select indexdef from pg_indexes
--    where indexname = 'kount_entries_client_key';
--   -- expect: UNIQUE ... (audit_id, client_entry_id) WHERE client_entry_id IS NOT NULL
