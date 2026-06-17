# Backup & restore runbook

Backstop for the Counting-App / Counting-Admin data. **The Postgres database is SHARED**
with KevaOS / Restaurant-App (project ref `mnraeesscqsaappkaldb`). That single fact drives
every decision below: a full-database restore would roll back the other apps too, so the
default posture is **logical, table-scoped backup/restore of the app's own tables**, and a
full restore is a break-glass action coordinated with the other apps' owners.

## What is "this app's data"

| Group | Tables |
|---|---|
| **Counting (app-owned, highest value)** | `kount_audits`, `kount_entries`, `kount_recounts`, `kount_members`, `kount_venues`, `kount_venue_zones`, `kount_carried_items`, `kount_pending_items`, `kount_avt_reports`, `kount_avt_rows`, `app_users`, `upc_mappings` |
| **Catalog / recipes (shared but app-critical)** | `master_items`, `master_item_upcs`, `purchase_items`, `new_recipes`, `new_recipe_ingredients`, `new_recipe_ingredient_master_map`, `new_recipe_pos_skus`, `menu_item_recipe_map` |
| **Shared / upstream (owned by KevaOS — do NOT restore from here)** | `pos_check_items`, `invoices`, `invoice_lines`, `v_effective_receipts`, `venues`, `receiving_events` |

The `kount_*` group is the irreplaceable data — physical counts can't be re-derived.

## Layer 1 — Supabase managed backups (already on, verify cadence)

Supabase takes **automatic daily backups** of the whole project (retention depends on the
plan; Pro adds Point-in-Time Recovery). Check / configure in the dashboard:
**Project → Database → Backups**.

- These are **full-project** snapshots → restoring one rolls back KevaOS + Restaurant-App
  too. Treat as disaster-recovery only, coordinated with the other teams.
- **Action item:** confirm the plan's retention covers your risk window (a counting cycle
  can span weeks); if PITR isn't enabled and the data justifies it, enable it.

## Layer 2 — Logical, table-scoped backups (the one you run)

Run from `c:\Github Projects\Counting-App` (the CLI is linked to the project). These are
plain `.sql` you can inspect and selectively restore — the safe default for a shared DB.

```bash
# Schema + data for the counting tables (recommended cadence: before each migration
# and before/after each real audit close).
supabase db dump --linked --data-only \
  -t public.kount_audits -t public.kount_entries -t public.kount_recounts \
  -t public.kount_members -t public.kount_venues -t public.kount_venue_zones \
  -t public.kount_carried_items -t public.kount_pending_items \
  -t public.kount_avt_reports -t public.kount_avt_rows \
  -t public.app_users -t public.upc_mappings \
  -f backups/kount_data_$(date +%Y%m%d).sql      # stamp the filename yourself; CI/scripts can't use Date.now in workflow scripts

# Full schema (DDL) snapshot — cheap, do it alongside:
supabase db dump --linked --schema-only -f backups/schema_$(date +%Y%m%d).sql
```

Notes:
- `supabase db dump` shells out to `pg_dump` over the linked connection. If the CLI version
  errors, a direct `pg_dump "$DATABASE_URL" --data-only -t public.kount_*` is the fallback
  (get the connection string from **Project → Settings → Database**; never commit it).
- Store dumps **outside the public repo** — they contain operational data. Add `backups/`
  to `.gitignore` if you keep them in-tree, or push to a private bucket.
- A quick ad-hoc read-only snapshot of a single table is also fine via
  `supabase db query --linked "select * from kount_avt_rows where ..."` piped to a file.

## Restore

**Default (table-scoped, safe):** restore one or more `kount_*` tables from a logical dump.
This does NOT touch the other apps.

```bash
# Inspect the dump first. Then, for a clean table-level restore, truncate + reload inside a
# transaction (adjust to your dump's INSERT/COPY form). Test on a non-prod target if possible.
supabase db query --linked --file backups/kount_data_YYYYMMDD.sql
```

- The dump is `--data-only`, so the table must already exist (schema unchanged). For a
  destructive reload, wrap `truncate ...; <inserts>` in `begin; ... commit;` and verify row
  counts before committing.
- **FK order matters:** restore parents before children (`kount_audits` before
  `kount_entries`/`kount_recounts`; `master_items` before `kount_carried_items`).
- Idempotency: prefer `insert ... on conflict do nothing/do update` over blind inserts so a
  partial re-run is safe.

**Break-glass (full-project):** only via the Supabase dashboard managed backup / PITR, and
only after confirming with the KevaOS / Restaurant-App owners — it rolls back their data to
the snapshot time as well.

## Recommended cadence

- **Before every migration apply** → `--schema-only` + `--data-only` of affected tables
  (the migration ledger in `migrations/APPLIED.md` is the trigger).
- **Around each real audit** → `--data-only` of the `kount_*` group before Count 1 close and
  after Count 2 close (the counts are the un-recreatable asset).
- **Verify Layer 1 retention** quarterly.
