# HWOOD Count

Mobile-first inventory counting app for H.Wood Group venues. PWA with barcode scanning, photo OCR, manual entry, Craftable AVT variance analysis, and Count 1 / Count 2 audit lifecycle.

## Venues

- Delilah LA
- Delilah Miami
- The Nice Guy
- The Birdstreet Club
- Poppy
- Keys

## Features

- **Barcode scanning** — Native BarcodeDetector API with QuaggaJS fallback
- **Photo label parsing** — On-device OCR (Tesseract.js) with image preprocessing + inventory search fallback
- **Manual entry** — Autocomplete search against 4,592 Bevager inventory items
- **Craftable AVT integration** — Upload AVT reports, auto-parse variance data
- **Severity scoring** — CRITICAL / HIGH / MEDIUM / WATCH / LOW (matches workflow app logic)
- **Count 1 → Recount → Count 2 lifecycle** — Full audit flow with recount focus list
- **CSV exports** — Count 1 and Count 2 reports with severity breakdown
- **Email-based access control** — Role-based (corporate/manager/counter) with venue assignments
- **Mobile-first PWA** — Works offline, installable on phone home screen

## Files

```
index.html           ← Redirects to counting-app.html
counting-app.html    ← The app (single file, ~155 KB)
items.json           ← Bevager inventory (4,592 items, ~290 KB)
manifest.json        ← PWA manifest
sw.js                ← Service worker for offline support
.nojekyll            ← Tells GitHub Pages to skip Jekyll
404.html             ← Redirects back to app
README.md            ← This file
```

## Access Control

Edit the `ACCESS_LIST` array in `counting-app.html` to add/remove users:

```javascript
const ACCESS_LIST = [
  { email: 'admin@hwood.com', name: 'Admin', role: 'corporate', venueIds: 'all' },
  { email: 'manager1@hwood.com', name: 'Manager 1', role: 'manager', venueIds: ['v1', 'v2', 'v3'] },
  { email: 'counter1@team.com', name: 'Counter 1', role: 'counter', venueIds: ['v1', 'v2'] },
];
```

Venue IDs: v1=Delilah LA, v2=Delilah Miami, v3=The Nice Guy, v4=The Birdstreet Club, v5=Poppy, v6=Keys

## Audit Workflow

1. Admin uploads Craftable AVT report (Variance tab, admin only)
2. Manager starts audit at a venue
3. Counters do Count 1 (scan, photo, manual across all zones)
4. Manager closes Count 1 → app generates severity-scored recount list
5. Admin optionally uploads fresh AVT report
6. Counters do Count 2 (flagged items only, with severity badges)
7. Manager closes Count 2 → final report generated
8. Export Count 1 CSV and Count 2 CSV

## Future

- Supabase integration (replace localStorage + CSV with live API)
- Live sync across multiple users (Supabase Realtime)
- Slack issue parsing integration with inventory workflow app
- Claude Vision API for label parsing (when API key available)
