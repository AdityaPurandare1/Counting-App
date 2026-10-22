// supabase/functions/ask-ai/index.ts
//
// Edge Function: server-side proxy for the in-app "Ask AI" assistant.
//
// WHY THIS EXISTS
// The chat used to call https://api.anthropic.com/v1/messages DIRECTLY FROM
// THE BROWSER, using an Anthropic key each user pasted into AI Settings and
// which was then kept in localStorage under 'hwood_anthropic_key', sent with
// the `anthropic-dangerous-direct-browser-access: true` header. That meant:
//
//   * every user needed their own key before the feature worked at all, so
//     in practice almost nobody had it switched on;
//   * a live API key sat in localStorage on a shared floor phone, readable by
//     any script on the origin;
//   * the key travelled from the browser on every request;
//   * spend was per-person and invisible centrally.
//
// Photo parsing already solved this properly — parse-bottle-label holds
// ANTHROPIC_API_KEY in Supabase secrets and the key never leaves the server.
// This function puts the chat on that same footing. Both AI features route
// through KevaOS's central AI connection (../_shared/ai-router.ts: OpenRouter
// on a pinned model, data_collection=deny, usage logged), with Anthropic
// direct as the fallback:
//
//   supabase secrets set KEVAOS_COUNTING_AI_KEY=...   ANTHROPIC_API_KEY=...
//
// AUTH MODEL — deliberately stricter than parse-bottle-label
// Supabase's default verify_jwt accepts the ANON key, which is public (it
// ships inside the client). For a general-purpose chat endpoint that is not
// good enough: anyone who read the anon key out of the bundle could use this
// as a free Claude proxy billed to h.wood. So, mirroring admin-user-mgmt, we
// resolve the caller's OWN JWT to a real user and require an active row in
// app_users. Any role may use the assistant — it only gives advice and cannot
// modify a count — but an anonymous caller cannot.
//
// The reply is returned already flattened to { text }, matching what the
// client's callAnthropic did with content blocks, so callers stay simple and
// no token-usage detail is leaked to the browser.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';
import { corsHeaders } from '../_shared/cors.ts';
import { AiRouterError, type ChatMessage, type ClaudeModel, routeClaude } from '../_shared/ai-router.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') || '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') || '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';

// Allowlist rather than passing the client's model straight through: the
// caller is a browser, and an unbounded model string would let anyone select
// the most expensive model available on the account.
const DEFAULT_MODEL: ClaudeModel = 'claude-sonnet-4-6';
const ALLOWED_MODELS = new Set<string>([
  'claude-sonnet-4-6',
  'claude-haiku-4-5',
]);

// Abuse bounds. The assistant is a short Q&A over the current screen's
// context, not a long-document tool, so these are generous for real use and
// still cap what a single call can cost.
const MAX_TOKENS_CAP = 2048;
const MAX_MESSAGES = 40;
const MAX_SYSTEM_CHARS = 8000;

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
function reject(status: number, message: string): Response {
  return jsonResponse(status, { error: message });
}

interface RequestBody {
  messages?: unknown;
  system?: unknown;
  max_tokens?: unknown;
  model?: unknown;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reject(405, 'Method not allowed');

  // --- 1. Caller must present their OWN JWT, not just the anon key. ---
  const authHeader = req.headers.get('Authorization') || '';
  const callerJwt = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!callerJwt) return reject(401, 'Missing Authorization header');

  const supabaseAsCaller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: 'Bearer ' + callerJwt } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // The anon key is a structurally valid JWT but resolves to no user, so this
  // is what actually closes the open-proxy hole.
  const { data: userResp, error: userErr } = await supabaseAsCaller.auth.getUser();
  if (userErr || !userResp.user || !userResp.user.email) {
    return reject(401, 'Invalid or expired JWT');
  }
  const callerEmail = userResp.user.email.toLowerCase();

  // --- 2. Must be an ACTIVE app user. Service-role lookup so a gap in the
  // app_users SELECT policy can't quietly turn into an auth bypass. ---
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: profile, error: profileErr } = await admin
    .from('app_users')
    .select('role,is_active')
    .eq('email', callerEmail)
    .limit(1)
    .maybeSingle();

  if (profileErr) {
    console.error('[ask-ai] profile lookup error:', profileErr);
    return reject(500, 'Failed to verify caller');
  }
  if (!profile || profile.is_active === false) {
    return reject(403, 'Caller is not an active app user');
  }
  // Note: no role gate. Every active user may ask the assistant questions —
  // it returns text only and cannot alter a count or any record.

  // --- 3. Validate the payload. ---
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return reject(400, 'Body must be JSON');
  }

  const messages = body.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    return reject(400, 'messages must be a non-empty array');
  }
  if (messages.length > MAX_MESSAGES) {
    return reject(400, 'Conversation too long (max ' + MAX_MESSAGES + ' messages) — start a new chat');
  }
  for (const m of messages) {
    if (!m || typeof m !== 'object') return reject(400, 'Each message must be an object');
    const role = (m as { role?: unknown }).role;
    if (role !== 'user' && role !== 'assistant') {
      return reject(400, "Each message.role must be 'user' or 'assistant'");
    }
    if ((m as { content?: unknown }).content === undefined) {
      return reject(400, 'Each message needs content');
    }
  }

  const system = typeof body.system === 'string' ? body.system.slice(0, MAX_SYSTEM_CHARS) : undefined;

  const requestedTokens = Number(body.max_tokens);
  const maxTokens = Number.isFinite(requestedTokens) && requestedTokens > 0
    ? Math.min(Math.floor(requestedTokens), MAX_TOKENS_CAP)
    : 1024;

  const requestedModel = typeof body.model === 'string' ? body.model : '';
  const model = (ALLOWED_MODELS.has(requestedModel) ? requestedModel : DEFAULT_MODEL) as ClaudeModel;

  // --- 4. Route the call. The keys stay here. ---
  let result;
  try {
    result = await routeClaude({
      flow: 'counting-ask-ai',
      kevaosFlow: 'ask',
      model,
      maxTokens,
      system: system ? [{ text: system }] : undefined,
      messages: messages as ChatMessage[],
      actorId: userResp.user.id,
      metadata: { role: profile.role },
    });
  } catch (e) {
    // Upstream detail is logged server-side by the router; return something
    // safe. A 401 here means OUR key is bad -- not something to explain to a
    // counter on the floor.
    const status = e instanceof AiRouterError ? e.status : 0;
    if (status === 429) return reject(429, 'AI is busy right now — try again in a moment');
    if (status === 500) return reject(500, (e as Error).message);
    if (status >= 500 || status === 0) return reject(502, 'The AI service is having trouble — try again');
    return reject(502, 'AI request failed');
  }

  // Already flattened to text, as the old browser-side callAnthropic did.
  return jsonResponse(200, { text: result.text, model });
});
