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
// This function puts the chat on that same footing. Since 2026-11-17 (the user:
// "lets switch all to openrouter please") it runs on OpenRouter ONLY - no Claude /
// Anthropic key is read:
//
//   supabase secrets set OPENROUTER_API_KEY=...   (OPENROUTER_MODEL optional)
//
// AUTH MODEL — deliberately stricter than parse-bottle-label
// Supabase's default verify_jwt accepts the ANON key, which is public (it
// ships inside the client). For a general-purpose chat endpoint that is not
// good enough: anyone who read the anon key out of the bundle could use this
// as a free Claude proxy billed to h.wood. So, mirroring admin-user-mgmt, we
// resolve the caller's OWN JWT to a real user and require that the database
// lets them count (_shared/counting-auth.ts). Any role may use the assistant — it only gives advice and cannot
// modify a count — but an anonymous caller cannot.
//
// The reply is returned already flattened to { text }, matching what the
// client's callAnthropic did with content blocks, so callers stay simple and
// no token-usage detail is leaked to the browser.

import { corsHeaders, withCors } from '../_shared/cors.ts';
import { requireCountingUser } from '../_shared/counting-auth.ts';

const OPENROUTER_API_URL = 'https://openrouter.ai/api/v1/chat/completions';

// Allowlist rather than passing the client's model straight through: the
// caller is a browser, and an unbounded model string would let anyone select
// the most expensive model available on the account.
const DEFAULT_MODEL = 'claude-sonnet-4-6';
const ALLOWED_MODELS = new Set([
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

Deno.serve(withCors(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reject(405, 'Method not allowed');

  const openRouterKey = Deno.env.get('OPENROUTER_API_KEY') || Deno.env.get('OPENROUTHER_API_KEY');
  if (!openRouterKey) {
    return reject(500, 'OPENROUTER_API_KEY is not set in Edge Function secrets');
  }

  // --- 1-2. Caller's OWN JWT, and the database must let them count
  // (active app_users row, access grant or Keva membership). ---
  const auth = await requireCountingUser(req, 'ask-ai');
  if (auth instanceof Response) return auth;
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

  // --- 4. Proxy to OpenRouter (the only AI path since 2026-11-17). ---
  {
    const openRouterModel = Deno.env.get('OPENROUTER_MODEL') || 'anthropic/claude-sonnet-4.6';
    const orMessages: Array<{ role: string; content: string }> = [];
    if (system) {
      orMessages.push({ role: 'system', content: system });
    }
    for (const m of messages) {
      const typed = m as { role: string; content: string };
      orMessages.push({ role: typed.role, content: String(typed.content) });
    }

    const payload = {
      model: openRouterModel,
      max_tokens: maxTokens,
      messages: orMessages,
    };

    let res: Response;
    try {
      res = await fetch(OPENROUTER_API_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${openRouterKey}`,
          'HTTP-Referer': 'https://kount.kevaos.ai',
          'X-Title': 'Kount by Keva',
        },
        body: JSON.stringify(payload),
      });
    } catch (e) {
      console.error('[ask-ai] openrouter fetch failed:', e);
      return reject(502, 'Could not reach the AI service — try again');
    }

    if (!res.ok) {
      let detail = '';
      try { detail = await res.text(); } catch { /* ignore */ }
      console.error('[ask-ai] openrouter error', res.status, detail.slice(0, 500));
      if (res.status === 429) return reject(429, 'AI is busy right now — try again in a moment');
      if (res.status >= 500) return reject(502, 'The AI service is having trouble — try again');
      return reject(502, 'AI request failed');
    }

    let data: { choices?: Array<{ message?: { content?: string } }> };
    try {
      data = await res.json();
    } catch {
      return reject(502, 'AI returned a malformed response');
    }

    const text = data.choices?.[0]?.message?.content || '';
    return jsonResponse(200, { text, model: openRouterModel });
  }

}));
