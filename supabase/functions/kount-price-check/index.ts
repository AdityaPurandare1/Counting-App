// supabase/functions/kount-price-check/index.ts
//
// Edge Function: the weekly PRICE CHECK (migration 0176, Counting-Admin v1.23). For every item in the venue bibles
// (BOH and FOH OS&E: glassware, flatware, plateware, barware, smallwares ...) a Claude model on OpenRouter searches the
// web for the EXACT item (manufacturer + manufacturer item #, every spec the bible gives) and reports each seller's
// price; the verdict compares the cheapest exact offer per piece with what we paid (the order tracker). Sellers that
// list the item behind "request a quote" are kept as quote required. Pure logic: ./rules.ts.
//
// Calls:
//   {action:'weekly'}  pg_cron 'kount-price-check-weekly' (x-kount-cron): the items re-read from the bibles, a run
//                      started, every checkable item due (the ones we have bought first)
//   {action:'work'}    pg_cron 'kount-price-check-work' every 3 min while items are due (x-kount-cron): claims a few
//                      due items and checks them side by side, in the background; stops at the weekly budget
//   {action:'sync' | 'start' | 'check', item_id?}  a person (JWT; Order tracker or Order prices permission):
//                      re-read the bibles now / start a run now / check one item now and wait for it
//
// Deployed with --no-verify-jwt (config.toml): the cron calls carry the shared secret, a person's JWT is checked here.
// Secrets: OPENROUTER_API_KEY (already set for the AI router).

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';
import { bibleItems, overBudget, purchasesFor, readResearch, RESEARCH_SYSTEM, researchPrompt, verdict, type BibleRow, type PcItem, type PurchaseLine, type Research } from './rules.ts';

// 2026-11 key rotation (as kount-order-mail): the new API key maps, legacy env as the fallback
function newApiKey(mapEnv: string, names: string[], legacyEnv: string): string {
  try {
    const m = JSON.parse(Deno.env.get(mapEnv) ?? '{}') as Record<string, string>;
    for (const n of names) if (typeof m?.[n] === 'string' && m[n]) return m[n];
  } catch { /* fall through */ }
  return Deno.env.get(legacyEnv) ?? '';
}
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = newApiKey('SUPABASE_PUBLISHABLE_KEYS', ['default'], 'SUPABASE_ANON_KEY');
const SUPABASE_SERVICE_ROLE_KEY = newApiKey('SUPABASE_SECRET_KEYS', ['keva_secret_2026_11', 'default'], 'SUPABASE_SERVICE_ROLE_KEY');
const OPENROUTER_API_KEY = Deno.env.get('OPENROUTER_API_KEY') || '';
const OPENROUTER = 'https://openrouter.ai/api/v1';
const FEATURES = ['purchasing:order-tracker', 'purchasing:order-prices'];
const ALLOWED_ROLES = new Set(['admin', 'corporate']);

// one item's research may search and open pages for a while; the function is stopped after a few minutes
const RESEARCH_TIMEOUT_MS = 140_000;
const MAX_ATTEMPTS = 3;
const MAX_PER_TICK = 8;

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
const reject = (status: number, message: string) => json(status, { error: message });
const msg = (e: unknown) => (e instanceof Error ? e.message : typeof e === 'object' && e && 'message' in e ? String((e as { message: unknown }).message) : String(e));
const nowIso = () => new Date().toISOString();
function background(p: Promise<unknown>) {
  const guarded = p.catch(e => console.error('[kount-price-check] background failed:', msg(e)));
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(guarded);
}
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function personCaller(req: Request, sb: SupabaseClient): Promise<{ email: string } | Response> {
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!jwt) return reject(401, 'Missing Authorization header');
  const asCaller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { global: { headers: { Authorization: 'Bearer ' + jwt } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await asCaller.auth.getUser(jwt);
  if (error || !data?.user?.email) return reject(401, 'Not signed in');
  const email = data.user.email.toLowerCase();
  const { data: p, error: pErr } = await sb.from('app_users').select('role,is_active,features').eq('email', email).limit(1).maybeSingle();
  if (pErr) return reject(500, 'Failed to verify caller');
  const ok = !!p && p.is_active === true && (Array.isArray(p.features) ? FEATURES.some(f => (p.features as unknown[]).includes(f)) : ALLOWED_ROLES.has(String(p.role)));
  return ok ? { email } : reject(403, 'The price check needs the Order tracker or Order prices permission');
}

interface Settings { enabled: boolean; model: string; weekly_budget_usd: number; overpay_pct: number; per_tick: number }
async function settings(sb: SupabaseClient): Promise<Settings> {
  const { data, error } = await sb.from('kount_pc_settings').select('enabled, model, weekly_budget_usd, overpay_pct, per_tick').eq('id', 1).single();
  if (error) throw error;
  return { enabled: !!data.enabled, model: String(data.model || 'anthropic/claude-sonnet-5.5'), weekly_budget_usd: Number(data.weekly_budget_usd) || 0,
    overpay_pct: Number(data.overpay_pct) || 10, per_tick: Math.min(MAX_PER_TICK, Math.max(1, Number(data.per_tick) || 5)) };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reject(405, 'Method not allowed');
  const body = await req.json().catch(() => ({})) as { action?: string; item_id?: string };
  const action = String(body.action ?? '');
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  try {
    if (action === 'weekly' || action === 'work') {
      const { data: secret } = await sb.rpc('kount_ot_mail_cron_secret');
      if (!secret || !safeEqual(req.headers.get('x-kount-cron') || '', String(secret))) return reject(401, 'Not allowed');
      const st = await settings(sb);
      if (!st.enabled) return json(200, { skipped: 'the price check is switched off' });
      if (action === 'weekly') return json(200, await startRun(sb, 'weekly'));
      return json(202, await work(sb, st));
    }
    const caller = await personCaller(req, sb);
    if (caller instanceof Response) return caller;
    if (action === 'sync') return json(200, await syncItems(sb));
    if (action === 'start') {
      const st = await settings(sb);
      const r = await startRun(sb, `started by ${caller.email}`);
      if (st.enabled) background(work(sb, st));
      return json(200, { ...r, enabled: st.enabled });
    }
    if (action === 'check') {
      const id = String(body.item_id ?? '').trim();
      if (!id) return reject(400, 'item_id is required');
      const { data: item, error } = await sb.from('kount_pc_items').select('*').eq('id', id).maybeSingle();
      if (error) throw error;
      if (!item) return reject(404, 'No such item');
      const st = await settings(sb);
      const check = await checkItem(sb, item as PcItemRow, st, null, await loadPurchaseLines(sb));
      return json(200, { check });
    }
    return reject(400, 'Unknown action');
  } catch (e) {
    console.error('[kount-price-check]', action, msg(e));
    return reject(500, msg(e));
  }
});

// ── the items ────────────────────────────────────────────────────────────────

type PcItemRow = PcItem & { id: string; bought?: boolean; attempts?: number };

async function loadPurchaseLines(sb: SupabaseClient): Promise<PurchaseLine[]> {
  const out: PurchaseLine[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb.from('kount_ot_lines')
      .select('sku, description, unit_price, unit, qty, status, invoice_number, kount_ot_orders!inner(vendor_name, ordered_on, order_number, archived_at)')
      .gt('unit_price', 0).neq('status', 'CANCELLED').range(from, from + 999);
    if (error) throw error;
    type Ord = { vendor_name: string; ordered_on: string | null; order_number: string | null };
    for (const l of (data ?? []) as unknown as Array<Record<string, unknown> & { kount_ot_orders: Ord | Ord[] }>) {
      const o = Array.isArray(l.kount_ot_orders) ? l.kount_ot_orders[0] : l.kount_ot_orders;
      if (!o) continue;
      out.push({ sku: (l.sku as string) ?? null, description: String(l.description ?? ''), unit_price: Number(l.unit_price), unit: (l.unit as string) ?? null,
        qty: l.qty == null ? null : Number(l.qty), status: String(l.status), invoice_number: (l.invoice_number as string) ?? null,
        vendor: o.vendor_name, ordered_on: o.ordered_on, order_number: o.order_number });
    }
    if ((data ?? []).length < 1000) break;
  }
  return out;
}

/** The items re-read from the current bibles: new ones added, changed ones updated, ones no bible lists any more
 *  switched off (their history stays). `bought` = we have a purchase price for it (checked first). */
async function syncItems(sb: SupabaseClient): Promise<{ items: number; checkable: number; bought: number; retired: number }> {
  const { data: bibles, error } = await sb.from('kount_ot_bibles').select('id, venue_id, title, text_index').eq('is_current', true);
  if (error) throw error;
  const items = bibleItems((bibles ?? []) as BibleRow[]);
  const lines = await loadPurchaseLines(sb);
  const at = nowIso();
  const rows = items.map(i => ({ ...i, bought: purchasesFor(i, lines).length > 0, active: true, updated_at: at }));
  for (let k = 0; k < rows.length; k += 200) {
    const { error: e } = await sb.from('kount_pc_items').upsert(rows.slice(k, k + 200), { onConflict: 'item_key' });
    if (e) throw e;
  }
  const keep = new Set(items.map(i => i.item_key));
  const { data: all, error: aErr } = await sb.from('kount_pc_items').select('id, item_key').eq('active', true);
  if (aErr) throw aErr;
  const gone = (all ?? []).filter(r => !keep.has(r.item_key)).map(r => r.id);
  for (let k = 0; k < gone.length; k += 200) {
    const { error: e } = await sb.from('kount_pc_items').update({ active: false, due_at: null, claimed_at: null, updated_at: at }).in('id', gone.slice(k, k + 200));
    if (e) throw e;
  }
  return { items: items.length, checkable: items.filter(i => i.checkable).length, bought: rows.filter(r => r.bought).length, retired: gone.length };
}

/** A run: the bibles re-read, every checkable item due. One run at a time - an unfinished one is closed first. */
async function startRun(sb: SupabaseClient, trigger: string) {
  const sync = await syncItems(sb);
  const st = await settings(sb);
  await sb.from('kount_pc_runs').update({ finished_at: nowIso(), stopped: 'replaced by a new run' }).is('finished_at', null);
  const { data: run, error } = await sb.from('kount_pc_runs').insert({ trigger, items_total: sync.checkable, budget_usd: st.weekly_budget_usd, model: st.model }).select('id').single();
  if (error) throw error;
  const { error: dErr } = await sb.from('kount_pc_items').update({ due_at: nowIso(), claimed_at: null, attempts: 0 }).eq('active', true).eq('checkable', true);
  if (dErr) throw dErr;
  return { run_id: run.id, ...sync };
}

/** One tick: a few due items claimed and checked side by side, in the background. Stops the run at its budget;
 *  closes it when nothing is left. */
async function work(sb: SupabaseClient, st: Settings) {
  const { data: run } = await sb.from('kount_pc_runs').select('id, cost_usd, budget_usd').is('finished_at', null).order('started_at', { ascending: false }).limit(1).maybeSingle();
  if (!run) return { skipped: 'no run in progress' };
  if (overBudget(Number(run.cost_usd), Number(run.budget_usd))) {
    await sb.from('kount_pc_runs').update({ finished_at: nowIso(), stopped: `the weekly budget ($${Number(run.budget_usd).toFixed(0)}) was reached` }).eq('id', run.id);
    await sb.from('kount_pc_items').update({ due_at: null, claimed_at: null }).not('due_at', 'is', null);
    return { stopped: 'budget' };
  }
  const { data: claimed, error } = await sb.rpc('kount_pc_claim', { p_n: st.per_tick });
  if (error) throw error;
  const items = (claimed ?? []) as PcItemRow[];
  if (!items.length) {
    const { count } = await sb.from('kount_pc_items').select('id', { count: 'exact', head: true }).not('due_at', 'is', null);
    if (!count) await sb.from('kount_pc_runs').update({ finished_at: nowIso() }).eq('id', run.id).is('finished_at', null);
    return { claimed: 0, left: count ?? 0 };
  }
  const lines = await loadPurchaseLines(sb);
  background(Promise.all(items.map(i => checkItem(sb, i, st, run.id, lines).catch(e => console.error('[kount-price-check] item', i.item_key, msg(e))))));
  return { claimed: items.length };
}

// ── one item ─────────────────────────────────────────────────────────────────

interface ResearchCall { text: string; cost: number; searches: number; model: string; error: string | null }

/** The research: the model with OpenRouter's web search and web fetch (server tools, Responses API). The search
 *  engine is the model's own (native) for Claude. */
async function research(model: string, prompt: string): Promise<ResearchCall> {
  if (!OPENROUTER_API_KEY) return { text: '', cost: 0, searches: 0, model, error: 'OPENROUTER_API_KEY is not set' };
  const headers = { 'Content-Type': 'application/json', Authorization: 'Bearer ' + OPENROUTER_API_KEY, 'HTTP-Referer': 'https://adityapurandare1.github.io/Counting-Admin/', 'X-Title': 'kOunt price check' };
  const res = await fetch(`${OPENROUTER}/responses`, {
    method: 'POST', headers, signal: AbortSignal.timeout(RESEARCH_TIMEOUT_MS),
    body: JSON.stringify({
      model,
      input: [{ type: 'message', role: 'system', content: RESEARCH_SYSTEM }, { type: 'message', role: 'user', content: prompt }],
      tools: [{ type: 'openrouter:web_search', parameters: { engine: 'auto', max_uses: 5 } }, { type: 'openrouter:web_fetch' }],
      max_tool_calls: 10,
      max_output_tokens: 6000,
      provider: { data_collection: 'deny' },
    }),
  });
  const raw = await res.text();
  let data: Record<string, unknown> = {};
  try { data = JSON.parse(raw); } catch { /* below */ }
  if (!res.ok) return { text: '', cost: 0, searches: 0, model, error: `OpenRouter ${res.status}: ${raw.slice(0, 300)}` };
  const texts: string[] = [];
  for (const o of (data.output as Array<Record<string, unknown>> | undefined) ?? []) {
    if (o.type !== 'message') continue;
    for (const c of (o.content as Array<Record<string, unknown>> | undefined) ?? []) if (c.type === 'output_text' && typeof c.text === 'string') texts.push(c.text);
  }
  if (!texts.length && typeof data.output_text === 'string') texts.push(data.output_text);
  const usage = (data.usage ?? {}) as Record<string, unknown>;
  const tools = (usage.server_tool_use_details ?? usage.server_tool_use ?? {}) as Record<string, unknown>;
  return { text: texts.join('\n'), cost: Number(usage.cost) || 0, searches: Number(tools.web_search_requests) || 0, model: String(data.model || model),
    error: texts.length ? null : 'the model gave no answer' };
}

/** The research written up as notes but not as the JSON asked for: one more call, no tools, to put it in that form. */
async function structure(model: string, prompt: string, notes: string): Promise<{ research: Research | null; cost: number }> {
  const res = await fetch(`${OPENROUTER}/chat/completions`, {
    method: 'POST', signal: AbortSignal.timeout(60_000),
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + OPENROUTER_API_KEY, 'X-Title': 'kOunt price check' },
    body: JSON.stringify({ model, max_tokens: 4000, provider: { data_collection: 'deny' }, usage: { include: true },
      messages: [{ role: 'user', content: `${prompt}\n\nYOUR RESEARCH NOTES (use only what they show; do not search again):\n${notes.slice(0, 30000)}` }] }),
  });
  if (!res.ok) return { research: null, cost: 0 };
  const data = await res.json().catch(() => ({})) as { choices?: Array<{ message?: { content?: string } }>; usage?: { cost?: number } };
  return { research: readResearch(String(data.choices?.[0]?.message?.content ?? '')), cost: Number(data.usage?.cost) || 0 };
}

/** One item checked: its research, the verdict, a kount_pc_checks row, the item's latest status. A failure is
 *  retried by a later tick (MAX_ATTEMPTS), then kept as an error. Returns the check row. */
async function checkItem(sb: SupabaseClient, item: PcItemRow, st: Settings, runId: string | null, lines: PurchaseLine[]) {
  const purchases = purchasesFor(item, lines);
  const prompt = researchPrompt(item, purchases);
  let r: ResearchCall;
  try { r = await research(st.model, prompt); }
  catch (e) { r = { text: '', cost: 0, searches: 0, model: st.model, error: msg(e) }; }
  let res = r.error ? null : readResearch(r.text);
  let cost = r.cost;
  if (!res && r.text) { const s = await structure(st.model, prompt, r.text).catch(() => ({ research: null, cost: 0 })); res = s.research; cost += s.cost; }
  const attempts = (item.attempts ?? 0) + 1;
  const failed = !res;
  if (failed && runId && attempts < MAX_ATTEMPTS) {
    // tried again by a later tick (the claim is released)
    await sb.from('kount_pc_items').update({ claimed_at: null, attempts }).eq('id', item.id);
    if (runId) await sb.rpc('kount_pc_run_add', { p_run: runId, p_cost: cost, p_done: 0 });
    return null;
  }
  const v = verdict(item, res, purchases, st.overpay_pct);
  const row = {
    item_id: item.id, run_id: runId, status: v.status, our_unit_price: v.our_unit_price, purchases,
    best_unit_price: v.best?.unit_price ?? null, best_vendor: v.best?.seller ?? null, best_url: v.best?.url ?? null, savings_pct: v.savings_pct,
    offers: res?.exact_offers ?? [], quote_vendors: res?.quote_required ?? [], rejected: res?.rejected ?? [],
    notes: [res?.our_unit_note ? `Our price: ${res.our_unit_note}` : '', res?.notes ?? ''].filter(Boolean).join(' | ').slice(0, 2000) || null,
    model: r.model, cost_usd: Math.round(cost * 10000) / 10000, searches: r.searches,
    error: failed ? (r.error ?? 'the answer could not be read') : null, raw_text: r.text.slice(0, 20000) || null,
  };
  const { data: check, error } = await sb.from('kount_pc_checks').insert(row).select('*').single();
  if (error) throw error;
  await sb.from('kount_pc_items').update({ last_check_id: check.id, last_status: v.status, last_checked_at: check.checked_at, due_at: null, claimed_at: null, attempts })
    .eq('id', item.id);
  if (runId) await sb.rpc('kount_pc_run_add', { p_run: runId, p_cost: cost, p_done: 1 });
  return check;
}
