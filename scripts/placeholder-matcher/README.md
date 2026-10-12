# Placeholder matcher

Matches R365 **"Missing Vendor Item"** invoice lines to the items a venue counts, so their
purchases reach the variance (`kount_invoice_line_map`, migrations 0071/0072).

R365 books a vendor line it can't match to an item as a placeholder with only qty and price.
h.wood AP's daily **"Item Missing exception report"** email (from hwoodap@iqbackoffice.com)
lists the vendor's item codes for exactly those lines — one code per line. This script reads
those reports and does the matching; it **never writes to the database**.

## Weekly run

1. Save the week's "Items Missing" email attachments (`.xlsx`) into one folder.
2. Run:

   ```
   python match_placeholders.py --reports "C:\path\to\that folder" --out "C:\path\to\output"
   ```

   Defaults are Alphabet (`--kount-venue v12 --ops-venue 4d2f6062-…`) and
   `--repo "C:/Github Projects/Restaurant-App"` (needs the supabase CLI linked there).
3. Open `placeholder-matches-v12-<date>.xlsx`: **Matched** (what will be loaded) and
   **Needs review** (ambiguous / no codes). Fix anything wrong.
4. Load the matched lines from the Restaurant-App folder:

   ```
   supabase db query --linked -f "C:\path\to\output\placeholder-matches-v12-<date>.sql"
   ```

   Undo is the `delete … where set_by = 'placeholder-matcher <date>'` line at the top of that file.
5. Recompute the venue's variance (Counting-Admin → Catalog → Recompute variance), or it
   recomputes on the next completed count.

## Rules (same as the 2026-10-08 load)

- A code only counts within the invoice's own vendor family (item numbers differ between distributors).
- A code already used by a loaded line on that invoice is not offered again (one code = one line).
- Line ↔ code pairing is by unit price on the same invoice (case or bottle, within 15%).
- Leftover lines: a price-only match is accepted only if exactly one counted item fits
  (cost × pack within 2%) and the vendor sells wine/spirits.
- Never a different bottle size from the one the venue counts.
- Produce/ice/food-vendor lines with no codes stay in **Needs review**.
