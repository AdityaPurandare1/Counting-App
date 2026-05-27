# Counting-App robot-QA suite

Playwright "personas" (corporate / manager / counter) drive the **real**
`counting-app.html` in a headless phone-sized browser, against a **faithful
in-memory Supabase mock**. No production data is touched.

## Run

```bash
cd tests
npm install                       # one-time
npx playwright install chromium   # one-time (downloads the browser)
npm test                          # run the whole suite
npm run report                    # open the HTML report
```

Filter / debug:

```bash
npx playwright test 02-counting            # one file
npx playwright test --headed               # watch it run
npx playwright test --debug                # step through
```

## What it covers (22 tests)

| File | Covers |
|------|--------|
| `01-auth-and-start` | login (3 roles), unknown-user rejection, manager starts a networked audit (join code + `kount_audits`), a counter joins by code |
| `02-counting` | manual add → master linking, **merge/dedup** (sums, no duplicate), +/- adjust, custom (non-catalog) item |
| `03-move-and-allcount` | move an item between zones in place (no delete+re-add), **All Count** cross-zone totals + per-zone edit |
| `04-catalog-and-search` | corporate **Add to catalog** (creates `master_items` + links), non-corporate **Suggest** (pending), carried-vs-full-catalog search divider |
| `05-lifecycle` | Count 1 close → review → Count 2 close → submitted |
| `06-regressions` | the safety net (see below) |
| `07-units` | `visibleSku`, `masterCategoryForCreate`, `parseBottleSize`, `searchItemMaster` |

## The safety net (`06-regressions`)

These are the tests that would have caught the 13-day outage and the
readability/permission issues:

- **`item_id` FK** — writing a `master_items` id into `kount_entries.item_id`
  is rejected (Postgres `23503`), exactly as production does; `item_id: null`
  is accepted. *(This is the exact outage bug.)*
- **`master_items` RLS** — a non-corporate user is blocked (`42501`); a
  corporate user succeeds.
- **UUIDs hidden / full name shown** — the count card shows the full item
  name and never the raw master UUID.

## How the mock works

- `mock/fixtures.js` — seed catalog, venues, app_users, carried set, UPCs.
- `mock/mockdb.js` — a PostgREST-ish query engine **plus the real schema
  constraints**: the `item_id→purchase_items` and `master_item_id→master_items`
  FKs, the `kount_entries` unique-merge index, and corporate-only `master_items`
  RLS (resolved from the request's auth). All browser contexts share one DB
  instance per test, so personas see consistent state.
- `fixtures.js` — Playwright base: per-test mock DB, browser stubs (Supabase
  client/auth/realtime, camera, BarcodeDetector, OCR, vibrate), request routing
  (`supabase.co` → mock; CDN libs → stubbed), and human-like helpers
  (`loginAs`, `startAuditAs`, `joinAuditAs`, `addManual`, …).

## Known scope

Cross-client realtime echo isn't emulated (the channel stub reports
SUBSCRIBED); merge correctness is proven via the mock's unique constraint
instead. The native camera scan path is stubbed (BarcodeDetector returns a
configured code); the barcode *entry* logic is exercised through the UI.
