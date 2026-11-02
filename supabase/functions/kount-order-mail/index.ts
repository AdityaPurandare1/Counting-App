// supabase/functions/kount-order-mail/index.ts
//
// Edge Function: the Order tracker's MORNING MAIL PULL (migration 0135,
// Counting-Admin v0.80). Reads the connected Outlook mailbox, takes the PDF
// attachments from the listed vendor domains, reads each one (the same reader
// as a manual upload) and either applies it to the order it clearly belongs to
// or leaves it in the Inbox for a person -- the rule is decideMailDocument in
// ../_shared/orderTracker.ts (a copy of Counting-Admin src/lib/orderTracker.ts).
//
// Calls:
//   {action:'cron'}      pg_cron 'kount-order-mail-morning' (x-kount-cron secret); works only
//                        in the 9 o'clock hour in Los Angeles
//   {action:'continue'}  the pull itself, when PDFs are left to read (same secret)
//   {action:'connect_start' | 'connect_poll' | 'pull'}  a person: JWT of an ACTIVE admin /
//                        corporate app_users row (deployed with --no-verify-jwt for the cron
//                        call; every person call is checked here instead)
//
// A pull answers at once and runs in the background (EdgeRuntime.waitUntil); one at a time
// (kount_ot_mail_begin_run). The admin watches kount_ot_mail_status().

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';
import { readPurchasePdf } from '../_shared/purchase-doc.ts';
import { decideMailDocument, type OtDocument, type OtItem, type OtLine, type OtOrder, type ReadDoc } from '../_shared/orderTracker.ts';
import { deviceCodePoll, deviceCodeStart, GraphError, graphGet, refreshAccess } from './graph.ts';
import { domainOf, fromBase64, isPdfAttachment, laParts, looksLikePurchaseDoc, onList, OWN_DOMAINS, safeEqual, sha256Hex, toBase64, type GraphAttachment } from './rules.ts';

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') || '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
const SELF_URL = `${SUPABASE_URL}/functions/v1/kount-order-mail`;

const BUCKET = 'kount-order-docs';
const ALLOWED_ROLES = new Set(['admin', 'corporate']);
const FIRST_LOOKBACK_DAYS = 30;
const OVERLAP_MS = 2 * 3600_000;       // re-look 2 h back: Outlook indexes late; duplicates are skipped
const READ_BUDGET_MS = 100_000;        // stop STARTING reads after this; the rest go on in a chained call
const READ_CONCURRENCY = 3;
const MAX_ATTEMPTS = 3;
const MAX_MESSAGES = 1000;
const MAX_CHAIN = 15;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
const reject = (status: number, message: string) => json(status, { error: message });
const msg = (e: unknown) => (e instanceof Error ? e.message : typeof e === 'object' && e && 'message' in e ? String((e as { message: unknown }).message) : String(e));
const fmtMoney = (x: number) => '$' + (Number(x) || 0).toFixed(2);
const nowIso = () => new Date().toISOString();

function background(p: Promise<unknown>) {
  const guarded = p.catch(e => console.error('[kount-order-mail] background run failed:', msg(e)));
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(guarded);
}

async function corporateCaller(req: Request, sb: SupabaseClient): Promise<{ email: string } | Response> {
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!jwt) return reject(401, 'Missing Authorization header');
  const asCaller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: 'Bearer ' + jwt } }, auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await asCaller.auth.getUser();
  if (error || !data.user?.email) return reject(401, 'Invalid or expired JWT');
  const email = data.user.email.toLowerCase();
  const { data: profile, error: pErr } = await sb.from('app_users').select('role,is_active').eq('email', email).limit(1).maybeSingle();
  if (pErr) return reject(500, 'Failed to verify caller');
  if (!profile || profile.is_active !== true || !ALLOWED_ROLES.has(String(profile.role))) {
    return reject(403, 'The order mail pull is limited to admin and corporate users');
  }
  return { email };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reject(405, 'Method not allowed');
  const body = await req.json().catch(() => ({})) as { action?: string; depth?: number };
  const action = String(body.action ?? '');
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    // ── the scheduled job (and its own continuation) ──
    if (action === 'cron' || action === 'continue') {
      const { data: secret } = await sb.rpc('kount_ot_mail_cron_secret');
      if (!secret || !safeEqual(req.headers.get('x-kount-cron') || '', String(secret))) return reject(401, 'Not allowed');
      if (action === 'cron' && laParts().hour !== 9) return json(200, { skipped: "not the 9 o'clock hour in Los Angeles" });
      const { data: locked } = await sb.rpc('kount_ot_mail_begin_run');
      if (locked !== true) return json(200, { skipped: 'a pull is already running' });
      background(runPull(sb, action === 'cron' ? 'morning' : 'continued', action === 'continue' ? Math.min(Number(body.depth) || 1, MAX_CHAIN) : 0));
      return json(202, { started: true });
    }

    // ── a person ──
    const caller = await corporateCaller(req, sb);
    if (caller instanceof Response) return caller;

    if (action === 'connect_start') {
      const dc = await deviceCodeStart();
      const { error } = await sb.from('kount_ot_mail_account').update({
        device_code: dc.device_code, device_code_expires_at: new Date(Date.now() + (dc.expires_in || 900) * 1000).toISOString(), updated_at: nowIso(),
      }).eq('id', 1);
      if (error) throw error;
      return json(200, { user_code: dc.user_code, verification_uri: dc.verification_uri, expires_in: dc.expires_in, interval: dc.interval || 5 });
    }

    if (action === 'connect_poll') {
      const { data: acct, error } = await sb.from('kount_ot_mail_account').select('device_code, device_code_expires_at').eq('id', 1).single();
      if (error) throw error;
      if (!acct.device_code || Date.parse(acct.device_code_expires_at) < Date.now()) return json(200, { state: 'expired', reason: 'The sign-in code expired — start again.' });
      const r = await deviceCodePoll(acct.device_code);
      if (!r.ok) {
        const code = String(r.json.error ?? '');
        if (code === 'authorization_pending' || code === 'slow_down') return json(200, { state: 'waiting' });
        await sb.from('kount_ot_mail_account').update({ device_code: null, device_code_expires_at: null, updated_at: nowIso() }).eq('id', 1);
        const reason = code === 'access_denied' ? 'The sign-in was declined.' : code === 'expired_token' ? 'The sign-in code expired — start again.'
          : String(r.json.error_description ?? code ?? 'Microsoft refused the sign-in').slice(0, 300);
        return json(200, { state: 'failed', reason });
      }
      const refresh = String(r.json.refresh_token ?? '');
      if (!refresh) return json(200, { state: 'failed', reason: 'Microsoft did not allow staying signed in (no refresh token).' });
      const me = await graphGet<{ mail?: string; userPrincipalName?: string }>(String(r.json.access_token), '/me?$select=mail,userPrincipalName');
      const mailbox = String(me.mail || me.userPrincipalName || '').toLowerCase();
      const { error: setErr } = await sb.rpc('kount_ot_mail_token_set', { p_token: refresh, p_mailbox: mailbox, p_by: caller.email });
      if (setErr) throw setErr;
      // the first pull starts right away (the last 30 days)
      const { data: locked } = await sb.rpc('kount_ot_mail_begin_run');
      if (locked === true) background(runPull(sb, 'first', 0));
      return json(200, { state: 'connected', mailbox });
    }

    if (action === 'pull') {
      const { data: locked } = await sb.rpc('kount_ot_mail_begin_run');
      if (locked !== true) return json(200, { started: false, reason: 'A pull is already running.' });
      background(runPull(sb, `by ${caller.email}`, 0));
      return json(202, { started: true });
    }

    return reject(400, 'Unknown action');
  } catch (e) {
    console.error('[kount-order-mail]', action, msg(e));
    return reject(e instanceof GraphError ? 502 : 500, msg(e));
  }
});

// ── one pull: fetch new PDFs, read them, decide ─────────────────────────────

interface Stats {
  trigger: string; started_at: string; messages: number; new_pdfs: number; read: number;
  applied: number; pending: number; ignored: number; failed: number; remaining?: number; error: string | null; reconnect: boolean;
}

/** Runs with the lock held (kount_ot_mail_begin_run returned true) and always releases it. */
async function runPull(sb: SupabaseClient, trigger: string, depth: number) {
  const startedMs = Date.now();
  const stats: Stats = { trigger, started_at: nowIso(), messages: 0, new_pdfs: 0, read: 0, applied: 0, pending: 0, ignored: 0, failed: 0, error: null, reconnect: false };
  let chain = false;
  try {
    const { data: acct, error } = await sb.from('kount_ot_mail_account')
      .select('token_secret_id, vendor_domains, suggested_domains, fetched_through, last_run').eq('id', 1).single();
    if (error) throw error;
    // a continuation adds to the run it continues, so the admin sees one morning's totals
    if (trigger === 'continued' && acct.last_run) {
      const prev = acct.last_run as Partial<Stats>;
      for (const k of ['messages', 'new_pdfs', 'read', 'applied', 'pending', 'ignored', 'failed'] as const) stats[k] = Number(prev[k]) || 0;
      stats.trigger = String(prev.trigger ?? trigger);
      stats.started_at = String(prev.started_at ?? stats.started_at);
    }
    if (!acct.token_secret_id) { stats.error = 'Outlook is not connected.'; return; }
    if (trigger !== 'continued') await fetchPhase(sb, acct, stats);
    await readPhase(sb, stats, startedMs + READ_BUDGET_MS);
    const { count } = await sb.from('kount_ot_inbox').select('id', { count: 'exact', head: true }).eq('state', 'unread').lt('attempts', MAX_ATTEMPTS);
    stats.remaining = count ?? 0;
    chain = (count ?? 0) > 0 && depth < MAX_CHAIN;
  } catch (e) {
    stats.error = msg(e);
    stats.reconnect = e instanceof GraphError && e.reauth;
    console.error('[kount-order-mail] pull failed:', stats.error);
  } finally {
    await sb.from('kount_ot_mail_account').update({ running_since: null, last_run: { ...stats, finished_at: nowIso() }, updated_at: nowIso() }).eq('id', 1);
  }
  if (chain) {
    const { data: secret } = await sb.rpc('kount_ot_mail_cron_secret');
    await fetch(SELF_URL, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'x-kount-cron': String(secret ?? '') },
      body: JSON.stringify({ action: 'continue', depth: depth + 1 }),
    }).catch(e => console.error('[kount-order-mail] could not continue:', msg(e)));
  }
}

interface Account { vendor_domains: string[] | null; suggested_domains: Record<string, number> | null; fetched_through: string | null }
interface GraphMessage { id: string; subject?: string; receivedDateTime: string; conversationId?: string; internetMessageId?: string; from?: { emailAddress?: { address?: string; name?: string } } }

async function fetchPhase(sb: SupabaseClient, acct: Account, stats: Stats) {
  const { data: refresh, error } = await sb.rpc('kount_ot_mail_token_get');
  if (error) throw error;
  if (!refresh) throw new Error('Outlook is not connected.');
  const tok = await refreshAccess(String(refresh));
  if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });

  const prevThrough = acct.fetched_through ? Date.parse(acct.fetched_through) : 0;
  const sinceMs = prevThrough ? prevThrough - OVERLAP_MS : Date.now() - FIRST_LOOKBACK_DAYS * 86_400_000;
  const since = new Date(sinceMs).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const domains = acct.vendor_domains ?? [];
  const suggested: Record<string, number> = { ...(acct.suggested_domains ?? {}) };
  let newest = prevThrough;
  let url = `/me/messages?$filter=receivedDateTime ge ${since} and hasAttachments eq true&$orderby=receivedDateTime asc`
    + '&$select=id,subject,from,receivedDateTime,conversationId,internetMessageId&$top=50';
  while (url && stats.messages < MAX_MESSAGES) {
    const page = await graphGet<{ value?: GraphMessage[]; '@odata.nextLink'?: string }>(tok.access_token, url);
    for (const m of page.value ?? []) {
      stats.messages++;
      const received = Date.parse(m.receivedDateTime);
      if (received > newest) newest = received;
      const domain = domainOf(m.from?.emailAddress?.address);
      if (!domain || onList(domain, OWN_DOMAINS)) continue;
      const listed = onList(domain, domains);
      const atts = await graphGet<{ value?: GraphAttachment[] }>(tok.access_token,
        `/me/messages/${encodeURIComponent(m.id)}/attachments?$select=id,name,contentType,size,isInline`);
      const pdfs = (atts.value ?? []).filter(isPdfAttachment);
      if (!pdfs.length) continue;
      if (!listed) {
        // nothing from an unlisted sender is read or stored: only its domain is counted, for the person to add
        if (received > prevThrough && pdfs.some(p => looksLikePurchaseDoc(m.subject, p.name))) suggested[domain] = (Number(suggested[domain]) || 0) + 1;
        continue;
      }
      for (const p of pdfs) await takePdf(sb, tok.access_token, m, p, stats);
    }
    url = page['@odata.nextLink'] ?? '';
  }
  const { error: upErr } = await sb.from('kount_ot_mail_account').update({
    fetched_through: newest ? new Date(newest).toISOString() : null, suggested_domains: suggested, updated_at: nowIso(),
  }).eq('id', 1);
  if (upErr) throw upErr;
}

async function takePdf(sb: SupabaseClient, accessToken: string, m: GraphMessage, a: GraphAttachment, stats: Stats) {
  const { data: seen } = await sb.from('kount_ot_inbox').select('id').eq('message_id', m.id).eq('attachment_id', a.id).maybeSingle();
  if (seen) return;
  const full = await graphGet<{ contentBytes?: string }>(accessToken, `/me/messages/${encodeURIComponent(m.id)}/attachments/${encodeURIComponent(a.id)}`);
  const b64 = String(full.contentBytes ?? '');
  if (!b64.startsWith('JVBER')) return;                       // not really a PDF
  const bytes = fromBase64(b64);
  const hash = await sha256Hex(bytes);
  const { data: dup } = await sb.from('kount_ot_inbox').select('id').eq('content_hash', hash).maybeSingle();
  if (dup) return;                                            // the same PDF came in another email
  const id = crypto.randomUUID();
  const path = `docs/${id}.pdf`;
  const up = await sb.storage.from(BUCKET).upload(path, bytes, { contentType: 'application/pdf', upsert: true });
  if (up.error) throw up.error;
  const { error } = await sb.from('kount_ot_inbox').insert({
    id, message_id: m.id, attachment_id: a.id, internet_message_id: m.internetMessageId ?? null, conversation_id: m.conversationId ?? null,
    subject: (m.subject ?? '').slice(0, 300), sender_email: m.from?.emailAddress?.address ?? null, sender_name: m.from?.emailAddress?.name ?? null,
    received_at: m.receivedDateTime, file_name: (a.name ?? 'document.pdf').slice(0, 200), size_bytes: a.size ?? bytes.length,
    content_hash: hash, storage_path: path, state: 'unread',
  });
  if (error) {
    await sb.storage.from(BUCKET).remove([path]);
    if (error.code === '23505') return;                       // a parallel run took it
    throw error;
  }
  stats.new_pdfs++;
}

interface InboxRow { id: string; message_id: string; conversation_id: string | null; file_name: string | null; storage_path: string; attempts: number }

async function readPhase(sb: SupabaseClient, stats: Stats, deadline: number) {
  let data = await loadTracker(sb);
  const today = laParts().isoDate;
  while (Date.now() < deadline) {
    const { data: batch, error } = await sb.from('kount_ot_inbox').select('id, message_id, conversation_id, file_name, storage_path, attempts')
      .eq('state', 'unread').lt('attempts', MAX_ATTEMPTS).order('received_at', { ascending: true }).limit(READ_CONCURRENCY);
    if (error) throw error;
    if (!batch?.length) break;
    // count the attempt BEFORE reading, so a run cut off mid-read can't retry the same PDF forever
    for (const b of batch as InboxRow[]) await sb.from('kount_ot_inbox').update({ attempts: b.attempts + 1 }).eq('id', b.id);

    const results = await Promise.all((batch as InboxRow[]).map(async b => {
      try {
        const dl = await sb.storage.from(BUCKET).download(b.storage_path);
        if (dl.error || !dl.data) throw dl.error ?? new Error('PDF missing from storage');
        const pdf = toBase64(new Uint8Array(await dl.data.arrayBuffer()));
        const r = await readPurchasePdf({ pdf, fileName: b.file_name || 'document.pdf', flow: 'kount-order-mail', metadata: { inbox_id: b.id } });
        return { b, doc: r.document as ReadDoc, model: r.model, err: null as string | null };
      } catch (e) {
        return { b, doc: null, model: null, err: msg(e) };
      }
    }));

    // decide one by one: an apply changes what the next document matches
    for (const r of results) {
      if (r.err || !r.doc) {
        stats.failed++;
        await sb.from('kount_ot_inbox').update({ read_error: String(r.err).slice(0, 500), state: r.b.attempts + 1 >= MAX_ATTEMPTS ? 'error' : 'unread' }).eq('id', r.b.id);
        continue;
      }
      stats.read++;
      await sb.from('kount_ot_inbox').update({ parsed: r.doc, model: r.model, read_error: null }).eq('id', r.b.id);
      const d = decideMailDocument(r.doc, { id: r.b.id, message_id: r.b.message_id, conversation_id: r.b.conversation_id, file_name: r.b.file_name, storage_path: r.b.storage_path },
        data, today, fmtMoney);
      if (d.state === 'applied') {
        const { error: aErr } = await sb.rpc('kount_ot_apply_document', { p: d.payload });
        if (!aErr) { stats.applied++; data = await loadTracker(sb); continue; }
        await sb.from('kount_ot_inbox').update({
          state: 'pending', decision: `Could not apply it automatically (${aErr.message}). Review it.`.slice(0, 1000), order_id: d.payload.order_id ?? null,
        }).eq('id', r.b.id);
        stats.pending++;
        continue;
      }
      await sb.from('kount_ot_inbox').update({
        state: d.state, decision: d.reason.slice(0, 1000), order_id: d.state === 'pending' ? d.orderId : null, decided_by: 'morning mail pull',
      }).eq('id', r.b.id);
      if (d.state === 'pending') stats.pending++; else stats.ignored++;
    }
  }
}

async function selectAll<T>(sb: SupabaseClient, table: string, columns = '*'): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb.from(table).select(columns).order('created_at', { ascending: true }).range(from, from + 999);
    if (error) throw error;
    out.push(...((data ?? []) as T[]));
    if (!data || data.length < 1000) return out;
  }
}

async function loadTracker(sb: SupabaseClient) {
  const num = (x: unknown) => (x == null || x === '' ? null : Number.isFinite(Number(x)) ? Number(x) : null);
  const [orders, lines, items, documents] = await Promise.all([
    selectAll<OtOrder>(sb, 'kount_ot_orders'),
    selectAll<OtLine>(sb, 'kount_ot_lines'),
    selectAll<OtItem>(sb, 'kount_ot_items'),
    selectAll<OtDocument>(sb, 'kount_ot_documents', 'id, order_id, kind, doc_number, doc_date, vendor_name, total, file_name, storage_path, created_at, source_conversation_id'),
  ]);
  return {
    orders,
    lines: lines.map(l => ({ ...l, qty: Number(l.qty) || 0, unit_price: num(l.unit_price) })),
    items: items.map(i => ({ ...i, pack_size: num(i.pack_size), reorder_point: num(i.reorder_point), lead_time_days: num(i.lead_time_days) })),
    documents,
  };
}
