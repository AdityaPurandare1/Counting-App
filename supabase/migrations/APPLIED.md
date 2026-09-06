# Migration apply-log (prod ledger)

**Why this file exists:** the repo's migrations are **NOT** tracked by the Supabase
CLI. The remote `supabase_migrations.schema_migrations` table is divergent (it holds
hundreds of versions never in this repo), so `supabase db push` **fails** and its
suggested repairs would corrupt history. Every migration here was/will be applied by
hand. There is no automatic record of *when* each was applied — **this file is that
record.** Update it every time you apply a migration to prod.

## How to apply a migration (the only supported path)

```bash
# from c:\Github Projects\Counting-App  (CLI is linked to mnraeesscqsaappkaldb)
supabase db query --linked --file supabase/migrations/<NNNN_name>.sql
# read-back verification:
supabase db query --linked "select ..."
```

- **NEVER** run `supabase db push`, `supabase migration repair`, or `supabase db pull`
  against this project — they assume CLI-tracked history that does not exist here and
  will corrupt the repo/remote.
- Keep every migration **idempotent** (`create ... if not exists`, `create or replace`,
  guarded `update`/`delete`) — nothing stops a re-run, so re-running must be safe.
- **The DB is SHARED** with KevaOS / Restaurant-App. A migration here can affect them.
  Scope changes to the `kount_*` tables, `master_items`, recipe tables, and the
  `compute_avt_for_audit` / `import_inventory_csv` RPCs; don't touch shared procurement
  tables without checking the other apps.
- After applying: add/append the row below, run the migration's own verification block,
  and (for app-facing changes) bump `APP_VERSION` + `sw.js` `CACHE_NAME` in lockstep.

## Ledger

Status legend: ✅ applied & verified · ⚠️ applied, see note.
Dates are the prod-apply date. Pre-0029 migrations were applied via the Supabase SQL
editor over the project's early history; individual dates were not recorded (marked
"early history") — they are all live (their objects exist in prod).

| #    | File                                   | Applied      | Notes |
|------|----------------------------------------|--------------|-------|
| 0001–0028 | (multi-user audits → Path B catalog) | early history | ✅ Applied by hand via SQL editor before this ledger existed. Includes the Path B move of the catalog from `purchase_items` → `master_items` (0023–0028). Objects confirmed live. |
| 0029 | kount_recounts_master_id               | 2026-05-27   | ✅ Adds `master_item_id` + partial index + backfill; 727 existing rows name-derived (0 backfilled, expected). |
| 0030 | kount_avt_computed                     | early June 2026 | ✅ Computed-AVT path; replaces the Craftable AVT-upload dependency. |
| 0031 | kount_avt_venue_scoped_select          | early June 2026 | ✅ Venue-scoped AVT select. |
| 0032 | avt_recipe_bridge_join_fix             | early June 2026 | ⚠️ A "demo purge" in this one deleted bridge rows for venue `1111…` (real Delilah LA) — its recipe bridge may need rebuilding. |
| 0033 | carried_items_master_key               | 2026-06-10   | ✅ Re-keys `kount_carried_items` on `master_item_id` (unique idx `kount_carried_items_master_item_uniq`); `purchase_item_id` unique idx also present. |
| 0034 | fix_import_inventory_csv               | 2026-06-10   | ✅ Fixes 6-vs-7 column INSERT bug; Path B carried resolution; replace-mode only deletes `master_item_id IS NULL` rows. |
| 0035 | compute_avt_v3                         | 2026-06-10   | ✅ Recount overrides from `kount_recounts.count2_qty`; per-(master,zone) SUM; per-POS-item depletion dedup. |
| 0036 | entries_client_key                     | 2026-06-10   | ✅ `client_entry_id` column + unique index for insert idempotency. |
| 0037 | compute_avt_v4_units                   | 2026-06-11   | ✅ Per-line unit→ml→bottle-fraction via `master_items.base_size/base_unit`; bottle-service-only direct arm; UOM-normalized purchases. Applied with bottle flags + 75 recipe bridges → 50 recipes + Poppy baseline audit. |
| 0038 | avt_window_count1                      | 2026-06-12   | ✅ Window end = `coalesce(count2_closed_at, completed_at, count1_closed_at)` so AVT computes at Count 1 close (was 22023 error). |
| 0039 | avt_purchases_invoice_date             | 2026-06-15   | ✅ Purchases window falls back to `invoices.invoice_date` when `v_effective_receipts.received_at` is NULL. NOTE: upstream invoice-LINE ingestion for hwood venues is still broken (Poppy silent since 2026-04-21) — not app-fixable. |
| 0040 | repoint_carried_to_active              | 2026-06-17   | ✅ Re-pointed 296 carried rows off archived masters onto the active same-name twin (collision-guarded), pruned 879 unresolvable. Post-commit verify = 0 carried rows pointing at an inactive master. |
| 0041 | client_error_log                       | 2026-06-17   | ✅ New `kount_client_errors` telemetry table (12 cols). RLS: INSERT for anon+authenticated, SELECT for authenticated corporate only. Both indexes present. |
| 0042 | recounts_replica_identity_full         | 2026-06-21   | ✅ `kount_recounts` → REPLICA IDENTITY FULL so realtime UPDATE/DELETE events carry audit_id for the filter (Count-2 recount edits now propagate across devices). |
| 0043 | effective_receipts_master_bridge       | 2026-06-24   | ✅ `v_effective_receipts.master_item_id` now `COALESCE(il.master_item_id, pi.master_item_id)`. R365-synced lines populate only `item_id` (purchase_items), leaving master null; the view already joined purchase_items, so this surfaces the bridged master. Purchases reached AVT for the first time. View-only, additive. |
| 0045 | app_users_role_viewer                  | 2026-06-29   | ✅ Widened `app_users_role_check` to allow `venue_manager` (display "Venue Management"); additive read-only role. Shared app_users/KevaOS — widening a CHECK is safe. Read-back confirmed 4-role list. |
| 0044 | master_merge_redirect_bridge           | 2026-06-24   | ✅ New `master_items.merged_into_id` redirect (folded twin→active canonical). 2217 archived masters auto-pointed by (canonical-key, size-in-ml); 5 explicit exceptions (Estrella, Dom P Brut Luminous, Red Bull SF, BIB OJ/Cranberry). `v_effective_receipts` follows the redirect so purchases routed to dead twins land on the canonical the counts use. Poppy stranded purchases 51→2 (leftover = ambiguous "Lime" garnish). Additive column + view; existing FKs untouched. NOTE: residual P-539 variance is now purchase-LINE completeness (R365 still ~80% of June lines; e.g. Hennessy 0 lines, Don Julio Repo only 22 btl) — upstream, not mapping. |
| 0046 | clear_avt_on_audit_cancel              | 2026-06-30   | ✅ Trigger `trg_kount_clear_avt_on_cancel` on `kount_audits` AFTER UPDATE OF status: active→cancelled deletes the audit's `kount_avt_reports` (rows cascade). Stops a cancelled, barely-counted audit's junk report from driving the venue variance (report selectors order by source/uploaded_at and ignored audit status). One-time cleanup deleted Poppy P-282's −$214k report (290/292 items actual=0); v5 fell back to P-075 (+$66,603). Left the one other cancelled-audit report (different venue, no fallback) untouched. |
| 0047 | merge_master_items                     | 2026-07-09   | ✅ Corporate-only RPC `merge_master_items(winner, losers[], dry_run)` to fold duplicate master_items: repoints counting-owned tables (kount_entries/recounts/carried/pending, master_item_upcs, upc_mappings) loser→winner, collapses redirect chains, sets loser.merged_into_id + is_active=false. No compute_avt change (loser drops out of all_masters after repoint; purchases already redirect via 0044). Function created; validated via dry_run on the PJ 'Blanc de Blanc(s)' 750ml pair (1 entry + 1 recount + 2 dup carried, 1 affected audit); then 23 dup masters folded (pilot + batch of 22), affected audits recomputed. Powers the admin Catalog "Merge duplicates" panel. |
| 0048 | lock_app_users_writes                  | 2026-07-09   | ✅ SECURITY: revoked anon/authenticated INSERT/UPDATE/DELETE on `app_users` + dropped the 6 dev_/auth_dev_app_users write policies (kept SELECT). Closes the self-escalation hole (Ares review): the public anon key could INSERT/UPDATE a row to role='corporate', defeating every corporate gate incl. merge_master_items. SAFE — all real writes go through the admin-user-mgmt Edge Function (service_role, bypasses RLS); KevaOS doesn't touch app_users. Verified: only SELECT policies/grants remain; anon INSERT now → HTTP 401, 0 rows landed. Open follow-on (gated to its own session): same lockdown for `master_item_upcs` + `upc_mappings` (needs client rerouting of 13 write sites through RPCs first). |

| 0051 | restore_kount_select_policies          | 2026-09-06   | ✅ INCIDENT FIX. Poppy could not start an audit ("Could not create the shared audit (network issue)"). The KevaOS team's CLI migration `close_public_all_rls_policies` (`supabase_migrations.schema_migrations` version `520260902162539`, applied 2026-09-02 16:25 UTC) swept every `public`/`anon`-targeted RLS policy in the schema. `kount_entries`/`members`/`recounts`/`carried_items` survived because their SELECT is `auth_dev_*_select` scoped to `{authenticated}`; **`kount_audits` and `kount_venue_zones` had no such policy — their SELECT came from a `public`-scoped one, and `public` covers `authenticated`, so signed-in managers lost read too.** That breaks audit CREATION because `supabaseRest.insert` sends `Prefer: return=representation` (counting-app.html ~3296) and `startNetworkedAudit` requires the row back (~5768): PostgREST inserts, re-reads to return it, the read is denied, the statement rolls back. Fix re-adds SELECT for `{authenticated}` on both tables (`using (true)`, matching the surviving sibling policies) and grants anon EXECUTE on `vendor_visible_venue_ids()` — the `venues_select_vendor` policy is `{public}` and calls it, so anon was getting `42501 permission denied for function` on every venues read; `is_platform_admin`/`is_super_admin` already carry `anon=X`. Verified after: both SELECT policies present, **0 anon policies remain on any kount_\* table** (their tightening preserved), and anon `GET /venues` returns `[]` + HTTP 200 (no rows exposed — the grant replaced a crash with an empty result). NOT the end state: venue-scoped policies keyed off `app_users.venue_ids` are still the right shape (the G3 gap). **None of the 672 CLI migrations mentions `kount` — that team does not model these tables, so this was collateral, not intent.** |

> When you apply the next migration, add its row here with the real date and a one-line
> note, and confirm its verification block returned the expected result.

### Written but NOT yet applied

| #    | Name                | Status | Note |
|------|---------------------|--------|------|
| 0049 | transfers           | ⏳ pending | Inter-venue stock transfers. Renamed from `0048_transfers.sql` on 2026-08-10 to clear a filename collision with the applied `0048_lock_app_users_writes`. Unapplied, so the renumber is safe. |
| 0050 | entry_delete_log    | ⏳ pending | Drops the ad-hoc `_guard_block_active_entry_delete` trigger (never captured as a migration) and replaces it with a `_log_kount_entry_delete` BEFORE-DELETE trigger writing row snapshots to a new `kount_entries_deleted_log`. The guard `return null`s — silently CANCELS — every delete on an `active` audit, which breaks moveEntryToZone's merge path (source row survives → the 12s reconcile re-adds it → "the whole list re-shows up", and the moved qty double-counts) and adjustQuantity's remove-from-count. Ships with phone v1.99. **Apply before/with the v1.99 deploy** — v1.99's recount location move uses the same merge path. |
