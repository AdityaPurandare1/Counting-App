/* In-memory Supabase mock with a PostgREST-ish query engine and the specific
   schema constraints that make this a real regression net:
     - kount_entries.item_id        FK → purchase_items(id)   (the outage bug)
     - kount_entries.master_item_id FK → master_items(id)
     - kount_entries unique merge index (audit, zone, coalesce(item_id,name), is_recount)
     - master_items INSERT          RLS → corporate app_users only
   Playwright route handlers call handle() directly (same Node process), so all
   browser contexts share one DB instance → consistent state across personas. */

const { seed } = require('./fixtures');

function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
    const r = (Math.random() * 16) | 0; const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function err(status, code, message) {
  return { status, body: { code: code, message: message, details: null, hint: null } };
}

// ---- query-string parsing -------------------------------------------------
function parseQuery(qs) {
  const out = { filters: [], select: '*', order: null, limit: null, offset: 0 };
  (qs || '').split('&').filter(Boolean).forEach(function (pair) {
    const eq = pair.indexOf('=');
    const key = decodeURIComponent(pair.slice(0, eq));
    const raw = pair.slice(eq + 1);
    const val = decodeURIComponent(raw);
    if (key === 'select') out.select = val;
    else if (key === 'order') out.order = val;
    else if (key === 'limit') out.limit = parseInt(val, 10);
    else if (key === 'offset') out.offset = parseInt(val, 10) || 0;
    else out.filters.push({ col: key, op: val });
  });
  return out;
}

function coerce(v) {
  if (v === 'true') return true;
  if (v === 'false') return false;
  return v;
}

function ilikeToRegex(pat) {
  let p = pat;
  if (p.length >= 2 && p[0] === '"' && p[p.length - 1] === '"') p = p.slice(1, -1);
  p = p.replace(/\\"/g, '"');
  const re = p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*').replace(/_/g, '.');
  return new RegExp('^' + re + '$', 'i');
}

function matchFilter(row, f) {
  const op = f.op;
  const cell = row[f.col];
  if (op === 'is.null') return cell === null || cell === undefined;
  if (op === 'not.is.null') return cell !== null && cell !== undefined;
  if (op.startsWith('eq.')) return String(cell) === String(coerce(op.slice(3))) || cell === coerce(op.slice(3));
  if (op.startsWith('neq.')) return String(cell) !== String(coerce(op.slice(4)));
  if (op.startsWith('gte.')) return cell != null && cell >= op.slice(4);
  if (op.startsWith('lte.')) return cell != null && cell <= op.slice(4);
  if (op.startsWith('ilike.')) return cell != null && ilikeToRegex(op.slice(6)).test(String(cell));
  if (op.startsWith('like.')) return cell != null && ilikeToRegex(op.slice(5)).test(String(cell));
  if (op.startsWith('cs.')) {
    // PostgREST array "contains": col=cs.{a,b} → column (an array) must
    // contain EVERY listed value. Used by the v1.62 AVT report selection
    // (kount_avt_reports.venue_ids is text[]).
    let list = op.slice(3);
    if (list.startsWith('{') && list.endsWith('}')) list = list.slice(1, -1);
    const wanted = list.split(',').map(function (s) {
      s = s.trim(); if (s[0] === '"' && s[s.length - 1] === '"') s = s.slice(1, -1).replace(/\\"/g, '"'); return s;
    }).filter(Boolean);
    if (!Array.isArray(cell)) return false;
    return wanted.every(function (w) { return cell.some(function (c) { return String(c) === w; }); });
  }
  if (op.startsWith('in.')) {
    let list = op.slice(3);
    if (list.startsWith('(') && list.endsWith(')')) list = list.slice(1, -1);
    const items = list.split(',').map(function (s) {
      s = s.trim(); if (s[0] === '"' && s[s.length - 1] === '"') s = s.slice(1, -1).replace(/\\"/g, '"'); return s;
    });
    return items.some(function (it) { return String(cell) === it; });
  }
  return true; // unknown operator → don't exclude
}

/* Resolves a PostgREST embed-join filter (e.g. master_items.is_active=eq.true)
   the way an !inner embed does on the server: the parent row is kept only if
   its joined-table row passes the filter. We map embed-table → {fk on the
   parent, pk on the embedded table} so the carried-items query (D-H1) and any
   future embed filter exclude rows whose parent points at a non-matching
   (e.g. archived) row. Unknown embeds fall through to "keep" so unrelated
   tests aren't affected. */
const EMBED_JOINS = {
  // kount_carried_items.master_item_id → master_items.id
  master_items: { fk: 'master_item_id', pk: 'id' },
};

function applyEmbedFilters(tables, rows, filters) {
  const embedFilters = filters.filter(function (f) { return f.col.indexOf('.') !== -1; });
  if (embedFilters.length === 0) return rows;
  return rows.filter(function (r) {
    return embedFilters.every(function (f) {
      const dot = f.col.indexOf('.');
      const embed = f.col.slice(0, dot);
      const col = f.col.slice(dot + 1);
      const join = EMBED_JOINS[embed];
      if (!join) return true; // unknown embed → don't exclude
      const fkVal = r[join.fk];
      const ref = (tables[embed] || []).find(function (x) { return x[join.pk] === fkVal; });
      if (!ref) return false; // !inner: no joined row → drop the parent
      return matchFilter(ref, { col: col, op: f.op });
    });
  });
}

function applyQuery(rows, q, tables) {
  const topFilters = q.filters.filter(function (f) { return f.col.indexOf('.') === -1; });
  let out = rows.filter(function (r) { return topFilters.every(function (f) { return matchFilter(r, f); }); });
  if (tables) out = applyEmbedFilters(tables, out, q.filters);
  if (q.order) {
    // PostgREST multi-column order: "col1.asc,col2.desc". The v1.62 AVT
    // report selection orders by source.asc,uploaded_at.desc — a single-
    // column parse would silently mis-sort it.
    const keys = q.order.split(',').map(function (part) {
      const bits = part.split('.');
      return { col: bits[0], desc: bits.indexOf('desc') !== -1 };
    });
    out = out.slice().sort(function (a, b) {
      for (const k of keys) {
        const av = a[k.col], bv = b[k.col];
        if (av === bv) continue;
        // Postgres defaults: ASC → NULLS LAST, DESC → NULLS FIRST.
        if (av == null) return k.desc ? -1 : 1;
        if (bv == null) return k.desc ? 1 : -1;
        return (av > bv ? 1 : -1) * (k.desc ? -1 : 1);
      }
      return 0;
    });
  }
  if (q.offset) out = out.slice(q.offset);
  if (q.limit != null) out = out.slice(0, q.limit);
  return out;
}

// ---- the mock -------------------------------------------------------------
class MockDB {
  constructor() { this.reset(); }
  reset() { this.t = seed(); }

  emailFromAuth(headers) {
    const auth = (headers['authorization'] || headers['Authorization'] || '');
    const m = /Bearer\s+mocktok\.(.+)$/.exec(auth);
    return m ? decodeURIComponent(m[1]) : null; // null = anon (anon key Bearer)
  }
  isCorporate(email) {
    if (!email) return false;
    const u = this.t.app_users.find(function (r) { return r.email.toLowerCase() === String(email).toLowerCase(); });
    return !!(u && u.role === 'corporate' && u.is_active);
  }

  mergeKey(row) {
    const idPart = (row.item_id != null) ? String(row.item_id) : String(row.item_name || '').toLowerCase();
    return [row.audit_id, row.zone, idPart, !!row.is_recount].join('|');
  }

  insert(table, headers, body) {
    const rows = Array.isArray(body) ? body : [body];
    const inserted = [];
    for (const raw of rows) {
      const row = Object.assign({}, raw);

      if (table === 'master_items') {
        if (!this.isCorporate(this.emailFromAuth(headers)))
          return err(403, '42501', 'new row violates row-level security policy for table "master_items"');
        if (!row.id) row.id = uuid();
        if (row.is_active === undefined) row.is_active = true;
      }

      if (table === 'kount_entries') {
        // NOT NULL
        for (const c of ['audit_id', 'item_name', 'zone', 'counted_by_email']) {
          if (row[c] == null || row[c] === '') return err(400, '23502', 'null value in column "' + c + '" violates not-null constraint');
        }
        // FK item_id → purchase_items  (THE outage bug: a master id here fails)
        if (row.item_id != null && !this.t.purchase_items.some(function (p) { return p.id === row.item_id; }))
          return err(409, '23503', 'insert or update on table "kount_entries" violates foreign key constraint "kount_entries_item_id_fkey"');
        // FK master_item_id → master_items
        if (row.master_item_id != null && !this.t.master_items.some(function (m) { return m.id === row.master_item_id; }))
          return err(409, '23503', 'violates foreign key constraint "kount_entries_master_item_id_fkey"');
        // FK audit_id → kount_audits
        if (!this.t.kount_audits.some(function (a) { return a.id === row.audit_id; }))
          return err(409, '23503', 'violates foreign key constraint "kount_entries_audit_id_fkey"');
        // unique merge index
        const key = this.mergeKey(row);
        const self = this;
        if (this.t.kount_entries.some(function (e) { return self.mergeKey(e) === key; }))
          return err(409, '23505', 'duplicate key value violates unique constraint "kount_entries_merge_key"');
        // migration 0036: partial unique on (audit_id, client_entry_id)
        // WHERE client_entry_id IS NOT NULL — replayed inserts collide with
        // the committed row instead of double-merging qty.
        if (row.client_entry_id != null &&
            this.t.kount_entries.some(function (e) {
              return e.audit_id === row.audit_id && e.client_entry_id != null &&
                     String(e.client_entry_id) === String(row.client_entry_id);
            }))
          return err(409, '23505', 'duplicate key value violates unique constraint "kount_entries_client_key"');
        if (!row.id) row.id = uuid();
      }

      if (table === 'kount_pending_items') {
        const nm = String(row.name || '').toLowerCase();
        if (row.status === 'pending' && this.t.kount_pending_items.some(function (p) { return p.status === 'pending' && String(p.name || '').toLowerCase() === nm; }))
          return err(409, '23505', 'duplicate key value violates unique constraint "kount_pending_items_pending_name_uniq"');
        if (!row.id) row.id = uuid();
      }

      if (!row.id && this.t[table]) row.id = uuid();
      if (!this.t[table]) this.t[table] = [];
      this.t[table].push(row);
      inserted.push(row);
    }
    return { status: 201, body: inserted };
  }

  select(table, headers, qs) {
    const rows = this.t[table] || [];
    return { status: 200, body: applyQuery(rows, parseQuery(qs), this.t) };
  }

  update(table, headers, qs, body) {
    const q = parseQuery(qs);
    const rows = this.t[table] || [];
    const hit = rows.filter(function (r) { return q.filters.every(function (f) { return matchFilter(r, f); }); });
    hit.forEach(function (r) { Object.assign(r, body); });
    return { status: 200, body: hit };
  }

  del(table, headers, qs) {
    const q = parseQuery(qs);
    const before = this.t[table] || [];
    const keep = []; const removed = [];
    before.forEach(function (r) { (q.filters.every(function (f) { return matchFilter(r, f); }) ? removed : keep).push(r); });
    this.t[table] = keep;
    return { status: 200, body: removed };
  }

  rpc(fn, headers, args) {
    if (fn === 'generate_kount_join_code') {
      return { status: 200, body: 'TST-' + Math.floor(1000 + Math.random() * 9000) };
    }
    if (fn === 'approve_upc_mapping' || fn === 'reject_upc_mapping') {
      return { status: 200, body: { ok: true } };
    }
    if (fn === 'find_auth_user_by_email') return { status: 200, body: null };
    if (fn === 'list_auth_user_emails') return { status: 200, body: [] };
    if (fn === 'compute_avt_for_audit') return this.computeAvtForAudit(args || {});
    return { status: 200, body: { ok: true } };
  }

  /* Faithful stub for the compute_avt_for_audit RPC (migration 0038). The
     real function computes theoretical-vs-actual variance from POS + recipes +
     purchases + starts and inserts a source='computed' kount_avt_reports row
     (+ its kount_avt_rows) for the audit's venue. It's now called at COUNT 1
     CLOSE (not just count 2), so the count-1 compute → loadAvtForAudit →
     generateRecountFromAvt path must be exercised end to end.

     We can't reproduce the real arithmetic in the mock, so we synthesize a
     deterministic report: one HIGH-variance row whose item_name matches what
     the lifecycle test counts (Belvedere 1L) so a recount IS generated, plus
     a zero-variance row so the "nothing flagged" branch has data to ignore.
     Returns the new report id (the RPC returns the report uuid). */
  computeAvtForAudit(args) {
    const auditId = args.p_audit_id;
    const audit = this.t.kount_audits.find(function (a) { return a.id === auditId; });
    if (!audit) return err(400, '22P02', 'audit not found: ' + auditId);
    const venueId = audit.venue_id;
    const venue = this.t.kount_venues.find(function (v) { return v.id === venueId; });
    const venueName = venue ? venue.name : '';

    const reportId = uuid();
    const now = new Date().toISOString();
    if (!this.t.kount_avt_reports) this.t.kount_avt_reports = [];
    if (!this.t.kount_avt_rows) this.t.kount_avt_rows = [];

    // Idempotent-ish: drop any prior computed report for this audit so a
    // re-run (count 1 then count 2) leaves a single current report, like the
    // real RPC's upsert-on-audit behavior.
    const self = this;
    this.t.kount_avt_reports = this.t.kount_avt_reports.filter(function (r) {
      if (r.audit_id === auditId && r.source === 'computed') {
        self.t.kount_avt_rows = self.t.kount_avt_rows.filter(function (row) { return row.report_id !== r.id; });
        return false;
      }
      return true;
    });

    this.t.kount_avt_reports.push({
      id: reportId,
      audit_id: auditId,
      venue_ids: [venueId],          // text[]: the v1.62 venue-scoped selection
      source: 'computed',
      uploaded_at: now,
      computed_at: now,
    });

    const mkRow = function (name, category, actual, theo, cuPrice) {
      const variance = actual - theo;                 // qty variance
      const varianceValue = variance * cuPrice;        // $ variance
      const variancePct = theo ? (variance / theo) * 100 : 0;
      return {
        id: uuid(), report_id: reportId, venue_id: venueId, venue_name: venueName,
        store: venueName, item_name: name, category: category,
        actual: actual, theo: theo, variance: variance,
        variance_value: varianceValue, variance_pct: variancePct,
        cu_price: cuPrice, start_qty: 0, purchases: 0, depletions: 0,
      };
    };

    // HIGH-variance liquor row: $150 over the $50 liquor threshold → MEDIUM+
    // → needsRecount() true → a recount row is generated for Belvedere 1L.
    this.t.kount_avt_rows.push(mkRow('Belvedere 1L', 'Liquor Cost', 1, 6, 30));
    // Zero-variance row that must NOT be flagged.
    this.t.kount_avt_rows.push(mkRow("Tito's Handmade Vodka 750ml", 'Liquor Cost', 4, 4, 20));

    return { status: 200, body: reportId };
  }

  edge(fn, headers, body) {
    if (fn === 'parse-bottle-label') {
      // Canned label read: an item NOT in the catalog, to drive the
      // "no match → create/suggest" path deterministically.
      return { status: 200, body: { name: 'Clase Azul Reposado', brand: 'Clase Azul', category: 'spirits', size: '750ml', vintage: '', details: '', confidence: 0.9 } };
    }
    return { status: 200, body: {} };
  }

  // Entry point used by the Playwright route handler.
  handle(method, table, qs, headers, body, kind, fn) {
    if (kind === 'rpc') return this.rpc(fn, headers, body || {});
    if (kind === 'edge') return this.edge(fn, headers, body || {});
    if (method === 'GET') return this.select(table, headers, qs);
    if (method === 'POST') return this.insert(table, headers, body);
    if (method === 'PATCH') return this.update(table, headers, qs, body);
    if (method === 'DELETE') return this.del(table, headers, qs);
    return err(405, 'METHOD', 'method not allowed');
  }
}

module.exports = { MockDB, uuid };
