// resolve_ambiguous_upcs.mjs
//
// One-shot data-cleanup script for the master_item_upcs migration.
//
// Pulls the 230 UPCs whose backfill into master_item_upcs landed on the
// wrong (ambiguous) master, looks each one up via UPCitemDB and Open Food
// Facts, and tries to assign it to the correct size variant.
//
// Resolution priority per UPC:
//   1. API says size = X ml AND exactly one candidate's base_size = X ml → match.
//   2. Exactly one candidate has no size in its name AND has a non-null
//      base_size — it's the "base SKU" that the others were spawned from.
//      Attach the UPC there.
//   3. Otherwise — log to master_item_upcs_review, keep as ambiguous.
//
// Outputs a JSON summary on stdout AND emits SQL statements (to stderr or a
// file) to apply the resolutions. Caller pipes the SQL into
// `supabase db query --linked --file ...`.

const SUPABASE_URL = 'https://mnraeesscqsaappkaldb.supabase.co/rest/v1';
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1ucmFlZXNzY3FzYWFwcGthbGRiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjI2MzkxNzQsImV4cCI6MjA3ODIxNTE3NH0.QaPiMs48H9nsH7wGNhi_1jYRQ_YAPGLduxSpYOrz1ug';

const H = { apikey: ANON_KEY, Authorization: 'Bearer ' + ANON_KEY };

// ---- helpers --------------------------------------------------------------

const sleep = ms => new Promise(r => setTimeout(r, ms));

function normalize(upc) {
  return String(upc || '').replace(/\D/g, '').replace(/^0+/, '');
}

function toMl(size, unit) {
  if (size == null || unit == null) return null;
  const u = String(unit).toLowerCase();
  const v = Number(size);
  if (!Number.isFinite(v)) return null;
  if (u === 'ml') return v;
  if (u === 'l')  return v * 1000;
  if (u === 'cl') return v * 10;
  if (u === 'oz' || u === 'fl.oz' || u === 'floz' || u === 'fl oz') return v * 29.5735;
  return null;
}

const SIZE_RX = /(\d+(?:\.\d+)?)\s*(ml|cl|l|oz|fl\.?\s*oz|fluid\s*ounce)/gi;

function parseSizeMl(text) {
  if (!text) return null;
  let m;
  const matches = [];
  SIZE_RX.lastIndex = 0;
  while ((m = SIZE_RX.exec(text)) !== null) {
    matches.push({ v: Number(m[1]), u: m[2].toLowerCase().replace(/\s+/g, '').replace('.', '') });
  }
  if (matches.length === 0) return null;
  // Prefer the largest size hit — most API titles also include sub-sizes
  // like "12 pack" or "case of 6" that we don't want to lock onto.
  const ml = matches.map(x => {
    if (x.u === 'ml') return x.v;
    if (x.u === 'cl') return x.v * 10;
    if (x.u === 'l') return x.v * 1000;
    if (x.u.includes('oz') || x.u.includes('fluid')) return x.v * 29.5735;
    return null;
  }).filter(Boolean);
  if (ml.length === 0) return null;
  return Math.max(...ml);
}

function nameHasSize(name) {
  return /\b\d+(?:\.\d+)?\s*(ml|cl|l|oz|fl\.?\s*oz|each|ea)\b/i.test(name || '');
}

function sizesMatch(a, b) {
  if (a == null || b == null) return false;
  const tol = Math.max(5, 0.02 * Math.max(a, b)); // 2% or 5ml tolerance
  return Math.abs(a - b) <= tol;
}

async function lookupUpcItemDb(upc) {
  try {
    const r = await fetch('https://api.upcitemdb.com/prod/trial/lookup?upc=' + upc);
    if (!r.ok) return null;
    const d = await r.json();
    if (d.code !== 'OK' || !d.items || d.items.length === 0) return null;
    const p = d.items[0];
    return { title: p.title || '', brand: p.brand || '', size_text: p.size || '', source: 'upcitemdb' };
  } catch { return null; }
}

async function lookupOpenFoodFacts(upc) {
  try {
    const r = await fetch('https://world.openfoodfacts.org/api/v2/product/' + upc + '.json',
                         { headers: { 'User-Agent': 'CountingAppUPCResolver/0.1' } });
    if (!r.ok) return null;
    const d = await r.json();
    if (d.status !== 1 || !d.product) return null;
    const p = d.product;
    return {
      title: p.product_name || p.product_name_en || '',
      brand: p.brands || '',
      size_text: p.quantity || '',
      source: 'openfoodfacts',
    };
  } catch { return null; }
}

async function lookupUpc(upc) {
  // UPCitemDB usually has better retail/liquor coverage; OFF as fallback.
  let hit = await lookupUpcItemDb(upc);
  if (hit && (hit.title || hit.size_text)) return hit;
  hit = await lookupOpenFoodFacts(upc);
  if (hit && (hit.title || hit.size_text)) return hit;
  return null;
}

// ---- main -----------------------------------------------------------------

async function fetchAmbiguous() {
  // Pull from purchase_items via REST, then group client-side. Simpler than
  // crafting the SQL through the REST API.
  const all = [];
  for (let page = 0; page < 50; page++) {
    const from = page * 1000;
    const r = await fetch(`${SUPABASE_URL}/purchase_items?select=upc,master_item_id&upc=not.is.null&limit=1000&offset=${from}`, { headers: H });
    const rows = await r.json();
    if (!Array.isArray(rows) || rows.length === 0) break;
    all.push(...rows);
    if (rows.length < 1000) break;
  }

  // Pull all masters once for name/size lookups
  const masters = [];
  for (let page = 0; page < 50; page++) {
    const from = page * 1000;
    const r = await fetch(`${SUPABASE_URL}/master_items?select=id,name,base_size,base_unit&limit=1000&offset=${from}`, { headers: H });
    const rows = await r.json();
    if (!Array.isArray(rows) || rows.length === 0) break;
    masters.push(...rows);
    if (rows.length < 1000) break;
  }
  const masterById = new Map(masters.map(m => [m.id, m]));

  // Group by upc → distinct master_item_ids
  const groups = new Map();
  for (const r of all) {
    const upc = (r.upc || '').trim();
    if (!upc || !r.master_item_id) continue;
    if (!groups.has(upc)) groups.set(upc, new Set());
    groups.get(upc).add(r.master_item_id);
  }

  // Ambiguous = upc with > 1 distinct master_item_id
  const ambiguous = [];
  for (const [upc, ids] of groups) {
    if (ids.size < 2) continue;
    const candidates = [...ids].map(id => {
      const m = masterById.get(id);
      return m ? {
        id, name: m.name,
        base_size: m.base_size, base_unit: m.base_unit,
        size_ml: toMl(m.base_size, m.base_unit),
      } : null;
    }).filter(Boolean);
    if (candidates.length < 2) continue;
    ambiguous.push({ upc, upc_normalized: normalize(upc), candidates });
  }
  return ambiguous;
}

function escapeSqlString(s) {
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function emitSqlForResolved(item, target, method, lookup, apiSizeMl) {
  // Replace the existing master_item_upcs row's master_item_id with the
  // correct one. ON CONFLICT preserves uniqueness on upc_normalized.
  return [
    `-- ${item.upc}  →  ${target.name}  (method: ${method})`,
    `update public.master_item_upcs`,
    `   set master_item_id = '${target.id}',`,
    `       source = 'resolved_via_${method}',`,
    `       notes  = ${escapeSqlString(`Resolved by 0022 cleanup. API: ${lookup?.title || '-'}; API size: ${apiSizeMl ?? '-'}; target_master: ${target.name}`)}`,
    ` where upc_normalized = ${escapeSqlString(item.upc_normalized)};`,
    ``,
  ].join('\n');
}

function emitSqlForUnresolved(item, reason, lookup, apiSizeMl) {
  return [
    `-- ${item.upc}  →  REVIEW (reason: ${reason})`,
    `delete from public.master_item_upcs where upc_normalized = ${escapeSqlString(item.upc_normalized)};`,
    `insert into public.master_item_upcs_review`,
    `  (upc_raw, upc_normalized, candidate_masters, lookup_title, lookup_brand,`,
    `   lookup_size_text, lookup_size_ml, lookup_source, reason)`,
    `values (`,
    `  ${escapeSqlString(item.upc)},`,
    `  ${escapeSqlString(item.upc_normalized)},`,
    `  ${escapeSqlString(JSON.stringify(item.candidates))}::jsonb,`,
    `  ${lookup?.title ? escapeSqlString(lookup.title) : 'null'},`,
    `  ${lookup?.brand ? escapeSqlString(lookup.brand) : 'null'},`,
    `  ${lookup?.size_text ? escapeSqlString(lookup.size_text) : 'null'},`,
    `  ${apiSizeMl != null ? apiSizeMl : 'null'},`,
    `  ${lookup?.source ? escapeSqlString(lookup.source) : 'null'},`,
    `  ${escapeSqlString(reason)}`,
    `) on conflict (upc_normalized) do nothing;`,
    ``,
  ].join('\n');
}

async function main() {
  const ambiguous = await fetchAmbiguous();
  console.error(`Pulled ${ambiguous.length} ambiguous UPCs to process.`);

  const sqlLines = [
    `-- Generated by resolve_ambiguous_upcs.mjs on ${new Date().toISOString()}`,
    `-- Resolves the ambiguous UPC mappings created by migration 0020.`,
    ``,
    `begin;`,
    ``,
  ];

  const stats = { resolved_api: 0, resolved_heuristic: 0, unresolved: 0 };
  let i = 0;

  for (const item of ambiguous) {
    i++;
    process.stderr.write(`[${i}/${ambiguous.length}] ${item.upc}: `);

    const lookup = await lookupUpc(item.upc);
    const apiSizeMl = lookup ? parseSizeMl((lookup.title || '') + ' ' + (lookup.size_text || '')) : null;

    let target = null, method = null, reason = null;

    // Step 1: API size match
    if (apiSizeMl != null) {
      const matches = item.candidates.filter(c => sizesMatch(c.size_ml, apiSizeMl));
      if (matches.length === 1) {
        target = matches[0]; method = 'api_size_match';
      } else if (matches.length > 1) {
        reason = 'multiple_size_match';
      }
    }

    // Step 2: No-size-in-name heuristic (the "base SKU" pattern)
    if (!target && !reason) {
      const baseCandidates = item.candidates.filter(c => !nameHasSize(c.name) && c.size_ml != null);
      if (baseCandidates.length === 1) {
        target = baseCandidates[0]; method = 'no_size_in_name_heuristic';
      }
    }

    // Step 3: outcome
    if (target) {
      sqlLines.push(emitSqlForResolved(item, target, method, lookup, apiSizeMl));
      if (method === 'api_size_match') stats.resolved_api++;
      else stats.resolved_heuristic++;
      process.stderr.write(`✓ ${method} → ${target.name}\n`);
    } else {
      if (!reason) reason = lookup ? (apiSizeMl != null ? 'size_no_match' : 'no_size') : 'not_found';
      sqlLines.push(emitSqlForUnresolved(item, reason, lookup, apiSizeMl));
      stats.unresolved++;
      process.stderr.write(`✗ ${reason}\n`);
    }

    // Polite pacing to avoid rate limits — UPCitemDB free tier is ~100/day,
    // we'll likely exhaust it midway and fall through to OFF for the rest.
    await sleep(250);
  }

  sqlLines.push(`commit;`);
  sqlLines.push('');
  console.log(sqlLines.join('\n'));

  console.error('');
  console.error('=== Summary ===');
  console.error(`  Resolved via API size match:       ${stats.resolved_api}`);
  console.error(`  Resolved via no-size-name heuristic: ${stats.resolved_heuristic}`);
  console.error(`  Unresolved (logged to review):     ${stats.unresolved}`);
  console.error(`  Total processed:                   ${ambiguous.length}`);
}

main().catch(e => { console.error('FATAL:', e); process.exit(1); });
