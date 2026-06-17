# kΩunt — Counting App

Mobile-first PWA for physical inventory counting at the h.wood Group venues. Counters
use it on phones to scan, photograph, or hand-key bottle counts through a
Count 1 → Recount → Count 2 audit lifecycle. It is the field half of a pair: the
desktop **Counting-Admin** app drives audit setup, review, and reporting. Both apps
talk to the **same Supabase project** (`mnraeesscqsaappkaldb`).

The app is a single static HTML file (`counting-app.html`, ~14.9k lines of vanilla JS,
no build step) plus a service worker. It is served from GitHub Pages.

## Architecture

```
index.html        ← meta-refresh redirect to counting-app.html
counting-app.html ← the entire app: UI, state, Supabase REST client, scanning
sw.js             ← service worker (network-first cache of static assets only)
manifest.json     ← PWA manifest (installable, standalone, portrait)
404.html          ← (present for SPA-style fallback on Pages)
.nojekyll         ← tells GitHub Pages to skip Jekyll
items.json        ← static catalog fallback used only if Supabase is unreachable

supabase/
  migrations/     ← SQL migrations 0001–0040 (see "Database migrations" below)
  functions/      ← Edge Functions: parse-bottle-label, admin-user-mgmt, _shared
  tests/          ← ad-hoc SQL (smoke_compute_avt.sql, poppy_* mapping helpers)
  recipes/        ← recipe-ingestion tooling + per-venue review TSVs

tests/            ← Playwright end-to-end suite (see "Testing")
```

### Version lockstep — read this before any deploy

`APP_VERSION` in `counting-app.html` and `CACHE_NAME` in `sw.js` are a cache-bust pair
and **must be bumped together, in lockstep, on every deploy** (currently both `1.76`).
The service worker is network-first for static assets, so a deploy normally lands
immediately online; the version bump guarantees stale caches are evicted on activate and
that offline devices pick up the new build. Bump `APP_VERSION` by 0.1 even for tiny
commits. The `hwood-count-` cache prefix is a deliberate legacy identifier — change only
the version digits, never the prefix (renaming orphans existing device caches).

The service worker caches **same-origin static assets only** (the files listed in
`STATIC_BASENAMES` plus image/font extensions). Everything dynamic — Supabase REST,
Edge Functions, auth, third-party CDNs — bypasses the SW entirely and is never stored or
served stale.

## Features

- **Barcode scanning** — native `BarcodeDetector` API where available, with a QuaggaJS
  fallback (loaded from CDN) for iOS Safari and other browsers that lack it.
- **Instant scan-to-count** — a scanned UPC that resolves to a known catalog item
  increments its running count immediately, with an on-screen confirmation and an Edit
  affordance; no form round-trip.
- **Photo label parsing** — capture a bottle photo and get back a structured item
  match. Three-tier fallback (see below): Claude via the `parse-bottle-label` Edge
  Function (primary), browser-side OpenAI, then on-device Tesseract.js as the offline
  last resort.
- **Manual / guided count** — autocomplete search over the live master catalog with
  typo tolerance; a unified guided count view with +/- steppers and partial-bottle
  entry.
- **Zones** — counts are scoped to venue zones; the count view toggles between
  **This Zone**, **All Count** (totals across zones), and **List** (the carried-item
  reference list for the venue).
- **Count 1 → Recount → Count 2 lifecycle** — full audit flow; closing Count 1 produces
  a recount focus list, and Count 2 corrections are stored as the canonical overrides.
- **Computed variance (AVT)** — see below.
- **CSV export** — reports export as CSV with a UTF-8 BOM and `charset=utf-8` so
  accented item and reporter names render correctly in Excel.
- **Installable PWA** — works offline (static shell cached), installs to the phone home
  screen.

### Photo label parsing — what actually runs

`parsePhotoLabel()` tries, in order:

1. **Claude** via the `parse-bottle-label` Supabase Edge Function (`functions/v1/
   parse-bottle-label`). The Anthropic key lives in Supabase secrets and never reaches
   the client. This is the primary, highest-accuracy path. The function sends a
   deterministically-sorted catalog snapshot (first ~400 items) with prompt caching.
2. **OpenAI** browser-side, if a client OpenAI key is present.
3. **Tesseract.js** on-device OCR (CDN worker + wasm core) — the offline fallback so a
   transient API failure never leaves a counter stuck.

> Note: Craftable/Bevager AVT **upload is fully removed.** Any `not-in-craftable` token
> still present in the code is a persisted `kount_entries.issue` value matched by the
> admin Issues page; only the visible label changed (now "Not in inventory").

## Computed variance (AVT) model

Variance is **computed server-side**, not uploaded. The `compute_avt_for_audit(p_audit_id)`
RPC runs at **Count 1 close** and again at **Count 2 close**, writing a
`kount_avt_reports` row tagged `source='computed'` that the admin Variance UI renders.

For each master item in a zone:

```
theoretical = starting count + purchases − depletions
actual      = live audit counts (kount_entries, summed; recount overrides win)
variance    = actual − theoretical
```

Four data sources feed it, all already in this Supabase:

- **Physical counts** — `kount_entries` (and `kount_recounts` for Count 2 corrections,
  which are the canonical override store).
- **Purchases / invoices** — effective receipts (`v_effective_receipts`), scoped by
  invoice date.
- **POS sales** — `pos_check_items`.
- **Recipes** — POS sales are converted to depleted master units via recipe/menu-item
  maps (direct bottle-service maps and the new-recipe ingredient bridge), with units
  normalized to whole sellable master units.

The catalog itself is **`master_items`** based (Path B): the in-scope bar/bev/liquor
categories are loaded and paginated live from Supabase (`items.json` is only a fallback
when Supabase is unreachable). Do not cite a fixed item count — the catalog is live.

> **FK rule:** never write a master id into the legacy `item_id` column. Path B master
> ids belong in `master_item_id`; writing one into `item_id` fails the FK (23503).

Migration lineage of the RPC: `0030` (initial computed pipeline) → `0032` → `0035` (v3,
recount overrides from `kount_recounts`) → `0037` (v4, unit normalization) → `0038`
(Count 1 window) → `0039` (purchases by invoice date).

## Venues

Venues are **dynamic**, configured in the admin and stored in the `venues` /
`kount_venues` tables (bridged via `kount_venues.ops_venue_id`). There is no hardcoded
venue list — do not treat any fixed roster as authoritative.

## Deployment

Deploys run through **GitHub Actions** (`.github/workflows/deploy.yml`), gated on tests:

1. `test` job — installs `tests/` deps, installs Chromium, runs the full Playwright suite.
2. `build` job (`needs: test`) — assembles the publish dir (`index.html`,
   `counting-app.html`, `sw.js`, `manifest.json`, `404.html`, `.nojekyll`, `items.json`).
3. `deploy` job — publishes to GitHub Pages.

A failing Playwright suite blocks the deploy. This replaced the previous direct,
branch-based publishing. The repo's **Settings → Pages → Source must be "GitHub Actions"**
for this workflow to take effect.

Remember the version lockstep above before pushing.

## Testing

```
cd tests
npm install        # first time
npm test           # runs the Playwright suite
```

- **62 tests**, Playwright, **serial** (`workers: 1`, `fullyParallel: false`) — the
  personas share one in-memory mock DB, so they cannot run in parallel.
- Phone-sized viewport (Pixel 5 / 414×896); service workers are blocked in tests so the
  PWA cache doesn't intercept.
- Served by a local `static-server.js` on port 5599.
- Watch a run: `PW_SLOWMO=<ms> npx playwright test --headed`.

## Database migrations

Migrations are **NOT** tracked by the Supabase CLI. Apply each one explicitly against
the linked project:

```
supabase db query --linked --file supabase/migrations/0040_repoint_carried_to_active.sql
```

**Never run `supabase db push`** — it would diverge from the actual prod schema. Files
are numbered `0001`–`0040`; each header documents its intent and idempotency.

## Access control

Access is role-based (corporate / manager / counter) with per-venue assignments,
managed through the admin and the `admin-user-mgmt` Edge Function. (The old in-file
`ACCESS_LIST` array documented in prior READMEs is no longer the source of truth.)
