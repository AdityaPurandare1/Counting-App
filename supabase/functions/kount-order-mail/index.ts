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
//   {action:'stub_check'} pg_cron 'kount-order-mail-stubs' (0175, same secret): once an hour 10:30-17:30 in Los
//                        Angeles after the morning pull, our own e-mails of the last 2 days are read for check stubs /
//                        payment proofs again (the stub step alone), so a stub sent during the day is seen that day
//   {action:'pull', since, domain?}  a person: PAST e-mails (v1.13) — that listed vendor's (or every listed vendor's)
//                        PDFs and tracking since that day, through the same rules; the morning mark is left alone;
//                        documents older than 30 days start no orders, older tracking moves no lines
//   {action:'connect_start' | 'connect_poll' | 'pull' | 'redecide'}  a person: JWT of an ACTIVE admin /
//                        corporate app_users row (deployed with --no-verify-jwt for the cron
//                        call; every person call is checked here instead)
//
// A pull answers at once and runs in the background (EdgeRuntime.waitUntil); one at a time
// (kount_ot_mail_begin_run). The admin watches kount_ot_mail_status().

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';
import { readPurchaseFile, readPurchasePdf } from '../_shared/purchase-doc.ts';
import * as XLSX from 'https://esm.sh/xlsx@0.18.5';
import { releaseMailCandidate, planReleaseMail, matchRelease, linkStorageRows, isCustomItem, itemLocation, EE_WAREHOUSE, accountingBoxes, acctMailVerdict, firstAccountingMail, trackableInvoice, type AcctMail, awaitingApproval, decideMailDocument, extractTracking, isOwnSender, paymentRequestOf, planQuoteApprovals, quoteKey, scheduledPullDue, stubCheckDue, searchableQuote, type MailMessage, isSpreadsheet, isStorageLine, keepOtherAttachment, orderForEmail, sheetUpdates, statusRank, orderVenues, planStorageLine, storageMoveRows, type MailDecideOptions, type OtDocument, type OtItem, type OtLine, type OtMove, type OtOrder, type ReadDoc, type TrackingHit } from '../_shared/orderTracker.ts';
import { readReleaseMail, releaseContext } from './release.ts';
import { deviceCodePoll, deviceCodeStart, DRAFT_SCOPE, GraphError, graphGet, graphPost, graphPostJson, refreshAccess, SEND_SCOPE } from './graph.ts';
import { latestThreadMail, laterMail, ALL_DOC_KINDS, isInvoiceFile, proofMatches, proofPrinted, saysPaid, stubThreadInvoices, type ProofMatch, type ProofRead, domainOf, fromBase64, idTokenMailbox, invoiceToken, isPdfAttachment, isStubAttachment, kindAllowed, laParts, paidInvoices, stubInvoices, type R365Tx, looksLikePurchaseDoc, onList, OWN_DOMAINS, safeEqual, sha256Hex, toBase64, wantsAttachment, sentToVendor, takeEmailSentDay, type GraphAttachment, type ThreadMessage } from './rules.ts';

// 2026-11 key rotation: read the new API keys (SUPABASE_SECRET_KEYS / SUPABASE_PUBLISHABLE_KEYS are JSON maps
// keyed by key name). Legacy env fallback only until the legacy keys are disabled; remove it at cleanup.
function newApiKey(mapEnv: string, names: string[], legacyEnv: string): string {
  try {
    const m = JSON.parse(Deno.env.get(mapEnv) ?? "{}") as Record<string, string>;
    for (const n of names) if (typeof m?.[n] === "string" && m[n]) return m[n];
  } catch { /* fall through */ }
  return Deno.env.get(legacyEnv) ?? "";
}
const NEW_SECRET_KEY = () => newApiKey("SUPABASE_SECRET_KEYS", ["keva_secret_2026_11", "default"], "SUPABASE_SERVICE_ROLE_KEY");
const NEW_PUBLISHABLE_KEY = () => newApiKey("SUPABASE_PUBLISHABLE_KEYS", ["default"], "SUPABASE_ANON_KEY");


declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = NEW_PUBLISHABLE_KEY();
const SUPABASE_SERVICE_ROLE_KEY = NEW_SECRET_KEY();
const SELF_URL = `${SUPABASE_URL}/functions/v1/kount-order-mail`;

const BUCKET = 'kount-order-docs';
const ALLOWED_ROLES = new Set(['admin', 'corporate']);
// v0.96 (0148): the Order tracker permission; a row from before 0148 (no list) by its role, as before
const mayUseOrderTracker = (p: { role?: unknown; features?: unknown }) =>
  Array.isArray(p.features) ? (p.features as unknown[]).includes('purchasing:order-tracker') : ALLOWED_ROLES.has(String(p.role));
const FIRST_LOOKBACK_DAYS = 30;
// v1.13 past e-mails (a backfill): what it reads is old — an older quote or invoice most likely belongs to an order
// the tracker already has (it waits in the Inbox instead of starting a copy), and older tracking is added to its
// order without moving the lines. Both only for mail this recent:
const RECENT_DAYS = 30;
// a past-e-mails pull's reading of mail, before the PDFs are read (the read phase has its own budget)
const BACKFILL_FETCH_MS = 90_000;
const isRecent = (iso: string | null | undefined) => !!iso && Date.now() - Date.parse(iso) <= RECENT_DAYS * 86_400_000;

/** A backfill's first day ('2026-09-01'): a real day, not before 2025, not in the future. 0 = not one. */
function backfillStart(since: unknown): number {
  const v = String(since ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) return 0;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return Number.isFinite(ms) && ms >= Date.parse('2025-01-01T00:00:00Z') && ms <= Date.now() ? ms : 0;
}
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
  const { data: profile, error: pErr } = await sb.from('app_users').select('role,is_active,features').eq('email', email).limit(1).maybeSingle();
  if (pErr) return reject(500, 'Failed to verify caller');
  if (!profile || profile.is_active !== true || !mayUseOrderTracker(profile)) {
    return reject(403, 'The order mail pull needs the Order tracker permission');
  }
  return { email };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reject(405, 'Method not allowed');
  const body = await req.json().catch(() => ({})) as { action?: string; depth?: number; number?: string; document_id?: string; since?: string; domain?: string };
  const action = String(body.action ?? '');
  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    // ── the scheduled job (and its own continuation) ──
    if (action === 'cron' || action === 'continue' || action === 'stub_check') {
      const { data: secret } = await sb.rpc('kount_ot_mail_cron_secret');
      if (!secret || !safeEqual(req.headers.get('x-kount-cron') || '', String(secret))) return reject(401, 'Not allowed');
      // 0175: the stubs checked again during the day - after the morning pull, 10:00-17:59 in Los Angeles
      if (action === 'stub_check') {
        const { data: acctNow, error: aErr } = await sb.from('kount_ot_mail_account').select('last_fetch_at').eq('id', 1).single();
        if (aErr) throw aErr;
        if (!stubCheckDue(acctNow?.last_fetch_at ?? null)) return json(200, { skipped: "outside 10:00-17:59 in Los Angeles, or today's morning pull has not run" });
        const { data: locked } = await sb.rpc('kount_ot_mail_begin_run');
        if (locked !== true) return json(200, { skipped: 'a pull is already running' });
        background(runStubCheck(sb));
        return json(202, { started: true });
      }
      // 9:00-13:59 in Los Angeles while today's mail is unread: one pull a morning, a missed one retried until 2 pm (0160)
      if (action === 'cron') {
        const { data: acctNow, error: aErr } = await sb.from('kount_ot_mail_account').select('last_fetch_at').eq('id', 1).single();
        if (aErr) throw aErr;
        if (!scheduledPullDue(acctNow?.last_fetch_at ?? null)) return json(200, { skipped: "outside 9:00-13:59 in Los Angeles, or today's mail is already read" });
      }
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
      // who signed in, from the id token (asking /me would need User.Read, which the app isn't granted)
      const mailbox = idTokenMailbox(String(r.json.id_token ?? '')) || caller.email;
      const { error: setErr } = await sb.rpc('kount_ot_mail_token_set', { p_token: refresh, p_mailbox: mailbox, p_by: caller.email });
      if (setErr) throw setErr;
      // the first pull starts right away (the last 30 days)
      const { data: locked } = await sb.rpc('kount_ot_mail_begin_run');
      if (locked === true) background(runPull(sb, 'first', 0));
      return json(200, { state: 'connected', mailbox });
    }

    if (action === 'pull') {
      // v1.13: since (+ domain) = PAST e-mails: that listed vendor's quotes, invoices, shipping notices and tracking since
      // that day (the user: "when I add another domain, i want to be able to pull emails from that domain only. Along
      // with marking since what date"). Without a domain, every listed vendor. The morning mark is not moved.
      const fromMs = body.since == null || body.since === '' ? 0 : backfillStart(body.since);
      if (body.since && !fromMs) return reject(400, 'Pick a day from 2025 on, not in the future.');
      let only: string | null = null;
      if (body.domain != null && body.domain !== '') {
        if (!fromMs) return reject(400, 'Pick the day to pull that domain\'s e-mails from.');
        only = String(body.domain).trim().toLowerCase();
        const { data: acctD, error: dErr } = await sb.from('kount_ot_mail_account').select('vendor_domains').eq('id', 1).single();
        if (dErr) throw dErr;
        if (!((acctD?.vendor_domains ?? []) as string[]).map(d => String(d).toLowerCase()).includes(only)) return reject(400, `${only} is not on the vendor list. Add it first.`);
      }
      const { data: locked } = await sb.rpc('kount_ot_mail_begin_run');
      if (locked !== true) return json(200, { started: false, reason: 'A pull is already running.' });
      background(runPull(sb, fromMs ? `past e-mails: ${only ?? 'every listed vendor'} since ${body.since} (by ${caller.email})` : `by ${caller.email}`, 0, fromMs, only));
      return json(202, { started: true });
    }

    if (action === 'redecide') {
      // after a save in the admin: waiting items that now match an order go in (cheap — no reading)
      const stats = blankStats(`re-check by ${caller.email}`);
      await redecidePending(sb, stats, Date.now() + 40_000);
      await r365PaidPhase(sb, stats);
      await storagePhase(sb, stats, caller.email);
      return json(200, { applied: stats.applied, tracking: stats.tracking, paid: stats.paid, stubs: stats.stubs, r365_error: stats.r365_error ?? null, storage: stats.storage ?? 0 });
    }

    if (action === 'find') {
      // one invoice / quote by its number, however old — the morning pull reads only what came since it last ran
      // (its first run went back 30 days), so an invoice e-mailed before that is never seen
      const number = String(body.number ?? '').trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9 _.\/-]{2,40}$/.test(number)) return reject(400, 'Enter an invoice or quote number.');
      const { data: locked } = await sb.rpc('kount_ot_mail_begin_run');
      if (locked !== true) return json(200, { found: 0, reason: 'A pull is running — try again in a minute.' });
      const stats = blankStats(`find ${number} by ${caller.email}`);
      try {
        const { seen: found, messages, token } = await findPhase(sb, number, stats);
        const { data: acct } = await sb.from('kount_ot_mail_account').select('doc_kinds').eq('id', 1).single();
        const kinds: string[] = Array.isArray(acct?.doc_kinds) && acct.doc_kinds.length ? acct.doc_kinds : [...ALL_DOC_KINDS];
        if (stats.new_pdfs) await readPhase(sb, stats, Date.now() + 90_000, kinds);
        await r365PaidPhase(sb, stats);
        // their other attachments (an Excel of tracking numbers) onto the order the PDFs just went to
        if (messages.length) await attachOthersOf(sb, token, messages, stats);
        return json(200, { found, new_pdfs: stats.new_pdfs, applied: stats.applied, pending: stats.pending, ignored: stats.ignored, failed: stats.failed, paid: stats.paid, others: stats.others ?? 0 });
      } finally {
        await sb.from('kount_ot_mail_account').update({ running_since: null, updated_at: nowIso() }).eq('id', 1);
      }
    }

    if (action === 'sheet') {
      // a delivery-status sheet attached by hand (or all of them, to re-read): each row moves its own line
      let q = sb.from('kount_ot_documents').select('id, order_id, file_name, storage_path').eq('kind', 'other').not('order_id', 'is', null);
      if (body.document_id) q = q.eq('id', String(body.document_id));
      const { data: docs, error } = await q;
      if (error) throw error;
      const out = { sheets: 0, rows: 0, matched: 0, updated: 0, tracking: 0 };
      for (const d of (docs ?? []).filter(x => isSpreadsheet(x.file_name)).sort((a, b) => String(a.file_name).localeCompare(String(b.file_name)))) {
        const r = await applySheet(sb, d as SheetDoc);
        out.sheets++; out.rows += r.rows; out.matched += r.matched; out.updated += r.updated; out.tracking += r.tracking;
      }
      return json(200, out);
    }

    if (action === 'storage') {
      // Warehouse: record the E&E deliveries / returns that can be read now
      const stats = blankStats(`storage by ${caller.email}`);
      await storagePhase(sb, stats, caller.email);
      return json(200, { recorded: stats.storage ?? 0, review: stats.storage_review ?? 0, error: stats.storage_error ?? null });
    }

    if (action === 'message_link') {
      // v1.12: a vendor e-mail opened in Outlook on the web — Reply there keeps the quote approval in its thread
      // without Mail.Send. Only for the mailbox's owner (the link opens in their own Outlook). Read-only.
      const mid = typeof (body as { message_id?: unknown }).message_id === 'string' ? String((body as { message_id?: string }).message_id).trim().slice(0, 300) : '';
      if (!mid) return reject(400, 'message_id is required');
      const { data: acct, error: aErr } = await sb.from('kount_ot_mail_account').select('mailbox, token_secret_id').eq('id', 1).single();
      if (aErr) throw aErr;
      if (!acct?.token_secret_id) return json(200, { link: null, reason: 'not_connected' });
      if (String(acct.mailbox ?? '').toLowerCase() !== caller.email) return json(200, { link: null, reason: 'not_owner', mailbox: acct.mailbox ?? null });
      const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
      if (tErr || !refresh) return json(200, { link: null, reason: 'not_connected' });
      const tok = await refreshAccess(String(refresh));
      if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
      try {
        const m = await graphGet<{ webLink?: string }>(tok.access_token, `/me/messages/${encodeURIComponent(mid)}?$select=webLink`);
        const link = typeof m.webLink === 'string' && /^https:\/\/outlook\.(office365|office|live)\.com\//i.test(m.webLink) ? m.webLink : null;
        return json(200, { link, ...(link ? {} : { reason: 'gone' }) });
      } catch (e) {
        if (e instanceof GraphError && (e.status === 404 || e.status === 400)) return json(200, { link: null, reason: 'gone' });
        throw e;
      }
    }
    if (action === 'approve_quote') {
      // v1.11: the quote approval e-mail, from the connected mailbox, then the lines stamped approved
      const p = body as { order_id?: unknown; line_ids?: unknown; quote_number?: unknown; to?: unknown; cc?: unknown; subject?: unknown; text?: unknown; reply_to?: unknown };
      const isEmail = (x: unknown) => typeof x === 'string' && /^[^\s@<>(),;:"]+@[^\s@<>(),;:"]+\.[^\s@<>(),;:"]+$/.test(x) && x.length <= 200;
      const uuid = (x: unknown) => typeof x === 'string' && /^[0-9a-f-]{36}$/i.test(x);
      const to = Array.isArray(p.to) ? p.to : [], cc = Array.isArray(p.cc) ? p.cc : [], ids = Array.isArray(p.line_ids) ? p.line_ids : [];
      const quote = typeof p.quote_number === 'string' && p.quote_number.trim() ? p.quote_number.trim().slice(0, 100) : null;
      const subject = typeof p.subject === 'string' ? p.subject.trim().slice(0, 300) : '';
      const text = typeof p.text === 'string' ? p.text.slice(0, 5000) : '';
      const replyTo = typeof p.reply_to === 'string' && p.reply_to.trim() ? p.reply_to.trim().slice(0, 300) : null;
      if (!uuid(p.order_id) || !ids.length || ids.length > 200 || !ids.every(uuid) || !to.length || to.length > 10 || cc.length > 10
        || ![...to, ...cc].every(isEmail) || !text.trim() || (!replyTo && !subject)) {
        return reject(400, 'The approval e-mail needs the order, its quoted lines, who it goes to and a message.');
      }
      // only the person whose mailbox is connected sends from it; anyone else sends from their own Outlook
      const { data: acct, error: aErr } = await sb.from('kount_ot_mail_account').select('mailbox, token_secret_id').eq('id', 1).single();
      if (aErr) throw aErr;
      if (!acct?.token_secret_id) return json(200, { sent: false, reason: 'not_connected' });
      if (String(acct.mailbox ?? '').toLowerCase() !== caller.email) return json(200, { sent: false, reason: 'not_owner', mailbox: acct.mailbox ?? null });
      // the lines must be this order's Quoted lines of that quote, still waiting
      const { data: ls, error: lErr } = await sb.from('kount_ot_lines').select('id, order_id, status, quote_number').in('id', ids as string[]);
      if (lErr) throw lErr;
      if ((ls ?? []).length !== new Set(ids as string[]).size
        || (ls ?? []).some(l => l.order_id !== p.order_id || l.status !== 'QUOTED' || quoteKey(l.quote_number ?? '') !== quoteKey(quote ?? ''))) {
        return reject(409, 'Those lines are no longer this quote\'s Quoted lines — reload the order.');
      }
      // a Mail.Send token from the stored sign-in; the read token is not touched (and nothing is stored)
      const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
      if (tErr || !refresh) return json(200, { sent: false, reason: 'not_connected' });
      let token: string;
      try {
        token = (await refreshAccess(String(refresh), SEND_SCOPE)).access_token;
      } catch (e) {
        if (e instanceof GraphError) return json(200, { sent: false, reason: 'not_granted', detail: e.message.slice(0, 200) });
        throw e;
      }
      const rcpt = (xs: unknown[]) => xs.map(a => ({ emailAddress: { address: String(a) } }));
      const message = { toRecipients: rcpt(to), ccRecipients: rcpt(cc), body: { contentType: 'Text', content: text } };
      try {
        // in the vendor's quote thread when it came by e-mail (Re: its subject), else a new e-mail; sent once
        if (replyTo) await graphPost(token, `/me/messages/${encodeURIComponent(replyTo)}/reply`, { message });
        else await graphPost(token, '/me/sendMail', { message: { ...message, subject }, saveToSentItems: true });
      } catch (e) {
        if (e instanceof GraphError && (e.status === 401 || e.status === 403)) return json(200, { sent: false, reason: 'not_granted', detail: e.message.slice(0, 200) });
        if (e instanceof GraphError) return json(200, { sent: false, detail: e.message.slice(0, 200) });
        throw e;
      }
      // sent: the lines are approved (the same columns the 9 o'clock pull fills from an approval e-mail, 0157)
      const firstLine = text.split(/\r?\n/).map(s => s.trim()).find(s => /approv/i.test(s)) ?? text.trim().split(/\r?\n/)[0];
      const { data: upd, error: uErr } = await sb.from('kount_ot_lines')
        .update({ quote_approved_at: nowIso(), quote_approved_for: quote, quote_approval_note: `Sent from the Order tracker by ${caller.email}: ${firstLine}`.slice(0, 300), quote_approval_message_id: replyTo })
        .in('id', ids as string[]).eq('status', 'QUOTED').select('id');
      if (uErr) return json(200, { sent: true, approved: 0, detail: `Sent, but the lines were not marked: ${uErr.message}`.slice(0, 200) });
      return json(200, { sent: true, approved: upd?.length ?? 0 });
    }
    if (action === 'approvals') {
      // the Quoted lines' approval e-mails (0157), on demand: "I've sent it - check now"
      const stats = blankStats(`approvals by ${caller.email}`);
      await approvalPhase(sb, stats);
      return json(200, { approved: stats.approved ?? 0, error: stats.approval_error ?? null });
    }

    if (action === 'draft_mail') {
      // v1.21 the user: "new emails can be drafted in the app and opened in outlook to be sent" - the payment request
      // to AP as a real draft in the connected mailbox, the invoice PDFs attached; the person sends it from Outlook.
      // drafted = false with a reason when it can't (not_granted: IT has not given the app Mail.ReadWrite) - the admin
      // then opens a new e-mail and downloads the PDFs instead.
      const p = body as { to?: unknown; cc?: unknown; subject?: unknown; text?: unknown; document_ids?: unknown };
      const isEmail = (x: unknown) => typeof x === 'string' && /^[^\s@<>(),;:"]+@[^\s@<>(),;:"]+\.[^\s@<>(),;:"]+$/.test(x) && x.length <= 200;
      const uuid = (x: unknown) => typeof x === 'string' && /^[0-9a-f-]{36}$/i.test(x);
      const to = Array.isArray(p.to) ? p.to : [], cc = Array.isArray(p.cc) ? p.cc : [], docIds = Array.isArray(p.document_ids) ? p.document_ids : [];
      const subject = typeof p.subject === 'string' ? p.subject.trim().slice(0, 300) : '';
      const text = typeof p.text === 'string' ? p.text.slice(0, 8000) : '';
      if (!to.length || to.length > 10 || cc.length > 10 || ![...to, ...cc].every(isEmail) || !subject || !text.trim() || docIds.length > 5 || !docIds.every(uuid)) {
        return reject(400, 'The draft needs who it goes to, a subject, a message, and at most 5 documents.');
      }
      const { data: acct, error: aErr } = await sb.from('kount_ot_mail_account').select('mailbox, token_secret_id').eq('id', 1).single();
      if (aErr) throw aErr;
      if (!acct?.token_secret_id) return json(200, { drafted: false, reason: 'not_connected' });
      if (String(acct.mailbox ?? '').toLowerCase() !== caller.email) return json(200, { drafted: false, reason: 'not_owner', mailbox: acct.mailbox ?? null });
      const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
      if (tErr || !refresh) return json(200, { drafted: false, reason: 'not_connected' });
      let token: string;
      try {
        token = (await refreshAccess(String(refresh), DRAFT_SCOPE)).access_token;
      } catch (e) {
        if (e instanceof GraphError) return json(200, { drafted: false, reason: 'not_granted', detail: e.message.slice(0, 200) });
        throw e;
      }
      // the tracker's own documents only (an invoice / quote / stub saved on an order), as files on the draft
      const attachments: Array<Record<string, unknown>> = [];
      const skipped: string[] = [];
      if (docIds.length) {
        const { data: docs, error: dErr } = await sb.from('kount_ot_documents').select('id, kind, doc_number, file_name, storage_path, order_id').in('id', docIds as string[]);
        if (dErr) throw dErr;
        for (const d of docs ?? []) {
          if (!d.storage_path || !d.order_id) continue;
          const name = String(d.file_name || `${d.doc_number ?? d.kind}.pdf`).slice(0, 200);
          const { data: blob, error: sErr } = await sb.storage.from(BUCKET).download(d.storage_path);
          if (sErr || !blob) { skipped.push(name); continue; }
          const bytes = new Uint8Array(await blob.arrayBuffer());
          if (bytes.length > 3 * 1024 * 1024) { skipped.push(name); continue; }      // Graph's limit for a file sent inline
          attachments.push({ '@odata.type': '#microsoft.graph.fileAttachment', name, contentType: blob.type || 'application/pdf', contentBytes: toBase64(bytes) });
        }
      }
      const rcpt = (xs: unknown[]) => xs.map(a => ({ emailAddress: { address: String(a) } }));
      try {
        const draft = await graphPostJson<{ id?: string; webLink?: string }>(token, '/me/messages', {
          subject, body: { contentType: 'Text', content: text }, toRecipients: rcpt(to), ccRecipients: rcpt(cc), attachments,
        });
        return json(200, { drafted: true, link: draft.webLink ?? null, attached: attachments.length, skipped });
      } catch (e) {
        if (e instanceof GraphError && (e.status === 401 || e.status === 403)) return json(200, { drafted: false, reason: 'not_granted', detail: e.message.slice(0, 200) });
        if (e instanceof GraphError) return json(200, { drafted: false, detail: e.message.slice(0, 200) });
        throw e;
      }
    }

    if (action === 'accounting') {
      // v1.21: one order's invoices sent to accounting (0174), on demand: "I've sent it - check now"
      const orderId = String((body as { order_id?: unknown }).order_id ?? '').trim();
      if (!orderId) return reject(400, 'order_id is required');
      const stats = blankStats(`accounting by ${caller.email}`);
      await accountingPhase(sb, stats, Date.now(), orderId);
      return json(200, { found: stats.acct_sent ?? 0, requested: stats.acct_requested ?? 0, checked: stats.acct_checked ?? 0, error: stats.acct_error ?? null });
    }

    if (action === 'releases') {
      // the release engine (0179), on demand: "Check my e-mails to E&E now" - then E&E's invoices link to what it found
      const stats = blankStats(`releases by ${caller.email}`);
      const token = await mailAccessToken(sb);
      if (!token) return json(200, { recorded: 0, error: 'Outlook is not connected.' });
      await releasePhase(sb, stats, token, Date.now() + 100_000);
      await storagePhase(sb, stats, caller.email);
      return json(200, { seen: stats.releases_seen ?? 0, read: stats.releases_read ?? 0, recorded: stats.releases_recorded ?? 0, review: stats.releases_review ?? 0,
        linked: stats.storage_linked ?? 0, note: stats.releases_note ?? null, error: stats.releases_error ?? stats.storage_error ?? null });
    }

    if (action === 'threads') {
      // each open order's latest e-mail (0178), on demand - the hourly check does the same
      const stats = blankStats(`order threads by ${caller.email}`);
      const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
      if (tErr) throw tErr;
      if (!refresh) return json(200, { checked: 0, error: 'Outlook is not connected.' });
      const tok = await refreshAccess(String(refresh));
      if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
      await threadPhase(sb, stats, tok.access_token, Date.now() + 100_000);
      return json(200, { checked: stats.threads_checked ?? 0, moved: stats.threads_moved ?? 0, note: stats.threads_note ?? null, error: stats.threads_error ?? null });
    }

    if (action === 'sent') {
      // when each order went to the vendor, from its e-mail threads (0147)
      const stats = blankStats(`sent dates by ${caller.email}`);
      await sentPhase(sb, stats);
      return json(200, { dated: stats.sent ?? 0, error: stats.sent_error ?? null });
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
  applied: number; pending: number; ignored: number; failed: number; tracking: number; paid: number; stubs: number; remaining?: number; error: string | null; reconnect: boolean; r365_error?: string;
  /** E&E storage lines recorded as stock moves / left for a person / why the step failed */
  storage?: number; storage_review?: number; storage_error?: string;
  /** other attachments (Excel, photos) kept on orders / with no known order yet / why the step failed */
  others?: number; others_unplaced?: number; others_error?: string;
  /** orders dated by the e-mail that sent them to the vendor (0147) / why the step failed */
  sent?: number; sent_error?: string;
  /** Quoted lines whose approval e-mail was found (0157) / why the step failed */
  approved?: number; approval_error?: string;
  /** lines marked as payment-requested from the team's e-mails to AP (0153) / why the step failed */
  pay_requests?: number; pay_requests_error?: string;
  /** invoice lines marked Paid from our own proof of a card / online payment e-mailed in their thread (11/17) */
  paid_by_proof?: number;
  /** payment proof files read by the reader (v1.21) / why the stub step stopped short */
  proofs_read?: number; stub_note?: string;
  /** stubs already on file from an e-mail inside h.wood, now found sent on to the vendor (0175) */
  stubs_sent?: number;
  /** unpaid invoices searched / their lines stamped as sent to AP or GA (0174) / what was left or failed */
  acct_checked?: number; acct_sent?: number; acct_error?: string;
  /** lines whose payment request was found as our own e-mail to AP / GA (0174) */
  acct_requested?: number;
  /** open orders whose threads were read / whose last e-mail moved / why it stopped short or failed (0178) */
  threads_checked?: number; threads_moved?: number; threads_note?: string; threads_error?: string;
  /** the release engine (0179): e-mails to E&E found / read by the reader / recorded as releases / left for a person */
  releases_seen?: number; releases_read?: number; releases_recorded?: number; releases_review?: number; releases_note?: string; releases_error?: string;
  /** E&E invoice lines that took a release already asked by e-mail (0179) */
  storage_linked?: number;
}
const blankStats = (trigger: string): Stats => ({ trigger, started_at: nowIso(), messages: 0, new_pdfs: 0, read: 0, applied: 0, pending: 0, ignored: 0, failed: 0, tracking: 0, paid: 0, stubs: 0, error: null, reconnect: false });

/** Runs with the lock held (kount_ot_mail_begin_run returned true) and always releases it. */
/** fromMs / only = a past-e-mails pull (v1.13): one listed vendor (or all) since that day; 0 = the normal pull. */
async function runPull(sb: SupabaseClient, trigger: string, depth: number, fromMs = 0, only: string | null = null) {
  const startedMs = Date.now();
  const stats = blankStats(trigger);
  let chain = false;
  try {
    const { data: acct, error } = await sb.from('kount_ot_mail_account')
      .select('token_secret_id, vendor_domains, doc_kinds, suggested_domains, fetched_through, last_run').eq('id', 1).single();
    if (error) throw error;
    // a continuation adds to the run it continues, so the admin sees one morning's totals
    if (trigger === 'continued' && acct.last_run) {
      const prev = acct.last_run as Partial<Stats>;
      for (const k of ['messages', 'new_pdfs', 'read', 'applied', 'pending', 'ignored', 'failed', 'tracking', 'paid', 'stubs'] as const) stats[k] = Number(prev[k]) || 0;
      stats.trigger = String(prev.trigger ?? trigger);
      stats.started_at = String(prev.started_at ?? stats.started_at);
    }
    if (!acct.token_secret_id) { stats.error = 'Outlook is not connected.'; return; }
    const kinds: string[] = Array.isArray(acct.doc_kinds) && acct.doc_kinds.length ? acct.doc_kinds : [...ALL_DOC_KINDS];
    if (trigger !== 'continued') {
      await fetchPhase(sb, acct, stats, kinds, fromMs, only);
      // the mail is read: the morning is done for the 9 o'clock job and the admin's warning (0160) — not by a
      // past-e-mails pull, which reads old mail only (v1.13: one at 8:00 must not stand in for the 9 o'clock pull)
      if (!fromMs) await sb.from('kount_ot_mail_account').update({ last_fetch_at: nowIso() }).eq('id', 1);
    }
    // what waited may match now (an order saved since); then read what is new; then Paid from R365
    await redecidePending(sb, stats, startedMs + READ_BUDGET_MS);
    await readPhase(sb, stats, startedMs + READ_BUDGET_MS, kinds);
    await r365PaidPhase(sb, stats);
    // v1.30 (0179): stock asked out of E&E's storage by e-mail, before E&E's invoices for those trips link to it
    const relToken = await mailAccessToken(sb).catch(e => { stats.releases_error = msg(e).slice(0, 300); return null; });
    if (relToken) await releasePhase(sb, stats, relToken);
    await storagePhase(sb, stats, 'morning mail pull');
    await otherPhase(sb, stats);
    await sentPhase(sb, stats);
    await approvalPhase(sb, stats);
    const { count } = await sb.from('kount_ot_inbox').select('id', { count: 'exact', head: true }).eq('state', 'unread').lt('attempts', MAX_ATTEMPTS);
    stats.remaining = count ?? 0;
    chain = (count ?? 0) > 0 && depth < MAX_CHAIN;
    // invoices e-mailed to accounting (0174): once this pull's invoices are filed — the last call of a chained pull
    if (!chain) await accountingPhase(sb, stats, startedMs);
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
      // the public anon key too: the gateway lets the call through even if verify_jwt is ever switched on (0160)
      method: 'POST', headers: { 'Content-Type': 'application/json', 'x-kount-cron': String(secret ?? ''), ...(SUPABASE_ANON_KEY ? { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } : {}) },
      body: JSON.stringify({ action: 'continue', depth: depth + 1 }),
    }).catch(e => console.error('[kount-order-mail] could not continue:', msg(e)));
  }
}

interface Account { vendor_domains: string[] | null; doc_kinds?: string[] | null; suggested_domains: Record<string, number> | null; fetched_through: string | null }
interface GraphMessage { id: string; subject?: string; receivedDateTime: string; conversationId?: string; internetMessageId?: string; hasAttachments?: boolean; bodyPreview?: string; from?: { emailAddress?: { address?: string; name?: string } } }

async function fetchPhase(sb: SupabaseClient, acct: Account, stats: Stats, kinds: string[], fromMs = 0, only: string | null = null) {
  const { data: refresh, error } = await sb.rpc('kount_ot_mail_token_get');
  if (error) throw error;
  if (!refresh) throw new Error('Outlook is not connected.');
  const tok = await refreshAccess(String(refresh));
  if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
  if (fromMs) {
    // past e-mails (v1.13): that vendor's (or every listed vendor's) mail since that day, by search — the morning
    // list is everyone's mail with attachments and stops at MAX_MESSAGES; the morning mark (fetched_through) stays
    const vendors = only ? [only] : (acct.vendor_domains ?? []);
    // a time limit (v1.14): the function is stopped after a few minutes; a cut-short pull says so and a second
    // pull from the same day reads the rest (what was taken is skipped)
    const until = Date.now() + BACKFILL_FETCH_MS;
    const done = await backfillPdfs(sb, tok.access_token, vendors, fromMs, stats, kinds, until);
    if (!done || Date.now() > until) {
      stats.error = `Pulled part of ${only ?? 'the vendors'}' e-mails (time limit). Pull again from the same day to read the rest — what it already took is skipped.`;
      return;
    }
    await trackingPhase(sb, tok.access_token, vendors, fromMs, stats);
    if (!only) await stubPhase(sb, tok.access_token, fromMs, stats);   // our own paystub e-mails: not one vendor's
    return;
  }

  const prevThrough = acct.fetched_through ? Date.parse(acct.fetched_through) : 0;
  const sinceMs = prevThrough ? prevThrough - OVERLAP_MS : Date.now() - FIRST_LOOKBACK_DAYS * 86_400_000;
  const since = new Date(sinceMs).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const domains = acct.vendor_domains ?? [];
  // a full re-scan (no mark) counts suggested senders from scratch, so repeated scans don't add up
  const suggested: Record<string, number> = prevThrough ? { ...(acct.suggested_domains ?? {}) } : {};
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
      for (const p of pdfs) if (wantsAttachment(kinds, m.subject, p.name)) await takePdf(sb, tok.access_token, m, p, stats);
    }
    url = page['@odata.nextLink'] ?? '';
  }
  await trackingPhase(sb, tok.access_token, domains, sinceMs, stats);
  await stubPhase(sb, tok.access_token, sinceMs, stats);
  await payRequestPhase(sb, tok.access_token, sinceMs, stats);
  const { error: upErr } = await sb.from('kount_ot_mail_account').update({
    fetched_through: newest ? new Date(newest).toISOString() : null, suggested_domains: suggested, updated_at: nowIso(),
  }).eq('id', 1);
  if (upErr) throw upErr;
}

/** The listed vendors' e-mails that mention `number` (Outlook search: subject, body and attachment text),
 *  any age: their PDFs go into the Inbox like the morning pull's (a PDF already taken is skipped). Returns the
 *  PDFs seen. Only listed vendor senders, as in the pull — a colleague's forward is not read. */
async function findPhase(sb: SupabaseClient, number: string, stats: Stats): Promise<{ seen: number; messages: GraphMessage[]; token: string }> {
  const { data: acct, error } = await sb.from('kount_ot_mail_account').select('vendor_domains, doc_kinds').eq('id', 1).single();
  if (error) throw error;
  const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
  if (tErr) throw tErr;
  if (!refresh) throw new Error('Outlook is not connected.');
  const tok = await refreshAccess(String(refresh));
  if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
  const domains: string[] = acct.vendor_domains ?? [];
  const kinds: string[] = Array.isArray(acct.doc_kinds) && acct.doc_kinds.length ? acct.doc_kinds : [...ALL_DOC_KINDS];
  const page = await graphGet<{ value?: GraphMessage[] }>(tok.access_token, `/me/messages?$search=${encodeURIComponent(`"${number.replace(/"/g, '')}"`)}`
    + '&$select=id,subject,from,receivedDateTime,conversationId,internetMessageId,hasAttachments&$top=25');
  let seen = 0;
  const messages: GraphMessage[] = [];
  for (const m of page.value ?? []) {
    stats.messages++;
    const domain = domainOf(m.from?.emailAddress?.address);
    if (!m.hasAttachments || !domain || !onList(domain, domains)) continue;
    messages.push(m);
    const atts = await graphGet<{ value?: GraphAttachment[] }>(tok.access_token,
      `/me/messages/${encodeURIComponent(m.id)}/attachments?$select=id,name,contentType,size,isInline`);
    for (const p of (atts.value ?? []).filter(isPdfAttachment)) {
      if (!wantsAttachment(kinds, m.subject, p.name)) continue;
      seen++;
      await takePdf(sb, tok.access_token, m, p, stats);
    }
  }
  return { seen, messages, token: tok.access_token };
}

/** The listed vendors' e-mails of the last 30 days: their non-PDF attachments (an Excel of tracking numbers,
 *  photos, a Word spec) go onto the order the e-mail belongs to — its thread, else an INV / quote # in it — as
 *  'other' documents (0142), and a spreadsheet's tracking numbers onto that order too. An e-mail whose order
 *  is not known yet is looked at again each morning while it is in the window. Never fails the pull. */
const OTHER_DAYS = 30;
/** A past-e-mails pull's PDFs (v1.13): each vendor's e-mails since fromMs (Outlook search), taken as the morning pull
 *  takes them — a PDF already in the Inbox (same e-mail + attachment, or the same file) is skipped. */
async function backfillPdfs(sb: SupabaseClient, accessToken: string, domains: string[], fromMs: number, stats: Stats, kinds: string[], until: number): Promise<boolean> {
  const sinceDay = new Date(fromMs).toISOString().slice(0, 10);
  for (const domain of domains) {
    let url = `/me/messages?$search=${encodeURIComponent(`"from:${domain} received>=${sinceDay}"`)}`
      + '&$select=id,subject,from,receivedDateTime,conversationId,internetMessageId,hasAttachments&$top=25';
    let pages = 0;
    while (url && pages++ < 40) {
      const page = await graphGet<{ value?: GraphMessage[]; '@odata.nextLink'?: string }>(accessToken, url);
      for (const m of page.value ?? []) {
        if (Date.now() > until) return false;
        if (!m.hasAttachments || !onList(domainOf(m.from?.emailAddress?.address), [domain])) continue;
        stats.messages++;
        const atts = await graphGet<{ value?: GraphAttachment[] }>(accessToken,
          `/me/messages/${encodeURIComponent(m.id)}/attachments?$select=id,name,contentType,size,isInline`);
        for (const a of (atts.value ?? []).filter(isPdfAttachment)) if (wantsAttachment(kinds, m.subject, a.name)) await takePdf(sb, accessToken, m, a, stats);
      }
      url = page['@odata.nextLink'] ?? '';
    }
  }
  return true;
}

async function otherPhase(sb: SupabaseClient, stats: Stats) {
  try {
    const { data: acct, error } = await sb.from('kount_ot_mail_account').select('vendor_domains').eq('id', 1).single();
    if (error) throw error;
    const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
    if (tErr) throw tErr;
    if (!refresh) return;
    const tok = await refreshAccess(String(refresh));
    if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
    const domains: string[] = acct.vendor_domains ?? [];
    const since = new Date(Date.now() - OTHER_DAYS * 86_400_000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    const messages: GraphMessage[] = [];
    let url = `/me/messages?$filter=receivedDateTime ge ${since} and hasAttachments eq true&$orderby=receivedDateTime asc`
      + '&$select=id,subject,from,receivedDateTime,conversationId,internetMessageId,bodyPreview&$top=50';
    while (url) {
      const page = await graphGet<{ value?: GraphMessage[]; '@odata.nextLink'?: string }>(tok.access_token, url);
      for (const m of page.value ?? []) { const d = domainOf(m.from?.emailAddress?.address); if (d && onList(d, domains)) messages.push(m); }
      url = page['@odata.nextLink'] ?? '';
    }
    await attachOthersOf(sb, tok.access_token, messages, stats);
  } catch (e) {
    stats.others_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] other attachments failed:', stats.others_error);
  }
}

async function attachOthersOf(sb: SupabaseClient, accessToken: string, messages: GraphMessage[], stats: Stats) {
  const data = await loadTracker(sb);
  const { data: had, error } = await sb.from('kount_ot_documents').select('source_message_id, file_name').eq('kind', 'other');
  if (error) throw error;
  const seen = new Set((had ?? []).map(d => `${d.source_message_id}|${d.file_name}`));
  for (const m of messages) {
    const atts = await graphGet<{ value?: GraphAttachment[] }>(accessToken,
      `/me/messages/${encodeURIComponent(m.id)}/attachments?$select=id,name,contentType,size,isInline`);
    const keep = (atts.value ?? []).filter(a => (!a['@odata.type'] || a['@odata.type'] === '#microsoft.graph.fileAttachment')
      && !isPdfAttachment(a) && keepOtherAttachment(a) && !seen.has(`${m.id}|${(a.name ?? 'attachment').slice(0, 200)}`));
    if (!keep.length) continue;
    const order = orderForEmail(m.conversationId ?? null, `${m.subject ?? ''} ${m.bodyPreview ?? ''} ${keep.map(a => a.name ?? '').join(' ')}`, data);
    if (!order) { stats.others_unplaced = (stats.others_unplaced ?? 0) + keep.length; continue; }
    for (const a of keep) {
      const name = (a.name ?? 'attachment').slice(0, 200);
      const full = await graphGet<{ contentBytes?: string }>(accessToken, `/me/messages/${encodeURIComponent(m.id)}/attachments/${encodeURIComponent(a.id)}`);
      const bytes = fromBase64(String(full.contentBytes ?? ''));
      if (!bytes.length) continue;
      const id = crypto.randomUUID();
      const path = `other/${id}.${(name.split('.').pop() ?? 'bin').toLowerCase().replace(/[^a-z0-9]/g, '')}`;
      const up = await sb.storage.from(BUCKET).upload(path, bytes, { contentType: keepOtherAttachment(a)!, upsert: false });
      if (up.error) throw up.error;
      const { error: dErr } = await sb.from('kount_ot_documents').insert({
        id, order_id: order.id, kind: 'other', doc_date: m.receivedDateTime.slice(0, 10), vendor_name: m.from?.emailAddress?.name ?? null,
        file_name: name, storage_path: path, source_message_id: m.id, source_conversation_id: m.conversationId ?? null,
        content_hash: await sha256Hex(bytes), uploaded_by: 'morning mail pull',
      });
      seen.add(`${m.id}|${name}`);
      if (dErr) {
        await sb.storage.from(BUCKET).remove([path]);
        if (dErr.code === '23505') continue;                       // the same file is on the order already
        throw dErr;
      }
      stats.others = (stats.others ?? 0) + 1;
      // a delivery-status sheet: each row moves its own line (Complete = delivered, in transit = shipped, its ETA)
      if (isSpreadsheet(name)) stats.tracking += (await applySheet(sb, { id, order_id: order.id, file_name: name, storage_path: path }, bytes)).tracking;
    }
  }
}

interface SheetDoc { id: string; order_id: string; file_name: string | null; storage_path: string }
/** One spreadsheet on an order: sheetUpdates matches each row to one of its lines; a line only moves forward,
 *  gets the row's tracking if it has none, and the row's ETA while not delivered. The carriers' numbers go on
 *  the order's tracking list (straight in — the RPC would copy the whole list onto every line). */
async function applySheet(sb: SupabaseClient, doc: SheetDoc, bytes?: Uint8Array) {
  if (!bytes) {
    const dl = await sb.storage.from(BUCKET).download(doc.storage_path);
    if (dl.error || !dl.data) throw dl.error ?? new Error('sheet missing from storage');
    bytes = new Uint8Array(await dl.data.arrayBuffer());
  }
  const wb = XLSX.read(bytes, { type: 'array' });
  const grid = wb.SheetNames.flatMap(n => XLSX.utils.sheet_to_json<unknown[]>(wb.Sheets[n], { header: 1, raw: false, defval: '' }));
  const { data: rows, error } = await sb.from('kount_ot_lines').select('*').eq('order_id', doc.order_id);
  if (error) throw error;
  const lines = ((rows ?? []) as OtLine[]).map(l => ({ ...l, qty: Number(l.qty) || 0 }));
  const read = sheetUpdates(grid, lines, doc.file_name ?? 'sheet');
  let updated = 0;
  for (const u of read.updates) {
    const l = lines.find(x => x.id === u.lineId)!;
    const patch: Record<string, unknown> = {};
    if (u.status && l.status !== 'CANCELLED' && l.status !== 'RECEIVED' && statusRank(u.status) > statusRank(l.status)) {
      patch.status = u.status; patch.status_source = 'document'; patch.status_note = u.note;
    }
    if (u.tracking && !l.tracking_number) patch.tracking_number = u.tracking;
    if (u.eta && l.expected_on !== u.eta && statusRank((patch.status as typeof l.status) ?? l.status) < statusRank('DELIVERED')) patch.expected_on = u.eta;
    if (!Object.keys(patch).length) continue;
    const { error: uErr } = await sb.from('kount_ot_lines').update(patch).eq('id', l.id);
    if (uErr) throw uErr;
    updated++;
  }
  let tracking = 0;
  if (read.tracking.length) {
    const { data: got, error: tErr } = await sb.from('kount_ot_tracking').upsert(read.tracking.map(h => ({
      order_id: doc.order_id, tracking_number: h.number.toUpperCase(), carrier: h.carrier, source: 'email', note: `Tracking from ${doc.file_name ?? 'a sheet'}`.slice(0, 200),
    })), { onConflict: 'order_id,tracking_number', ignoreDuplicates: true }).select('id');
    if (tErr) throw tErr;
    tracking = got?.length ?? 0;
  }
  return { rows: read.rows, matched: read.matched, updated, tracking };
}

interface BodyMessage extends GraphMessage { uniqueBody?: { content?: string } }

/** Tracking numbers written in the vendors' email text (with or without attachments): each email with
 *  any becomes an inbox row (attachment 'body'); onto its order at once when the thread / an invoice #
 *  says which, else it waits for a person to pick the order. uniqueBody = only what that email added,
 *  not the quoted history below it, so an old number in a reply chain is not taken again. */
async function trackingPhase(sb: SupabaseClient, accessToken: string, domains: string[], sinceMs: number, stats: Stats) {
  const sinceDay = new Date(sinceMs).toISOString().slice(0, 10);
  let data = await loadTracker(sb);
  // the vendor's latest e-mail per order (0153): a reply ("production finishes this week") is an update, so no follow-up
  const lastMail = new Map<string, string>();
  for (const domain of domains) {
    const search = encodeURIComponent(`"from:${domain} received>=${sinceDay}"`);
    let url = `/me/messages?$search=${search}&$select=id,subject,from,receivedDateTime,conversationId,internetMessageId,uniqueBody&$top=25`;
    let pages = 0;
    while (url && pages++ < 20) {
      const page = await graphGet<{ value?: BodyMessage[]; '@odata.nextLink'?: string }>(accessToken, url, { textBody: true });
      for (const m of page.value ?? []) {
        if (!onList(domainOf(m.from?.emailAddress?.address), [domain])) continue;
        const text = `${m.subject ?? ''}\n${m.uniqueBody?.content ?? ''}`;
        const about = orderForEmail(m.conversationId ?? null, text, data);
        if (about && m.receivedDateTime > (lastMail.get(about.id) ?? '')) lastMail.set(about.id, m.receivedDateTime);
        const hits = extractTracking(text);
        if (!hits.length) continue;
        const { data: seen } = await sb.from('kount_ot_inbox').select('id').eq('message_id', m.id).eq('attachment_id', 'body').maybeSingle();
        if (seen) continue;
        const id = crypto.randomUUID();
        const order = orderForEmail(m.conversationId ?? null, text, data);
        const { error } = await sb.from('kount_ot_inbox').insert({
          id, message_id: m.id, attachment_id: 'body', internet_message_id: m.internetMessageId ?? null, conversation_id: m.conversationId ?? null,
          subject: (m.subject ?? '').slice(0, 300), sender_email: m.from?.emailAddress?.address ?? null, sender_name: m.from?.emailAddress?.name ?? null,
          received_at: m.receivedDateTime, file_name: null, content_hash: `body:${m.id}`, storage_path: '',
          state: 'pending', parsed: { tracking: hits, excerpt: text.slice(0, 1500) },
          decision: order ? null : 'Tracking number in the email, but which order is not clear — pick it.', order_id: null,
        });
        if (error) { if (error.code === '23505') continue; throw error; }
        if (order && await applyTracking(sb, id, order, hits, m.subject ?? '', m.id, m.conversationId ?? null, isRecent(m.receivedDateTime))) {
          stats.tracking++; data = await loadTracker(sb);
        } else stats.pending++;
      }
      url = page['@odata.nextLink'] ?? '';
    }
  }
  for (const [orderId, at] of lastMail) {
    await sb.from('kount_ot_orders').update({ last_vendor_email_at: at }).eq('id', orderId).or(`last_vendor_email_at.is.null,last_vendor_email_at.lt.${at}`);
  }
}

/** The team's payment requests to AP, and AP's "RE:Payment Request ... 'Query No=...'" replies (0153): their invoices'
 *  lines get pay_requested_at (the first one) and AP's query number, so To send does not ask again. It always looks
 *  back PAY_LOOKBACK_DAYS, so requests sent before this step existed (or by someone else, with us on copy) are found;
 *  a batch naming no invoice in its subject is read from its body. Never fails the pull. */
const PAY_LOOKBACK_DAYS = 90;
async function payRequestPhase(sb: SupabaseClient, accessToken: string, sinceMs: number, stats: Stats) {
  try {
    const fromMs = Math.min(sinceMs || Date.now(), Date.now() - PAY_LOOKBACK_DAYS * 86_400_000);
    const sinceDay = new Date(fromMs).toISOString().slice(0, 10);
    const found = new Map<string, { at: string; queryNo: string | null }>();
    let url = `/me/messages?$search=${encodeURIComponent(`"payment request received>=${sinceDay}"`)}&$select=id,subject,from,receivedDateTime,uniqueBody&$top=25`;
    let pages = 0;
    while (url && pages++ < 30) {
      const page = await graphGet<{ value?: BodyMessage[]; '@odata.nextLink'?: string }>(accessToken, url, { textBody: true });
      for (const m of page.value ?? []) {
        const addr = m.from?.emailAddress?.address;
        if (!isOwnSender(addr, OWN_DOMAINS) && !onList(domainOf(addr), ['iqbackoffice.com'])) continue;
        const pr = paymentRequestOf(m.subject, m.uniqueBody?.content);
        if (!pr) continue;
        for (const inv of pr.invoices) {
          const had = found.get(inv);
          found.set(inv, { at: had && had.at < m.receivedDateTime ? had.at : m.receivedDateTime, queryNo: had?.queryNo ?? pr.queryNo });
        }
      }
      url = page['@odata.nextLink'] ?? '';
    }
    if (!found.size) return;
    const { data: lines, error } = await sb.from('kount_ot_lines').select('id, invoice_number, pay_requested_at, ap_query_no').in('invoice_number', [...found.keys()]);
    if (error) throw error;
    for (const l of lines ?? []) {
      const f = found.get(String(l.invoice_number).toUpperCase());
      if (!f) continue;
      const at = l.pay_requested_at && l.pay_requested_at < f.at ? l.pay_requested_at : f.at;
      const q = l.ap_query_no ?? f.queryNo;
      if (at === l.pay_requested_at && q === l.ap_query_no) continue;
      const { error: uErr } = await sb.from('kount_ot_lines').update({ pay_requested_at: at, ap_query_no: q }).eq('id', l.id);
      if (uErr) throw uErr;
      stats.pay_requests = (stats.pay_requests ?? 0) + 1;
    }
  } catch (e) {
    stats.pay_requests_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] payment requests failed:', stats.pay_requests_error);
  }
}

/** Invoices sent to accounting (0174). The user, 11/16: "scan if those invoices are being sent to accounting.
 *  hwoodap@iqbackoffice.com and hwoodga@iqbackoffice.com". Each tracked invoice not paid yet is searched in Outlook
 *  by its number - once as words (from, subject, body) and once in attachments (attachment:) - until it is found
 *  sent and, if a vendor sent it, until one of ours is found too. An e-mail counts when it went (to / cc / bcc, not a
 *  draft) to AP or GA and names the invoice (acctMailVerdict) - ours, a colleague's, or the vendor's own with us on
 *  copy. Its lines get the first such e-mail and every mailbox they went to; the first one of ours is also the
 *  payment request (pay_requested_at), in the same update (0174 keeps updated_at for both). A line added later
 *  copies the stamp. The work is the open invoices, not the mail: in number order from where the last pull stopped
 *  (acct_cursor), within a time limit from the run's start; one invoice failing skips only it. Never fails the pull. */
const ACCT_BUDGET_MS = 45_000;
const ACCT_RUN_LIMIT_MS = 240_000;     // and not past 4 minutes into the run
const ACCT_PAGES = 4;                   // 100 e-mails per search
interface AcctGraphMessage extends GraphMessage {
  isDraft?: boolean;
  body?: { content?: string };
  toRecipients?: Array<{ emailAddress?: { address?: string } }>;
  ccRecipients?: Array<{ emailAddress?: { address?: string } }>;
  bccRecipients?: Array<{ emailAddress?: { address?: string } }>;
}
/** onlyOrder (v1.21 "check now"): just that order's invoices, the pulls' place in the list left alone. */
async function accountingPhase(sb: SupabaseClient, stats: Stats, startedMs: number, onlyOrder: string | null = null) {
  const until = Math.min(Date.now() + ACCT_BUDGET_MS, startedMs + ACCT_RUN_LIMIT_MS);
  if (until - Date.now() < 10_000) { stats.acct_error = 'Not checked: the pull ran long. The next pull checks.'; return; }
  let failed = 0, lastErr = '';
  const fail = (e: unknown) => { failed++; lastErr = msg(e).slice(0, 160); };
  try {
    const data = await loadTracker(sb);
    const orders = new Map(data.orders.filter(o => !o.archived_at).map(o => [o.id, o]));
    const byTok = new Map<string, OtLine[]>();
    for (const l of data.lines) {
      if (!l.invoice_number || l.status === 'CANCELLED' || !orders.has(l.order_id)) continue;
      const t = invoiceToken(l.invoice_number);
      if (!trackableInvoice(t)) continue;                                         // "TBD", "INV 46284": not searchable
      (byTok.get(t) ?? byTok.set(t, []).get(t)!).push(l);
    }
    const todo: Array<{ tok: string; ls: OtLine[]; vendor: string; stamped: boolean }> = [];
    for (const [tok, ls] of byTok) {
      if (onlyOrder && !ls.some(l => l.order_id === onlyOrder)) continue;
      if (ls.some(l => statusRank(l.status) >= statusRank('PAID'))) continue;      // paid: accounting had it
      const found = ls.find(l => l.acct_sent_at);
      if (found) {
        // a line added after the invoice was found gets the same stamp
        const missing = ls.filter(l => !l.acct_sent_at).map(l => l.id);
        if (missing.length) {
          const { error } = await sb.from('kount_ot_lines').update({ acct_sent_at: found.acct_sent_at, acct_sent_to: found.acct_sent_to,
            acct_sent_by: found.acct_sent_by, acct_sent_subject: found.acct_sent_subject, acct_message_id: found.acct_message_id }).in('id', missing);
          if (error) fail(error); else stats.acct_sent = (stats.acct_sent ?? 0) + missing.length;
        }
        // found, and our own payment request too: done
        if (ls.every(l => l.pay_requested_at)) continue;
      }
      todo.push({ tok, ls, vendor: orders.get(ls[0].order_id)!.vendor_name, stamped: !!found });
    }
    if (!todo.length) { if (failed) stats.acct_error = `${failed} could not be updated (${lastErr})`; return; }
    const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
    if (tErr) throw tErr;
    if (!refresh) return;
    const tok = await refreshAccess(String(refresh));
    if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
    // in number order, from just after the last one the previous pull checked, so a list too long for one pull is
    // gone through in turn
    const { data: acctRow } = onlyOrder ? { data: null } : await sb.from('kount_ot_mail_account').select('acct_cursor').eq('id', 1).maybeSingle();
    const cursor = String((acctRow as { acct_cursor?: string | null } | null)?.acct_cursor ?? '');
    todo.sort((a, b) => a.tok.localeCompare(b.tok));
    const after = todo.findIndex(t => t.tok.localeCompare(cursor) > 0);
    const order = after > 0 ? [...todo.slice(after), ...todo.slice(0, after)] : todo;
    let checked = 0, lastTok = '';
    for (const t of order) {
      if (Date.now() > until) break;
      checked++;
      lastTok = t.tok;
      try {
        const hits: AcctMail[] = [];
        const seen = new Set<string>();
        const q = t.tok.replace(/"/g, '');
        // as words (Outlook's default: from, subject, body), then in attachments (names and text)
        for (const term of [q, `attachment:${q}`]) {
          try {
          let url = `/me/messages?$search=${encodeURIComponent(`"${term}"`)}`
            + '&$select=id,subject,from,toRecipients,ccRecipients,bccRecipients,receivedDateTime,hasAttachments,isDraft,body&$top=25';
          let pages = 0;
          while (url && pages++ < ACCT_PAGES) {
            const page = await graphGet<{ value?: AcctGraphMessage[]; '@odata.nextLink'?: string }>(tok.access_token, url, { textBody: true });
            for (const m of page.value ?? []) {
              if (seen.has(m.id)) continue;
              seen.add(m.id);
              const mail: AcctMail = {
                id: m.id, receivedDateTime: m.receivedDateTime, subject: m.subject ?? null, body: m.body?.content ?? null, hasAttachments: m.hasAttachments,
                isDraft: m.isDraft, from: m.from?.emailAddress?.address ?? null, fromName: m.from?.emailAddress?.name ?? null,
                recipients: [...(m.toRecipients ?? []), ...(m.ccRecipients ?? []), ...(m.bccRecipients ?? [])].map(r => r.emailAddress?.address),
              };
              let v = acctMailVerdict(t.tok, t.vendor, mail);
              if (v === 'attachments') {
                const atts = await graphGet<{ value?: GraphAttachment[] }>(tok.access_token, `/me/messages/${encodeURIComponent(m.id)}/attachments?$select=id,name`);
                v = acctMailVerdict(t.tok, t.vendor, mail, (atts.value ?? []).map(a => a.name ?? ''));
              }
              if (v === 'yes') hits.push(mail);
            }
            url = page['@odata.nextLink'] ?? '';
          }
          } catch (e) {
            // the attachment search failing keeps what the plain one found (counted as a failure)
            if (term === q) throw e;
            fail(e);
          }
        }
        const hit = firstAccountingMail(hits, OWN_DOMAINS);
        if (!hit) continue;
        const ownAt = hit.ownAt;
        // our own e-mail to AP / GA with the invoice is its payment request (the earliest one is kept)
        const requested = ownAt ? t.ls.filter(l => !l.pay_requested_at || Date.parse(ownAt) < Date.parse(l.pay_requested_at)).map(l => l.id) : [];
        const stamp = t.stamped ? {} : { acct_sent_at: hit.at, acct_sent_to: hit.to, acct_sent_by: hit.by, acct_sent_subject: hit.subject, acct_message_id: hit.messageId };
        const rest = t.ls.map(l => l.id).filter(id => !requested.includes(id));
        if (requested.length) {
          const { error } = await sb.from('kount_ot_lines').update({ ...stamp, pay_requested_at: ownAt }).in('id', requested);
          if (error) throw error;
          stats.acct_requested = (stats.acct_requested ?? 0) + requested.length;
        }
        if (!t.stamped && rest.length) {
          const { error } = await sb.from('kount_ot_lines').update(stamp).in('id', rest);
          if (error) throw error;
        }
        if (!t.stamped) stats.acct_sent = (stats.acct_sent ?? 0) + t.ls.length;
      } catch (e) {
        fail(e);
      }
    }
    if (lastTok && !onlyOrder) await sb.from('kount_ot_mail_account').update({ acct_cursor: checked < order.length ? lastTok : null }).eq('id', 1);
    stats.acct_checked = (stats.acct_checked ?? 0) + checked;
    const notes = [checked < order.length && `checked ${checked} of ${order.length} unpaid invoices (time limit); the next pull goes on from there`,
      failed && `${failed} could not be searched or updated (${lastErr})`].filter(Boolean);
    if (notes.length) stats.acct_error = notes.join('; ');
  } catch (e) {
    stats.acct_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] accounting failed:', stats.acct_error);
  }
}

/** shipLines = move the order's unshipped lines to Shipped (only for recent mail — see RECENT_DAYS). */
async function applyTracking(sb: SupabaseClient, inboxId: string, order: OtOrder, hits: TrackingHit[], subject: string, messageId: string, conversationId: string | null, shipLines = true) {
  const { error } = await sb.rpc('kount_ot_add_tracking', { p: {
    order_id: order.id, numbers: hits, inbox_id: inboxId, source: 'email', message_id: messageId, conversation_id: conversationId,
    note: `Tracking from email: ${subject}`.slice(0, 200), ship_lines: shipLines,
    decision: `Tracking ${hits.map(h => h.number).join(', ')} added to ${order.order_number || `the ${order.vendor_name} order`}.`,
  } });
  if (error) {
    await sb.from('kount_ot_inbox').update({ decision: `Could not add the tracking automatically (${error.message}).`.slice(0, 1000) }).eq('id', inboxId);
    return false;
  }
  return true;
}

/** h.wood's own "Please find the attached paystub for INV-…" emails: the stub file goes onto every order
 *  holding one of those invoices (a 'payment' document). Stubs for invoices not tracked yet wait (redecide).
 *  11/16: also "This was paid. PFA the proof of payment." with "Check Stub Reprint (22).pdf" - found by "check stub",
 *  "proof of payment" and an attachment named "...stub..." (attachment:stub; a plain search is from / subject / body
 *  only), its invoice taken from the thread when its own words name none (stubThreadInvoices). Every pull looks back
 *  STUB_LOOKBACK_DAYS; an e-mail whose stub is already in the Inbox is passed over. */
const STUB_LOOKBACK_DAYS = 30;
// 11/17 the user: "I had paid for this using the credit card and also shared the proof of payments as screenshots. those
// were not pulled in" ("The payments have been processed, PFA the proofs below", screenshots pasted in the e-mail)
const STUB_TERMS = ['paystub', 'pay stub', 'payment stub', 'check stub', 'remittance', 'proof of payment', 'attachment:stub', 'paid', 'payments processed', 'payment processed'];
// each candidate file is read by the reader (v1.21): at most this many per pull, within this time; the rest next pull
const STUB_READS_MAX = 10;
const STUB_BUDGET_MS = 75_000;
async function stubPhase(sb: SupabaseClient, accessToken: string, sinceMs: number, stats: Stats, lookbackDays = STUB_LOOKBACK_DAYS) {
  const sinceDay = new Date(Math.min(sinceMs || Date.now(), Date.now() - lookbackDays * 86_400_000)).toISOString().slice(0, 10);
  const until = Date.now() + STUB_BUDGET_MS;
  let data = await loadTracker(sb);
  const seenMsg = new Set<string>();
  let reads = 0, cut = false;
  for (const term of STUB_TERMS) {
    if (cut) break;
    let url = `/me/messages?$search=${encodeURIComponent(`"${term} received>=${sinceDay}"`)}`
      + '&$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,conversationId,internetMessageId,hasAttachments,uniqueBody,body&$top=25';
    let pages = 0;
    while (url && pages++ < 10 && !cut) {
      const page = await graphGet<{ value?: (BodyMessage & { hasAttachments?: boolean; body?: { content?: string } })[]; '@odata.nextLink'?: string }>(accessToken, url, { textBody: true });
      for (const m of page.value ?? []) {
        if (seenMsg.has(m.id) || !isOwnSender(m.from?.emailAddress?.address, OWN_DOMAINS)) continue;
        seenMsg.add(m.id);
        const own = String(m.uniqueBody?.content ?? '');
        const paidSaid = saysPaid(own);
        // E&E's INV-2026-… numbers, and (v1.14) any invoice number a tracked order carries ("I051027", "INV-46284")
        const ownRefs = [...new Set([...stubInvoices(own), ...trackedInvoicesIn(own, data)])];
        // screenshots pasted in the e-mail do not count as attachments (hasAttachments false): read on when it says paid
        if (!m.hasAttachments && !paidSaid) continue;
        // v1.14: sent to a vendor (anyone outside h.wood), or only passed around inside — then it is on file, not sent
        const rcpts = [...((m as { toRecipients?: Array<{ emailAddress?: { address?: string } }> }).toRecipients ?? []),
          ...((m as { ccRecipients?: Array<{ emailAddress?: { address?: string } }> }).ccRecipients ?? [])];
        // a payment request to AP / GA (the invoice attached) is not a stub
        if (accountingBoxes(rcpts.map(r => r.emailAddress?.address)).length || /^\s*(?:(?:re|fw|fwd):\s*)*payment request/i.test(m.subject ?? '')) continue;
        const toVendor = rcpts.some(r => { const a = r.emailAddress?.address ?? ''; return a.includes('@') && !isOwnSender(a, OWN_DOMAINS); });
        // filed already (a look-back pull meets it again): nothing to fetch
        const { data: filed } = await sb.from('kount_ot_inbox').select('id').eq('message_id', m.id).limit(1);
        if (filed?.length) continue;
        // the limit is checked between e-mails, never inside one: an e-mail with a row is not looked at again, so all of
        // its files are read in the same pull
        if (reads >= STUB_READS_MAX || Date.now() > until) { cut = true; break; }
        const atts = await graphGet<{ value?: GraphAttachment[] }>(accessToken, `/me/messages/${encodeURIComponent(m.id)}/attachments?$select=id,name,contentType,size,isInline`);
        const files = (atts.value ?? []).filter(a => isStubAttachment(a) && !isInvoiceFile(a.name));
        if (!files.length) continue;
        // only an e-mail about a payment is read: it says paid, names an invoice, or a file is named for one
        if (!paidSaid && !ownRefs.length && !files.some(a => /stub|remit|receipt|payment|paid/i.test(a.name ?? ''))) continue;
        for (const a of files) {
          const type = isStubAttachment(a);
          if (!type) continue;
          const { data: seen } = await sb.from('kount_ot_inbox').select('id').eq('message_id', m.id).eq('attachment_id', a.id).maybeSingle();
          if (seen) continue;
          const full = await graphGet<{ contentBytes?: string }>(accessToken, `/me/messages/${encodeURIComponent(m.id)}/attachments/${encodeURIComponent(a.id)}`);
          if (!full.contentBytes) continue;
          const bytes = fromBase64(full.contentBytes);
          const hash = `stub:${await sha256Hex(bytes)}`;
          const { data: dup } = await sb.from('kount_ot_inbox').select('id, storage_path').eq('content_hash', hash).maybeSingle();
          if (dup) {
            // the same stub again (0175): filed from an e-mail inside h.wood, now sent on to the vendor -> it counts as sent
            if (toVendor && dup.storage_path) {
              const n = await markStubSent(sb, String(dup.storage_path), m.id);
              if (n) { stats.stubs_sent = (stats.stubs_sent ?? 0) + n; data = await loadTracker(sb); }
            }
            continue;
          }
          // v1.21 the reader: what this file proves - the invoices and amounts printed on it ("Payment Received!
          // ... INV-2026-581270 ... $547.90"), or that it is no payment proof at all (a logo, a design proof)
          let proof: ProofRead | null = null;
          try {
            reads++;
            proof = (await readPurchaseFile({ data: full.contentBytes, mediaType: type, fileName: a.name ?? 'proof', flow: 'kount-order-mail-proof', metadata: { message_id: m.id } })).document as ProofRead;
            stats.proofs_read = (stats.proofs_read ?? 0) + 1;
          } catch (e) {
            console.error('[kount-order-mail] payment proof not read:', msg(e));   // filed from the e-mail's words below, never marked paid
          }
          const id = crypto.randomUUID();
          const ext = type === 'application/pdf' ? 'pdf' : type === 'image/png' ? 'png' : 'jpg';
          const path = `docs/${id}.${ext}`;
          const base = {
            id, message_id: m.id, attachment_id: a.id, internet_message_id: m.internetMessageId ?? null, conversation_id: m.conversationId ?? null,
            subject: (m.subject ?? '').slice(0, 300), sender_email: m.from?.emailAddress?.address ?? null, sender_name: m.from?.emailAddress?.name ?? null,
            received_at: m.receivedDateTime, file_name: (a.name ?? `paystub.${ext}`).slice(0, 200), size_bytes: a.size ?? bytes.length,
            content_hash: hash, storage_path: path, model: proof ? 'claude-opus-5-5' : null,
          };
          const up = await sb.storage.from(BUCKET).upload(path, bytes, { contentType: type, upsert: true });
          if (up.error) throw up.error;
          if (proof && !proof.payment_proof) {
            // read and not a payment: kept as passed over, so it is not read again
            const { error } = await sb.from('kount_ot_inbox').insert({ ...base, state: 'ignored', parsed: { kind: 'other', read: proof },
              decision: 'Not a payment proof (read by the tracker).', decided_by: 'morning mail pull' });
            if (error && error.code !== '23505') throw error;
            continue;
          }
          const matches = proofMatches(proof, data);
          // the invoices: those the proof prints that are tracked, else those it prints (they wait for their order), else
          // the e-mail's own numbers, else (it says paid) its thread's PAID invoices - a guess files, it never marks paid
          let invoices = matches.map(x => x.token);
          if (!invoices.length) invoices = proofPrinted(proof);
          if (!invoices.length) invoices = ownRefs;
          if (!invoices.length && paidSaid) invoices = stubThreadInvoices(m.conversationId ?? null, m.body?.content ?? null, data);
          if (!invoices.length) {
            if (!proof) { await sb.storage.from(BUCKET).remove([path]); continue; }       // not read: tried again next pull
            // read, a payment, but no invoice to put it on: kept as passed over (0175: the hourly check must not re-read it)
            const { error } = await sb.from('kount_ot_inbox').insert({ ...base, state: 'ignored', parsed: { kind: 'payment', invoices: [], to_vendor: toVendor, read: proof },
              decision: 'A payment proof naming no invoice the tracker knows (read by the tracker).', decided_by: 'morning mail pull' });
            if (error && error.code !== '23505') throw error;
            continue;
          }
          const row = { ...base, state: 'pending', parsed: { kind: 'payment', invoices, to_vendor: toVendor, ...(proof ? { read: proof } : {}) },
            decision: `${proof?.payment_proof ? 'Payment proof' : 'Check stub'} for ${invoices.join(', ')}.` };
          const { error } = await sb.from('kount_ot_inbox').insert(row);
          if (error) { await sb.storage.from(BUCKET).remove([path]); if (error.code === '23505') continue; throw error; }
          if (await attachStub(sb, row, data)) { stats.stubs++; data = await loadTracker(sb); }
          // the invoices the proof itself shows paid in full -> Paid (a card / online payment R365 never sees)
          const n = await markPaidFromProof(sb, matches, proof, 'ours', m.receivedDateTime, data);
          if (n) { stats.paid_by_proof = (stats.paid_by_proof ?? 0) + n; data = await loadTracker(sb); }
        }
        if (cut) break;
      }
      url = page['@odata.nextLink'] ?? '';
    }
  }
  if (cut) stats.stub_note = `Read ${reads} payment proof file${reads === 1 ? '' : 's'} (the limit for one pull); the next pull reads the rest.`;
}

/** The invoice lines a payment proof shows paid IN FULL (proofMatches: printed on it, amount = the invoice's total) and
 *  not yet past Invoiced, with no R365 payment -> Paid, the note saying which proof. A part payment or one with no amount
 *  is left alone (the proof is still filed). Returns the lines marked. */
async function markPaidFromProof(sb: SupabaseClient, matches: ProofMatch[], proof: ProofRead | null, whose: 'ours' | 'vendor', at: string,
                                 data: { lines: OtLine[]; orders: OtOrder[] }): Promise<number> {
  const full = matches.filter(x => x.full);
  if (!full.length) return 0;
  const live = new Set(data.orders.filter(o => !o.archived_at).map(o => o.id));
  const day = new Date(at).toLocaleDateString('en-US', { timeZone: 'America/Los_Angeles', month: 'numeric', day: 'numeric' });
  let n = 0;
  for (const f of full) {
    const ids = data.lines.filter(l => live.has(l.order_id) && BEFORE_PAID.includes(l.status) && !!l.invoice_number && invoiceToken(l.invoice_number) === f.token
      && !(l.r365_payments?.length)).map(l => l.id);
    if (!ids.length) continue;
    const ref = proof?.payment_reference ? ` ${proof.payment_reference}` : '';
    const { error } = await sb.from('kount_ot_lines').update({ status: 'PAID', status_source: 'document',
      status_note: `Paid ${fmtMoney(f.amount)}: ${whose === 'vendor' ? "the vendor's payment receipt" : 'our payment proof'}${ref} of ${day}`.slice(0, 300) }).in('id', ids);
    if (error) throw error;
    n += ids.length;
  }
  return n;
}

/** The stub documents filed from this file (its storage path) that went only to people inside h.wood (to_vendor false):
 *  sent to the vendor now, by e-mail `messageId` -> to_vendor true, so "Stubs to send" lets them go. Returns how many. */
async function markStubSent(sb: SupabaseClient, storagePath: string, messageId: string): Promise<number> {
  const { data: docs, error } = await sb.from('kount_ot_documents').select('id, parsed').eq('kind', 'payment').eq('storage_path', storagePath);
  if (error) throw error;
  let n = 0;
  for (const d of (docs ?? []) as Array<{ id: string; parsed: Record<string, unknown> | null }>) {
    if (d.parsed?.to_vendor !== false) continue;
    const { error: upErr } = await sb.from('kount_ot_documents').update({ parsed: { ...d.parsed, to_vendor: true, sent_message_id: messageId } }).eq('id', d.id);
    if (upErr) throw upErr;
    n++;
  }
  return n;
}

/** 0175: the stubs checked again during the day. Our own e-mails of the last STUB_CHECK_DAYS days, the stub step alone
 *  (no vendor PDFs, R365, accounting): a stub sent to the vendor at 2 pm leaves "Stubs to send" by 2:30. The morning's
 *  last_run stays; this check is kept in it as stub_check. Runs under the pull lock (kount_ot_mail_begin_run). */
const STUB_CHECK_DAYS = 2;
async function runStubCheck(sb: SupabaseClient) {
  const startedAt = nowIso();
  const stats = blankStats('stub check');
  try {
    const { data: refresh, error } = await sb.rpc('kount_ot_mail_token_get');
    if (error) throw error;
    if (!refresh) throw new Error('Outlook is not connected.');
    const tok = await refreshAccess(String(refresh));
    if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
    await stubPhase(sb, tok.access_token, 0, stats, STUB_CHECK_DAYS);
    // 0178: each open order's latest e-mail, for "Follow up" - hourly, so a reply clears the flag the same day
    await threadPhase(sb, stats, tok.access_token);
    // 0179: releases asked by e-mail during the day, then E&E's invoices that arrived since
    await releasePhase(sb, stats, tok.access_token);
    await storagePhase(sb, stats, 'hourly check');
  } catch (e) {
    stats.error = msg(e);
    stats.reconnect = e instanceof GraphError && e.reauth;
    console.error('[kount-order-mail] stub check failed:', stats.error);
  } finally {
    const check = { started_at: startedAt, finished_at: nowIso(), stubs: stats.stubs, stubs_sent: stats.stubs_sent ?? 0, proofs_read: stats.proofs_read ?? 0,
      paid_by_proof: stats.paid_by_proof ?? 0, note: stats.stub_note ?? null, error: stats.error, reconnect: stats.reconnect,
      threads_checked: stats.threads_checked ?? 0, threads_moved: stats.threads_moved ?? 0, threads_note: stats.threads_note ?? null, threads_error: stats.threads_error ?? null,
      releases_seen: stats.releases_seen ?? 0, releases_read: stats.releases_read ?? 0, releases_recorded: stats.releases_recorded ?? 0,
      releases_review: stats.releases_review ?? 0, releases_note: stats.releases_note ?? null, releases_error: stats.releases_error ?? null,
      storage: stats.storage ?? 0, storage_linked: stats.storage_linked ?? 0, storage_error: stats.storage_error ?? null };
    const { data: a } = await sb.from('kount_ot_mail_account').select('last_run').eq('id', 1).single();
    const prev = (a?.last_run ?? null) as Record<string, unknown> | null;
    await sb.from('kount_ot_mail_account').update({ running_since: null, last_run: prev ? { ...prev, stub_check: check } : { ...stats, finished_at: nowIso(), stub_check: check },
      updated_at: nowIso() }).eq('id', 1);
  }
}

/** A vendor's own payment receipt (Everything Promo's "i051027 - Payment Receipt", 11/04, read as 'other' and passed
 *  over until v1.21): filed on the orders of the invoices it pays, which are marked Paid when it pays them in full. */
async function applyVendorReceipt(sb: SupabaseClient, row: { id: string; message_id: string; conversation_id: string | null; file_name: string | null; storage_path: string; received_at?: string | null },
                                  proof: ProofRead, data: { orders: OtOrder[]; lines: OtLine[]; documents: OtDocument[] }, stats: Stats): Promise<{ state: string; decision: string }> {
  const matches = proofMatches(proof, data);
  const invoices = matches.length ? matches.map(x => x.token) : proofPrinted(proof);
  if (!invoices.length) return { state: 'ignored', decision: 'A payment receipt naming no invoice.' };
  const filed = await attachStub(sb, { ...row, parsed: { kind: 'payment', invoices, to_vendor: true } }, data);
  const n = await markPaidFromProof(sb, matches, proof, 'vendor', row.received_at ?? new Date().toISOString(), data);
  if (n) stats.paid_by_proof = (stats.paid_by_proof ?? 0) + n;
  const what = (matches.length ? matches : invoices.map(t => ({ token: t, amount: 0, total: null, full: false } as ProofMatch)))
    .map(x => `${x.token}${x.amount ? ` ${fmtMoney(x.amount)}` : ''}${x.full ? '' : x.total ? ` (invoice total ${fmtMoney(x.total)}: not marked paid)` : ''}`).join(', ');
  return { state: filed ? 'applied' : 'pending', decision: `Payment receipt for ${what}${n ? ` - ${n} line${n === 1 ? '' : 's'} marked paid` : ''}.` };
}

/** The invoice numbers tracked orders carry (one token, a digit in it: "I051027", "INV-46284") that a text names as a
 *  whole word — so a stub e-mail for a vendor with its own numbering is filed too (v1.14). */
function trackedInvoicesIn(text: string | null | undefined, data: { lines: OtLine[]; orders: OtOrder[] }): string[] {
  const up = ` ${String(text ?? '').toUpperCase()} `;
  const live = new Set(data.orders.filter(o => !o.archived_at).map(o => o.id));
  const tokens = new Set(data.lines.filter(l => live.has(l.order_id)).map(l => String(l.invoice_number ?? '').trim().toUpperCase())
    .filter(t => t.length >= 4 && /\d/.test(t) && /^[A-Z0-9][A-Z0-9-]*$/.test(t)));
  return [...tokens].filter(t => new RegExp(`[^A-Z0-9-]${t.replace(/-/g, '\\-')}[^A-Z0-9-]`).test(up));
}

/** A stub onto every live order with one of its invoices; false when none is tracked yet (it keeps waiting). */
async function attachStub(sb: SupabaseClient, row: { id: string; message_id: string; conversation_id: string | null; file_name: string | null; storage_path: string; parsed: unknown; received_at?: string | null },
                          data: { orders: OtOrder[]; lines: OtLine[]; documents: OtDocument[] }): Promise<boolean> {
  const invoices = ((row.parsed as { invoices?: string[] })?.invoices ?? []).map(invoiceToken);
  // v1.21: a file the reader read is a payment proof (a screenshot, a receipt, an R365 stub)
  const label = (row.parsed as { read?: unknown })?.read ? 'Payment proof' : 'Check stub';
  const live = new Set(data.orders.filter(o => !o.archived_at).map(o => o.id));
  const orderIds = new Set<string>();
  for (const inv of invoices) {
    for (const l of data.lines) if (l.invoice_number && invoiceToken(l.invoice_number) === inv && live.has(l.order_id)) orderIds.add(l.order_id);
    for (const d of data.documents) if (d.kind === 'invoice' && d.order_id && invoiceToken(d.doc_number) === inv && live.has(d.order_id)) orderIds.add(d.order_id);
  }
  if (!orderIds.size) {
    await sb.from('kount_ot_inbox').update({ decision: `${label} for ${invoices.join(', ')} — no order with that invoice yet; it goes on by itself once there is one.` }).eq('id', row.id);
    return false;
  }
  for (const orderId of orderIds) {
    if (data.documents.some(d => d.order_id === orderId && d.storage_path === row.storage_path)) continue;
    const { error } = await sb.from('kount_ot_documents').insert({
      order_id: orderId, kind: 'payment', doc_number: invoices.join(', ').slice(0, 200), doc_date: row.received_at ? row.received_at.slice(0, 10) : null,
      file_name: row.file_name, storage_path: row.storage_path, source_message_id: row.message_id, source_conversation_id: row.conversation_id,
      // to_vendor (v1.14): false = an internal e-mail — the stub is on file but has not gone to the vendor
      parsed: { invoices, ...(typeof (row.parsed as { to_vendor?: unknown })?.to_vendor === 'boolean' ? { to_vendor: (row.parsed as { to_vendor: boolean }).to_vendor } : {}) },
    });
    if (error) throw error;
  }
  await sb.from('kount_ot_inbox').update({
    state: 'applied', order_id: [...orderIds][0], decided_by: 'morning mail pull',
    decision: `${label} for ${invoices.join(', ')} attached to ${orderIds.size === 1 ? 'its order' : `${orderIds.size} orders`}.`,
  }).eq('id', row.id);
  return true;
}

interface PendingRow { id: string; message_id: string; attachment_id: string; conversation_id: string | null; subject: string | null; file_name: string | null; storage_path: string; received_at: string | null; parsed: Record<string, unknown> | null }

/** Look again at everything waiting: since it waited, a person may have saved the order it belongs to. */
async function redecidePending(sb: SupabaseClient, stats: Stats, deadline: number) {
  const { data: rows, error } = await sb.from('kount_ot_inbox')
    .select('id, message_id, attachment_id, conversation_id, subject, file_name, storage_path, received_at, parsed').eq('state', 'pending').order('received_at', { ascending: true });
  if (error) throw error;
  if (!rows?.length) return;
  let data = await loadTracker(sb);
  const opts = await decideOptions(sb);
  if (!data.orders.length && !opts.autoCreate) return;
  const today = laParts().isoDate;
  for (const r of rows as PendingRow[]) {
    if (Date.now() > deadline) break;                  // the rest on the next pull / re-check
    if (!r.parsed) continue;
    if ((r.parsed as { kind?: string }).kind === 'payment') {
      if (await attachStub(sb, r, data)) { stats.stubs++; data = await loadTracker(sb); }
      continue;
    }
    if (r.attachment_id === 'body') {
      const hits = (r.parsed.tracking ?? []) as TrackingHit[];
      const order = orderForEmail(r.conversation_id, String(r.parsed.excerpt ?? r.subject ?? ''), data);
      if (order && hits.length && await applyTracking(sb, r.id, order, hits, r.subject ?? '', r.message_id, r.conversation_id, isRecent(r.received_at))) { stats.tracking++; data = await loadTracker(sb); }
      continue;
    }
    const d = decideMailDocument(r.parsed as unknown as ReadDoc, { id: r.id, message_id: r.message_id, conversation_id: r.conversation_id, file_name: r.file_name, storage_path: r.storage_path },
      data, today, fmtMoney, optsFor(opts, r.received_at));
    if (d.state === 'applied') {
      const { error: aErr } = await sb.rpc('kount_ot_apply_document', { p: d.payload });
      if (!aErr) { stats.applied++; data = await loadTracker(sb); }
    } else if (d.state === 'ignored') {
      await sb.from('kount_ot_inbox').update({ state: 'ignored', decision: d.reason.slice(0, 1000), decided_by: 'morning mail pull' }).eq('id', r.id);
    } else {
      await sb.from('kount_ot_inbox').update({ decision: d.reason.slice(0, 1000), order_id: d.orderId }).eq('id', r.id);
    }
  }
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

interface InboxRow { id: string; message_id: string; conversation_id: string | null; file_name: string | null; storage_path: string; attempts: number; received_at: string | null }

/** This document's options: no new order from one received more than RECENT_DAYS ago (v1.13: past e-mails). */
function optsFor(opts: MailDecideOptions, receivedAt: string | null): MailDecideOptions {
  return opts.autoCreate && !isRecent(receivedAt) ? { ...opts, autoCreate: false } : opts;
}

const KIND_PLURAL: Record<string, string> = { quote: 'quotes', confirmation: 'order confirmations', invoice: 'invoices', shipping: 'shipping notices' };

async function decideOptions(sb: SupabaseClient): Promise<MailDecideOptions> {
  const [{ data: acct }, { data: venues }] = await Promise.all([
    sb.from('kount_ot_mail_account').select('auto_create').eq('id', 1).maybeSingle(),
    sb.from('kount_venues').select('id, name').eq('is_active', true),
  ]);
  // + the order-only venues (Delilah Dallas, Corporate) Kount does not count
  return { autoCreate: acct?.auto_create !== false, venues: orderVenues((venues ?? []) as Array<{ id: string; name: string }>) };
}

async function readPhase(sb: SupabaseClient, stats: Stats, deadline: number, kinds: string[]) {
  let data = await loadTracker(sb);
  const opts = await decideOptions(sb);
  const today = laParts().isoDate;
  while (Date.now() < deadline) {
    const { data: batch, error } = await sb.from('kount_ot_inbox').select('id, message_id, conversation_id, file_name, storage_path, attempts, received_at')
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
      // v1.21 a vendor's payment receipt (not an invoice or quote): the invoices it pays are paid. An order confirmation
      // saying "payment received" (paid at checkout) goes on as a confirmation unless it pays an invoice we track.
      const proof = r.doc as ReadDoc & ProofRead;
      if (proof.payment_proof && (proof.doc_kind === 'other' || (proof.doc_kind !== 'invoice' && proof.doc_kind !== 'quote' && proofMatches(proof, data).length > 0))) {
        const res = await applyVendorReceipt(sb, { id: r.b.id, message_id: r.b.message_id, conversation_id: r.b.conversation_id, file_name: r.b.file_name,
          storage_path: r.b.storage_path, received_at: r.b.received_at }, proof, data, stats);
        await sb.from('kount_ot_inbox').update({ state: res.state, decision: res.decision.slice(0, 1000), decided_by: 'morning mail pull' }).eq('id', r.b.id);
        if (res.state === 'applied') { stats.applied++; data = await loadTracker(sb); } else if (res.state === 'pending') stats.pending++; else stats.ignored++;
        continue;
      }
      if (!kindAllowed(kinds, r.doc)) {
        const only = kinds.map(k => KIND_PLURAL[k] ?? k).join(' and ');
        await sb.from('kount_ot_inbox').update({
          state: 'ignored', decision: `Only ${only} are pulled for now — bring it back to save it.`, decided_by: 'morning mail pull',
        }).eq('id', r.b.id);
        stats.ignored++;
        continue;
      }
      const d = decideMailDocument(r.doc, { id: r.b.id, message_id: r.b.message_id, conversation_id: r.b.conversation_id, file_name: r.b.file_name, storage_path: r.b.storage_path },
        data, today, fmtMoney, optsFor(opts, r.b.received_at));
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

/** Invoiced lines whose R365 AP invoice has been paid -> PAID (matchR365Payments: R365's payment rows
 *  don't name invoices, so vendor + company + amount; unsure = left alone). Each line also keeps WHICH R365
 *  payment paid it (r365_payments, 0143) — lines already past Paid too — so a missing check stub can be
 *  reprinted from R365 by that payment. Never fails the pull. */
const BEFORE_PAID = ['REQUESTED', 'ORDERED', 'QUOTED', 'INVOICED'];
const PAID_ON = ['PAID', 'SHIPPED', 'DELIVERED', 'RECEIVED'];
async function r365PaidPhase(sb: SupabaseClient, stats: Stats) {
  try {
    const [{ data: open, error }, { data: noRef, error: nErr }] = await Promise.all([
      sb.from('kount_ot_lines').select('invoice_number').not('invoice_number', 'is', null).in('status', BEFORE_PAID),
      sb.from('kount_ot_lines').select('invoice_number').not('invoice_number', 'is', null).in('status', PAID_ON).is('r365_payments', null),
    ]);
    if (error) throw error;
    if (nErr) throw nErr;
    const lines = [...(open ?? []), ...(noRef ?? [])];
    const originals = [...new Set((lines ?? []).map(l => String(l.invoice_number).trim()).filter(Boolean))];
    const numbers = [...new Set(originals.map(invoiceToken))];
    if (!numbers.length) return;
    const since = new Date(Date.now() - 150 * 86_400_000).toISOString().slice(0, 10);
    // the first read of the ledger after a quiet spell can pass the 8 s limit; the second is warm (~0.3 s)
    let { data: txs, error: rErr } = await sb.rpc('kount_ot_r365_ap', { p_numbers: numbers, p_since: since });
    if (rErr?.code === '57014') ({ data: txs, error: rErr } = await sb.rpc('kount_ot_r365_ap', { p_numbers: numbers, p_since: since }));
    if (rErr) throw rErr;
    // R365 splits some invoices per venue ("INV-2026-857309 Delilah LA" / Miami / Dallas): paid = every part paid
    const paid = paidInvoices(numbers, ((txs ?? []) as R365Tx[]).map(t => ({ ...t, amount: Number(t.amount) })));
    for (const n of originals) {
      const pays = paid.get(invoiceToken(n));
      if (!pays?.length) continue;
      const note = `Paid in R365: ${pays.map(p => `${p.number} on ${p.date}`).join(', ')}`.slice(0, 300);
      const refs = pays.map(p => ({ number: p.number, date: p.date, amount: Number(p.amount) }));
      const { data: upd, error: uErr } = await sb.from('kount_ot_lines')
        .update({ status: 'PAID', status_source: 'document', status_note: note, r365_payments: refs })
        .eq('invoice_number', n).in('status', BEFORE_PAID).select('id');
      if (uErr) throw uErr;
      if (upd?.length) stats.paid++;
      // already past Paid (shipped, delivered — or paid per the sheet): only which payment it was
      const { error: rErr2 } = await sb.from('kount_ot_lines').update({ r365_payments: refs })
        .eq('invoice_number', n).in('status', PAID_ON).is('r365_payments', null);
      if (rErr2) throw rErr2;
    }
  } catch (e) {
    stats.r365_error = msg(e).slice(0, 300);           // shown in the last run, never fails the pull
    console.error('[kount-order-mail] R365 paid check failed:', stats.r365_error);
  }
}

/** E&E delivery / return / receiving fee lines -> warehouse stock moves (planStorageLine). Each line is
 *  claimed (stock_draw) before its moves are written, so it is recorded once even if two runs overlap;
 *  a line it cannot read waits in Warehouse for a person. Never fails the pull. */
async function storagePhase(sb: SupabaseClient, stats: Stats, who: string) {
  try {
    const data = await loadTracker(sb);
    const orders = new Map(data.orders.map(o => [o.id, o]));
    const todo = data.lines.filter(l => !l.stock_draw && orders.has(l.order_id) && isStorageLine(l, orders.get(l.order_id)!.vendor_name));
    if (!todo.length) return;
    const moves = (await selectAll<OtMove>(sb, 'kount_ot_stock_moves')).map(m => ({ ...m, qty: Number(m.qty) || 0 }));
    const { venues = [] } = await decideOptions(sb);
    const drawn = new Set(moves.map(m => m.line_id).filter(Boolean));
    const claim = async (id: string) => {
      const { data: got, error } = await sb.from('kount_ot_lines').update({ stock_draw: 'recorded' }).eq('id', id).is('stock_draw', null).select('id');
      if (error) throw error;
      return !!got?.length;
    };
    for (const l of todo) {
      if (drawn.has(l.id)) { await claim(l.id); continue; }       // recorded by hand already
      const o = orders.get(l.order_id)!;
      const plan = planStorageLine(l, o, data.items, moves, venues);
      if (plan.problem) { stats.storage_review = (stats.storage_review ?? 0) + 1; continue; }
      if (!(await claim(l.id))) continue;
      const rows = storageMoveRows(plan, l, l.invoice_date ?? o.ordered_on ?? laParts().isoDate).map(r => ({ ...r, created_by: who }));
      // v1.30 (0179): a trip already asked for by e-mail is that release - it takes the invoice's day, cases and line
      const { link, insert } = linkStorageRows(rows, moves);
      for (const { move, row } of link) {
        const { error } = await sb.from('kount_ot_stock_moves').update({ line_id: row.line_id, moved_on: row.moved_on, qty: row.qty,
          note: `${move.note ?? ''} · ${row.note}`.slice(0, 500) }).eq('id', move.id);
        if (error) {
          await sb.from('kount_ot_lines').update({ stock_draw: null }).eq('id', l.id);
          throw error;
        }
        Object.assign(move, { line_id: row.line_id, moved_on: row.moved_on, qty: row.qty });
      }
      const { error } = insert.length ? await sb.from('kount_ot_stock_moves').insert(insert) : { error: null };
      if (error) {
        await sb.from('kount_ot_lines').update({ stock_draw: null }).eq('id', l.id);
        throw error;
      }
      moves.push(...insert.map(r => ({ ...r, id: '' })));
      stats.storage = (stats.storage ?? 0) + 1;
      if (link.length) stats.storage_linked = (stats.storage_linked ?? 0) + link.length;
    }
  } catch (e) {
    stats.storage_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] storage draws failed:', stats.storage_error);
  }
}

/** When each order went to the vendor (0147), from the e-mail threads its documents came in (sentToVendor: the
 *  exchange that led to its first quote / invoice / confirmation). A day typed in the order panel is kept; the
 *  sheet's Order Date and the PO date give way to the e-mail's. Never fails the pull. */
async function sentPhase(sb: SupabaseClient, stats: Stats) {
  try {
    const { data: acct, error } = await sb.from('kount_ot_mail_account').select('vendor_domains').eq('id', 1).single();
    if (error) throw error;
    const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
    if (tErr) throw tErr;
    if (!refresh) return;
    const data = await loadTracker(sb);
    const todo = new Set(data.orders.filter(o => o.sent_source !== 'email' && o.sent_source !== 'manual').map(o => o.id));
    const threads = new Map<string, Set<string>>();
    const docMessages = new Map<string, Set<string>>();          // the e-mails that brought each order's documents
    const firstDoc = new Map<string, string>();                   // each order's first quote / invoice / confirmation day
    const { data: docMsgs, error: mErr } = await sb.from('kount_ot_documents').select('order_id, source_message_id, kind, doc_date').not('order_id', 'is', null);
    if (mErr) throw mErr;
    for (const d of docMsgs ?? []) {
      if (!todo.has(d.order_id) || !['quote', 'invoice', 'confirmation'].includes(d.kind)) continue;
      if (d.source_message_id) (docMessages.get(d.order_id) ?? docMessages.set(d.order_id, new Set()).get(d.order_id)!).add(d.source_message_id);
      if (d.doc_date && (!firstDoc.has(d.order_id) || d.doc_date < firstDoc.get(d.order_id)!)) firstDoc.set(d.order_id, d.doc_date);
    }
    for (const d of data.documents) {
      if (!d.order_id || !d.source_conversation_id || !todo.has(d.order_id) || !['quote', 'invoice', 'confirmation'].includes(d.kind)) continue;
      (threads.get(d.order_id) ?? threads.set(d.order_id, new Set()).get(d.order_id)!).add(d.source_conversation_id);
    }
    if (!threads.size) return;
    const tok = await refreshAccess(String(refresh));
    if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
    const domains: string[] = acct.vendor_domains ?? [];
    const thread = new Map<string, ThreadMessage[]>();
    for (const [orderId, convs] of threads) {
      let first: string | null = null;
      for (const c of convs) {
        if (!thread.has(c)) {
          const page = await graphGet<{ value?: ThreadMessage[] }>(tok.access_token, `/me/messages?$filter=${encodeURIComponent(`conversationId eq '${c.replace(/'/g, "''")}'`)}`
            + '&$select=id,sentDateTime,receivedDateTime,isDraft,from,toRecipients,ccRecipients&$top=250');
          thread.set(c, page.value ?? []);
        }
        const f = sentToVendor(thread.get(c)!, domains, docMessages.get(orderId) ?? new Set(), firstDoc.get(orderId) ?? null);
        if (f && (!first || Date.parse(f) < Date.parse(first))) first = f;
      }
      const day = first ? laParts(new Date(first)).isoDate : null;
      if (!takeEmailSentDay(day, data.orders.find(o => o.id === orderId)?.sent_on ?? null, firstDoc.get(orderId) ?? null)) continue;
      const { data: upd, error: uErr } = await sb.from('kount_ot_orders').update({ sent_on: day, sent_source: 'email' })
        .eq('id', orderId).or('sent_source.is.null,sent_source.in.(sheet,po_date)').select('id');
      if (uErr) throw uErr;
      if (upd?.length) stats.sent = (stats.sent ?? 0) + 1;
    }
  } catch (e) {
    stats.sent_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] sent dates failed:', stats.sent_error);
  }
}

/** Quoted lines stay flagged until h.wood e-mails the vendor its go-ahead (0157). For each open order with a Quoted
 *  line and no approval e-mail for its quote number: read the order's threads (its documents' and the Inbox's) and,
 *  for a real quote number, the e-mails that mention it; planQuoteApprovals says which lines a reply approved, and
 *  they are stamped (when, which quote, who said what). Read-only on the mailbox. Never fails the pull. */
const MAIL_FIELDS = 'id,conversationId,sentDateTime,receivedDateTime,isDraft,from,toRecipients,ccRecipients,uniqueBody,bodyPreview';
async function approvalPhase(sb: SupabaseClient, stats: Stats) {
  try {
    const data = await loadTracker(sb);
    const byOrder = new Map<string, OtLine[]>();
    for (const l of data.lines) (byOrder.get(l.order_id) ?? byOrder.set(l.order_id, []).get(l.order_id)!).push(l);
    const todo = data.orders.filter(o => !o.archived_at && !o.completed_at && (byOrder.get(o.id) ?? []).some(awaitingApproval));
    if (!todo.length) return;
    const { data: refresh, error: tErr } = await sb.rpc('kount_ot_mail_token_get');
    if (tErr) throw tErr;
    if (!refresh) return;
    const tok = await refreshAccess(String(refresh));
    if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
    const { data: inbox, error: iErr } = await sb.from('kount_ot_inbox').select('order_id, conversation_id')
      .in('order_id', todo.map(o => o.id)).not('conversation_id', 'is', null);
    if (iErr) throw iErr;
    const threadCache = new Map<string, MailMessage[]>();
    const searchCache = new Map<string, MailMessage[]>();
    for (const o of todo) {
      const ls = byOrder.get(o.id) ?? [];
      const docs = data.documents.filter(d => d.order_id === o.id);
      const convs = new Set([...docs.map(d => d.source_conversation_id), ...(inbox ?? []).filter(r => r.order_id === o.id).map(r => r.conversation_id)]
        .filter((c): c is string => !!c));
      const threads = new Map<string, MailMessage[]>();
      for (const c of convs) {
        if (!threadCache.has(c)) {
          const page = await graphGet<{ value?: MailMessage[] }>(tok.access_token, `/me/messages?$filter=${encodeURIComponent(`conversationId eq '${c.replace(/'/g, "''")}'`)}`
            + `&$select=${MAIL_FIELDS}&$top=100`, { textBody: true });
          threadCache.set(c, page.value ?? []);
        }
        threads.set(c, threadCache.get(c)!);
      }
      const searched = new Map<string, MailMessage[]>();
      for (const l of ls) {
        if (!awaitingApproval(l) || !searchableQuote(l.quote_number)) continue;
        const k = quoteKey(l.quote_number);
        if (!searchCache.has(k)) {
          const page = await graphGet<{ value?: MailMessage[] }>(tok.access_token, `/me/messages?$search=${encodeURIComponent(`"${String(l.quote_number).replace(/"/g, '')}"`)}`
            + `&$select=${MAIL_FIELDS}&$top=25`, { textBody: true });
          searchCache.set(k, page.value ?? []);
        }
        searched.set(k, searchCache.get(k)!);
      }
      for (const s of planQuoteApprovals(ls, docs, threads, searched)) {
        const { data: upd, error } = await sb.from('kount_ot_lines').update({
          quote_approved_at: s.approval.at, quote_approved_for: s.quoteNumber,
          quote_approval_note: `${s.approval.by}: "${s.approval.note}"`.slice(0, 500), quote_approval_message_id: s.approval.messageId,
        }).in('id', s.lineIds).eq('status', 'QUOTED').select('id');
        if (error) throw error;
        stats.approved = (stats.approved ?? 0) + (upd?.length ?? 0);
      }
    }
  } catch (e) {
    stats.approval_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] quote approvals failed:', stats.approval_error);
  }
}

/** "Follow up" on quiet orders (0178; the user, 11/18: "for any order without a new email in the thread for over 3
 *  days, needs a status marker saying followup required"). For each open order with a line not delivered yet, the
 *  latest e-mail in its threads - its documents', the Inbox's and its tracking's conversations - any sender, ours too
 *  (latestThreadMail), stamped on kount_ot_orders.last_email_at; the screens flag the order when that is more than 3
 *  days old. The least recently checked orders go first and the step stops at its deadline, so a check that runs short
 *  carries on with the rest next time. Read-only on the mailbox. Never fails the run. */
const THREAD_BUDGET_MS = 60_000;
async function threadPhase(sb: SupabaseClient, stats: Stats, accessToken: string, deadline = Date.now() + THREAD_BUDGET_MS) {
  try {
    const data = await loadTracker(sb);
    const inFlight = new Set(data.lines.filter(l => !['DELIVERED', 'RECEIVED', 'CANCELLED'].includes(l.status)).map(l => l.order_id));
    type Quiet = OtOrder & { last_email_at?: string | null; thread_checked_at?: string | null };
    const todo = (data.orders as Quiet[]).filter(o => !o.archived_at && !o.completed_at && inFlight.has(o.id))
      .sort((a, b) => String(a.thread_checked_at ?? '').localeCompare(String(b.thread_checked_at ?? '')));
    if (!todo.length) return;
    const ids = todo.map(o => o.id);
    const convs = new Map<string, Set<string>>();
    const add = (orderId: string | null, c: string | null) => {
      if (orderId && c) (convs.get(orderId) ?? convs.set(orderId, new Set()).get(orderId)!).add(c);
    };
    for (const d of data.documents) add(d.order_id, d.source_conversation_id ?? null);
    for (let i = 0; i < ids.length; i += 200) {
      const part = ids.slice(i, i + 200);
      const [inbox, tracking] = await Promise.all([
        sb.from('kount_ot_inbox').select('order_id, conversation_id').in('order_id', part).not('conversation_id', 'is', null),
        sb.from('kount_ot_tracking').select('order_id, conversation_id').in('order_id', part).not('conversation_id', 'is', null),
      ]);
      if (inbox.error) throw inbox.error;
      if (tracking.error) throw tracking.error;
      for (const r of [...(inbox.data ?? []), ...(tracking.data ?? [])]) add(r.order_id, r.conversation_id);
    }
    const cache = new Map<string, ThreadMessage[]>();
    let checked = 0, moved = 0;
    for (const o of todo) {
      if (Date.now() > deadline) { stats.threads_note = `stopped at the time limit: ${todo.length - checked} orders left for the next check`; break; }
      const found: ThreadMessage[] = [];
      for (const c of convs.get(o.id) ?? []) {
        if (!cache.has(c)) {
          const page = await graphGet<{ value?: ThreadMessage[] }>(accessToken, `/me/messages?$filter=${encodeURIComponent(`conversationId eq '${c.replace(/'/g, "''")}'`)}`
            + '&$select=id,sentDateTime,receivedDateTime,isDraft,from&$top=250');
          cache.set(c, page.value ?? []);
        }
        found.push(...cache.get(c)!);
      }
      const last = latestThreadMail(found);
      const patch: Record<string, string> = { thread_checked_at: nowIso() };
      if (last && laterMail(o.last_email_at, last.at)) { patch.last_email_at = last.at; patch.last_email_from = last.from; moved++; }
      const { error } = await sb.from('kount_ot_orders').update(patch).eq('id', o.id);
      if (error) throw error;
      checked++;
    }
    stats.threads_checked = checked;
    stats.threads_moved = moved;
  } catch (e) {
    stats.threads_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] order threads failed:', stats.threads_error);
  }
}

/** A fresh Graph access token from the stored refresh token (rotated as Microsoft hands back a new one); null when
 *  Outlook is not connected. */
async function mailAccessToken(sb: SupabaseClient): Promise<string | null> {
  const { data: refresh, error } = await sb.rpc('kount_ot_mail_token_get');
  if (error) throw error;
  if (!refresh) return null;
  const tok = await refreshAccess(String(refresh));
  if (tok.refresh_token) await sb.rpc('kount_ot_mail_token_set', { p_token: tok.refresh_token });
  return tok.access_token;
}

/** The release engine (0179, admin v1.30; the user, 11/18: "I order a large batch, then EE stores it, then from that
 *  large pile i keep ordering smaller batches ... build the engine that tracks them like this"). Every e-mail h.wood sent
 *  E&E since the last read: one asking for cases out of storage becomes releases (the venue, the cases) dated the day it
 *  was asked; one the reader is unsure of waits in the Warehouse tab for a person; anything else is noted and skipped.
 *  A release already recorded for that trip (typed by hand, from E&E's invoice, the 11/18 back-fill) is linked, not added
 *  again. A words test comes before the reader, so quotes and payments cost nothing. Read-only on the mailbox. Never
 *  fails the run. */
const RELEASE_LOOKBACK_DAYS = 14;
const RELEASE_BUDGET_MS = 45_000;
const RELEASE_FIELDS = 'id,subject,from,toRecipients,ccRecipients,sentDateTime,receivedDateTime,conversationId,internetMessageId,isDraft,uniqueBody,bodyPreview';
interface ReleaseMsg {
  id: string; subject?: string; sentDateTime?: string; receivedDateTime?: string; conversationId?: string; internetMessageId?: string; isDraft?: boolean;
  from?: { emailAddress?: { address?: string; name?: string } };
  toRecipients?: Array<{ emailAddress?: { address?: string } }>; ccRecipients?: Array<{ emailAddress?: { address?: string } }>;
  uniqueBody?: { content?: string }; bodyPreview?: string;
}
async function releasePhase(sb: SupabaseClient, stats: Stats, accessToken: string, deadline = Date.now() + RELEASE_BUDGET_MS) {
  try {
    const { data: acct, error } = await sb.from('kount_ot_mail_account').select('vendor_domains, release_cursor').eq('id', 1).single();
    if (error) throw error;
    // E&E's own storage only (not a factory shipping straight to a venue, not i.Halper)
    const ee = ((acct.vendor_domains ?? []) as string[]).filter(d => /eemercantile/i.test(d));
    if (!ee.length) ee.push('eemercantile.co');
    const fromMs = acct.release_cursor ? Date.parse(acct.release_cursor) - 86_400_000 : Date.now() - RELEASE_LOOKBACK_DAYS * 86_400_000;
    const sinceDay = new Date(fromMs).toISOString().slice(0, 10);
    const byId = new Map<string, ReleaseMsg>();
    // one field per search: Outlook refuses "participants:" (an OR of from / to / cc) together with a date (11/19, the
    // first run: "Unrecognized filter of type Microsoft.Exchange.Data.OrFilter"); "from:<domain> received>=" works
    const searchErrors: string[] = [];
    for (const d of ee) for (const field of ['to', 'cc']) {
      try {
        let url = `/me/messages?$search=${encodeURIComponent(`"${field}:${d} received>=${sinceDay}"`)}&$select=${RELEASE_FIELDS}&$top=25`;
        let pages = 0;
        while (url && pages++ < 20) {
          const page = await graphGet<{ value?: ReleaseMsg[]; '@odata.nextLink'?: string }>(accessToken, url, { textBody: true });
          for (const m of page.value ?? []) byId.set(m.id, m);
          url = page['@odata.nextLink'] ?? '';
        }
      } catch (e) {
        // one search refused still leaves the other (the e-mails to E&E are the most of them)
        if (e instanceof GraphError && e.reauth) throw e;
        searchErrors.push(`${field}: ${msg(e)}`.slice(0, 150));
      }
    }
    if (searchErrors.length === ee.length * 2) throw new Error(searchErrors.join(' | '));
    if (searchErrors.length) stats.releases_note = `a search was refused (${searchErrors.join(' | ')})`;
    // ours (a teammate's with us on copy too), not a draft, to or copying E&E; oldest first so the cursor only moves forward
    const toEe = (m: ReleaseMsg) => [...(m.toRecipients ?? []), ...(m.ccRecipients ?? [])].some(r => onList(domainOf(r.emailAddress?.address), ee));
    const at = (m: ReleaseMsg) => m.sentDateTime ?? m.receivedDateTime ?? '';
    const mine = [...byId.values()].filter(m => !m.isDraft && onList(domainOf(m.from?.emailAddress?.address), OWN_DOMAINS) && toEe(m))
      .sort((a, b) => at(a).localeCompare(at(b)));
    stats.releases_seen = mine.length;
    if (!mine.length) return;
    const { data: seenRows, error: sErr } = await sb.from('kount_ot_release_mail').select('message_id').in('message_id', mine.map(m => m.id));
    if (sErr) throw sErr;
    const seen = new Set((seenRows ?? []).map(r => r.message_id as string));
    const data = await loadTracker(sb);
    const moves = (await selectAll<OtMove>(sb, 'kount_ot_stock_moves')).map(m => ({ ...m, qty: Number(m.qty) || 0 }));
    const { venues = [] } = await decideOptions(sb);
    const stock = data.items.filter(i => i.is_active && i.track_stock && itemLocation(i) === EE_WAREHOUSE && isCustomItem(i));
    const context = releaseContext(stock, venues);
    let cursor: string | null = acct.release_cursor ?? null;
    const done = (m: ReleaseMsg) => { const t = at(m); if (t && (!cursor || Date.parse(t) > Date.parse(cursor))) cursor = t; };
    const keep = async (row: Record<string, unknown>) => {
      const { error: e } = await sb.from('kount_ot_release_mail').insert(row);
      if (e && e.code !== '23505') throw e;
    };
    for (const m of mine) {
      if (seen.has(m.id)) { done(m); continue; }
      if (Date.now() > deadline) { stats.releases_note = 'stopped at the time limit; the rest next time'; break; }
      const sentAt = at(m) || nowIso();
      const body = String(m.uniqueBody?.content ?? m.bodyPreview ?? '').replace(/\r/g, '').trim();
      const base = {
        message_id: m.id, conversation_id: m.conversationId ?? null, internet_message_id: m.internetMessageId ?? null, sent_at: sentAt,
        sender_email: (m.from?.emailAddress?.address ?? '').toLowerCase() || null, sender_name: m.from?.emailAddress?.name ?? null,
        subject: (m.subject ?? '').slice(0, 300), excerpt: body.slice(0, 1500),
      };
      if (!releaseMailCandidate(m.subject, body)) {
        await keep({ ...base, state: 'not_release', decision: 'No cases sent, delivered or picked up in it.' });
        done(m); continue;
      }
      const { read, model } = await readReleaseMail({ subject: base.subject, from: `${base.sender_name ?? ''} <${base.sender_email ?? ''}>`, sentAt, body, context, messageId: m.id });
      stats.releases_read = (stats.releases_read ?? 0) + 1;
      const kept = { ...read, model };
      if (!read.is_release) {
        await keep({ ...base, read: kept, state: 'not_release', decision: 'Not stock out of storage (read).' });
        done(m); continue;
      }
      const day = laParts(new Date(sentAt)).isoDate;
      const plan = planReleaseMail(read, day, data.items, moves, venues);
      if (plan.problem) {
        await keep({ ...base, read: kept, state: 'review', decision: plan.problem.slice(0, 500) });
        stats.releases_review = (stats.releases_review ?? 0) + 1;
        done(m); continue;
      }
      const { data: row, error: iErr } = await sb.from('kount_ot_release_mail').insert({ ...base, read: kept, state: 'recorded', decision: '' }).select('id').single();
      if (iErr) { if (iErr.code === '23505') { done(m); continue; } throw iErr; }
      const ids: string[] = [], said: string[] = [];
      for (const d of plan.draws) {
        // the same trip already in (typed, E&E's invoice, the 11/18 back-fill): link it, never add it twice
        const had = matchRelease(moves, d.itemId, plan.venueId, day, d.qty, 7, x => !x.mail_id);
        if (had) {
          const { error: e } = await sb.from('kount_ot_stock_moves').update({ mail_id: row.id }).eq('id', had.id);
          if (e) throw e;
          had.mail_id = row.id; ids.push(had.id); said.push(`${d.qty} ${d.name} (already in, ${had.moved_on})`);
          continue;
        }
        const ins = { item_id: d.itemId, moved_on: day, kind: 'release' as const, qty: d.qty, venue_id: plan.venueId, line_id: null,
          note: `Asked E&E by e-mail: ${base.subject}`.slice(0, 500), created_by: base.sender_email, created_at: `${day}T19:00:00Z`, mail_id: row.id };
        const { data: mv, error: e } = await sb.from('kount_ot_stock_moves').insert(ins).select('id').single();
        if (e) throw e;
        moves.push({ ...ins, id: mv.id } as OtMove); ids.push(mv.id); said.push(`${d.qty} ${d.name}`);
      }
      const { error: uErr } = await sb.from('kount_ot_release_mail').update({ move_ids: ids, decision: said.join('; ').slice(0, 500) }).eq('id', row.id);
      if (uErr) throw uErr;
      stats.releases_recorded = (stats.releases_recorded ?? 0) + 1;
      done(m);
    }
    if (cursor && cursor !== acct.release_cursor) {
      const { error: cErr } = await sb.from('kount_ot_mail_account').update({ release_cursor: cursor }).eq('id', 1);
      if (cErr) throw cErr;
    }
  } catch (e) {
    stats.releases_error = msg(e).slice(0, 300);
    console.error('[kount-order-mail] releases failed:', stats.releases_error);
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
    selectAll<OtDocument>(sb, 'kount_ot_documents', 'id, order_id, kind, doc_number, doc_date, vendor_name, total, file_name, storage_path, created_at, source_conversation_id, source_message_id'),
  ]);
  return {
    orders,
    lines: lines.map(l => ({ ...l, qty: Number(l.qty) || 0, unit_price: num(l.unit_price) })),
    items: items.map(i => ({ ...i, pack_size: num(i.pack_size), reorder_point: num(i.reorder_point), lead_time_days: num(i.lead_time_days) })),
    documents,
  };
}
