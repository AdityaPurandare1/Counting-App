// supabase/functions/_shared/ai-router.ts
//
// One AI path for the counting apps: KevaOS's central AI connection.
//
//   1. KevaOS first -- POST /api/external/counting/ai (Restaurant-App), which
//      runs the call through lib/ai/gateway: OpenRouter on the task's pinned
//      model with data_collection=deny, KevaOS's Anthropic key as its fallback,
//      usage logged by KevaOS to platform_ai_usage_events. Auth is a KevaOS
//      partner API key with scope counting:ai, held here as a secret:
//
//        KEVAOS_COUNTING_AI_KEY   (required for this step; unset = skipped)
//        KEVAOS_AI_URL            (optional, default https://kevaos.ai/api/external/counting/ai)
//
//   2. OpenRouter direct with the OpenRouter key held in this project's Edge
//      Function secrets (OPENROUTER_API_KEY), when KevaOS is not configured or
//      fails. Same Claude models (anthropic/claude-sonnet-4.6 / haiku-4.5),
//      structured output via response_format json_schema, and KevaOS's policy
//      provider.data_collection = 'deny'. Added 2026-10-26: the Anthropic
//      account ran out of credits and photo labels fell back to on-device OCR.
//
//   3. Anthropic direct with our own key (ANTHROPIC_API_KEY) when neither of
//      the above is configured or both fail. Structured output is enforced
//      natively on this path.
//
// KevaOS logs the calls it serves; this module logs only what KevaOS did not:
// a failed KevaOS attempt, and every OpenRouter / Anthropic-direct call.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

export type ClaudeModel = 'claude-sonnet-4-6' | 'claude-haiku-4-5';

const KEVAOS_DEFAULT_URL = 'https://kevaos.ai/api/external/counting/ai';
const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';

// The same models, by OpenRouter's ids (both take images and structured output).
const OPENROUTER_MODEL: Record<ClaudeModel, string> = {
  'claude-sonnet-4-6': 'anthropic/claude-sonnet-4.6',
  'claude-haiku-4-5': 'anthropic/claude-haiku-4.5',
};

// $ per million tokens, for the Anthropic-direct usage rows (Anthropic does not report cost).
const PRICE: Record<ClaudeModel, { input: number; output: number; cacheRead: number; cacheWrite: number }> = {
  'claude-sonnet-4-6': { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  'claude-haiku-4-5': { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 },
};

// KevaOS gets a shorter leash so a slow attempt still leaves time for the
// Anthropic fallback inside the Edge Function's wall clock.
const KEVAOS_TIMEOUT_MS = 45_000;
const OPENROUTER_TIMEOUT_MS = 50_000;
const ANTHROPIC_TIMEOUT_MS = 60_000;

export type TextBlock = { type: 'text'; text: string };
export type ImageBlock = { type: 'image'; source: { type: 'base64'; media_type: string; data: string } };
export type ContentBlock = TextBlock | ImageBlock;
export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string | ContentBlock[];
}

export interface AiRequest {
  /** Stable code-path name, logged as flow_name (e.g. 'counting-photo-label'). */
  flow: string;
  /** Which KevaOS counting flow serves this call (picks the gateway task there). */
  kevaosFlow: 'photo-label' | 'ask';
  /** Model for the Anthropic-direct fallback. KevaOS picks its own (the task's pinned model). */
  model: ClaudeModel;
  maxTokens: number;
  /** System prompt parts. `cache: true` puts a prompt-cache breakpoint after that part. */
  system?: Array<{ text: string; cache?: boolean }>;
  messages: ChatMessage[];
  /** Structured output. The reply must parse as JSON or the attempt counts as failed. */
  jsonSchema?: { name: string; schema: Record<string, unknown> };
  actorId?: string | null;
  metadata?: Record<string, unknown>;
}

export interface AiUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface AiResult {
  text: string;
  /** Parsed reply, present when jsonSchema was given. */
  json?: unknown;
  route: Route;
  /** The model that answered (KevaOS reports the one its gateway used). */
  model: string;
  /** Token usage of the Anthropic-direct path; zero when KevaOS served the call (it logs its own). */
  usage: AiUsage;
}

export type Route = 'kevaos' | 'openrouter' | 'anthropic';

export class AiRouterError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

interface Attempt {
  ok: boolean;
  status: number;
  text?: string;
  json?: unknown;
  model: string;
  usage: AiUsage;
  requestId?: string | null;
  error?: string;
  /** Provider-reported cost (OpenRouter returns it with usage.include). */
  costUsd?: number;
}

const ZERO_USAGE: AiUsage = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 };

/** Strip a ```json fence if the model wrapped its JSON in one, then parse. Throws on bad JSON. */
export function parseJsonReply(text: string): unknown {
  const t = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  return JSON.parse(t);
}

export function estimateCost(model: ClaudeModel, u: AiUsage): number {
  const p = PRICE[model];
  const usd = (u.inputTokens * p.input + u.outputTokens * p.output +
    u.cacheReadTokens * p.cacheRead + u.cacheWriteTokens * p.cacheWrite) / 1_000_000;
  return Math.round(usd * 1e6) / 1e6;
}

export function buildAnthropicBody(req: AiRequest): Record<string, unknown> {
  const body: Record<string, unknown> = {
    model: req.model,
    max_tokens: req.maxTokens,
    messages: req.messages,
  };
  if (req.system && req.system.length > 0) {
    body.system = req.system.map((s) =>
      s.cache ? { type: 'text', text: s.text, cache_control: { type: 'ephemeral' } } : { type: 'text', text: s.text }
    );
  }
  if (req.jsonSchema) body.output_config = { format: { type: 'json_schema', schema: req.jsonSchema.schema } };
  return body;
}

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : 0;
}

/** The structured-output contract, stated in the prompt for the KevaOS path (its gateway returns text). */
export function jsonInstruction(schema: Record<string, unknown>): string {
  return 'Respond with ONLY a JSON object -- no prose, no markdown, no code fences -- that matches this JSON Schema exactly:\n' +
    JSON.stringify(schema);
}

/** The KevaOS request body. System parts are joined; the schema contract is appended to them. */
export function buildKevaosBody(req: AiRequest): Record<string, unknown> {
  const parts = (req.system || []).map((s) => s.text);
  if (req.jsonSchema) parts.push(jsonInstruction(req.jsonSchema.schema));
  const body: Record<string, unknown> = {
    flow: req.kevaosFlow,
    messages: req.messages,
    max_tokens: req.maxTokens,
  };
  if (parts.length > 0) body.system = parts.join('\n\n');
  if (req.actorId) body.actor_id = req.actorId;
  return body;
}

async function callKevaos(req: AiRequest, key: string, url: string): Promise<Attempt> {
  let res: Response;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + key },
      body: JSON.stringify(buildKevaosBody(req)),
      signal: AbortSignal.timeout(KEVAOS_TIMEOUT_MS),
    });
  } catch (e) {
    return { ok: false, status: 0, model: 'kevaos', usage: { ...ZERO_USAGE }, error: 'fetch: ' + (e as Error).message };
  }
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    return { ok: false, status: res.status, model: 'kevaos', usage: { ...ZERO_USAGE }, error: detail.slice(0, 300) };
  }
  let data: Record<string, unknown>;
  try {
    data = await res.json();
  } catch {
    return { ok: false, status: res.status, model: 'kevaos', usage: { ...ZERO_USAGE }, error: 'non-JSON response' };
  }
  const text = typeof data.text === 'string' ? data.text : '';
  const model = typeof data.model === 'string' && data.model ? data.model : 'kevaos';
  if (!text) return { ok: false, status: 200, model, usage: { ...ZERO_USAGE }, error: 'empty reply' };
  const attempt: Attempt = { ok: true, status: 200, text, model, usage: { ...ZERO_USAGE } };
  if (req.jsonSchema) {
    try {
      attempt.json = parseJsonReply(text);
    } catch {
      return { ...attempt, ok: false, error: 'reply was not valid JSON' };
    }
  }
  return attempt;
}

async function callAnthropic(req: AiRequest, key: string): Promise<Attempt> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'x-api-key': key,
    'anthropic-version': '2023-06-01',
  };
  // Raw HTTP needs the structured-outputs flag sent by hand (the SDKs add it).
  if (req.jsonSchema) headers['anthropic-beta'] = 'structured-outputs-2025-11-13';
  let res: Response;
  try {
    res = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify(buildAnthropicBody(req)),
      signal: AbortSignal.timeout(ANTHROPIC_TIMEOUT_MS),
    });
  } catch (e) {
    return { ok: false, status: 0, model: req.model, usage: { ...ZERO_USAGE }, error: 'fetch: ' + (e as Error).message };
  }
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    return { ok: false, status: res.status, model: req.model, usage: { ...ZERO_USAGE }, error: detail.slice(0, 300) };
  }
  let data: Record<string, unknown>;
  try {
    data = await res.json();
  } catch {
    return { ok: false, status: res.status, model: req.model, usage: { ...ZERO_USAGE }, error: 'non-JSON response' };
  }
  const u = (data.usage || {}) as Record<string, unknown>;
  const usage: AiUsage = {
    inputTokens: num(u.input_tokens),
    outputTokens: num(u.output_tokens),
    cacheReadTokens: num(u.cache_read_input_tokens),
    cacheWriteTokens: num(u.cache_creation_input_tokens),
  };
  let text = '';
  if (Array.isArray(data.content)) {
    for (const b of data.content as Array<{ type?: string; text?: string }>) {
      if (b && b.type === 'text' && typeof b.text === 'string') text += b.text;
    }
  }
  const attempt: Attempt = { ok: true, status: 200, text, model: req.model, usage, requestId: (data.id as string) || null };
  if (req.jsonSchema) {
    try {
      attempt.json = parseJsonReply(text);
    } catch {
      return { ...attempt, ok: false, error: 'reply was not valid JSON' };
    }
  }
  return attempt;
}

/** One Anthropic-style content block in OpenRouter's (OpenAI chat) shape. */
function toOpenRouterPart(b: ContentBlock): Record<string, unknown> {
  if (b.type === 'image') {
    return { type: 'image_url', image_url: { url: 'data:' + b.source.media_type + ';base64,' + b.source.data } };
  }
  return { type: 'text', text: b.text };
}

/**
 * The OpenRouter request body. System parts become one system message whose
 * cached part carries cache_control (OpenRouter passes it through to Anthropic,
 * so the long catalog prefix is still prompt-cached). Structured output uses
 * response_format json_schema; require_parameters keeps the request off any
 * provider that cannot honour it, and data_collection 'deny' matches KevaOS.
 */
export function buildOpenRouterBody(req: AiRequest): Record<string, unknown> {
  const messages: Array<Record<string, unknown>> = [];
  if (req.system && req.system.length > 0) {
    messages.push({
      role: 'system',
      content: req.system.map((s) =>
        s.cache ? { type: 'text', text: s.text, cache_control: { type: 'ephemeral' } } : { type: 'text', text: s.text }
      ),
    });
  }
  for (const m of req.messages) {
    messages.push({
      role: m.role,
      content: typeof m.content === 'string' ? m.content : m.content.map(toOpenRouterPart),
    });
  }
  const body: Record<string, unknown> = {
    model: OPENROUTER_MODEL[req.model],
    max_tokens: req.maxTokens,
    messages,
    provider: { data_collection: 'deny', require_parameters: !!req.jsonSchema },
    usage: { include: true },
  };
  if (req.jsonSchema) {
    body.response_format = {
      type: 'json_schema',
      json_schema: { name: req.jsonSchema.name, strict: true, schema: req.jsonSchema.schema },
    };
  }
  return body;
}

async function callOpenRouter(req: AiRequest, key: string): Promise<Attempt> {
  const model = OPENROUTER_MODEL[req.model];
  let res: Response;
  try {
    res = await fetch(OPENROUTER_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + key,
        'HTTP-Referer': 'https://adityapurandare1.github.io/Counting-App/',
        'X-Title': 'kOunt counting',
      },
      body: JSON.stringify(buildOpenRouterBody(req)),
      signal: AbortSignal.timeout(OPENROUTER_TIMEOUT_MS),
    });
  } catch (e) {
    return { ok: false, status: 0, model, usage: { ...ZERO_USAGE }, error: 'fetch: ' + (e as Error).message };
  }
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    return { ok: false, status: res.status, model, usage: { ...ZERO_USAGE }, error: detail.slice(0, 300) };
  }
  let data: Record<string, unknown>;
  try {
    data = await res.json();
  } catch {
    return { ok: false, status: res.status, model, usage: { ...ZERO_USAGE }, error: 'non-JSON response' };
  }
  // OpenRouter can answer 200 with an error object (e.g. a provider failure mid-stream).
  if (data.error) {
    const err = data.error as Record<string, unknown>;
    return { ok: false, status: num(err.code) || 502, model, usage: { ...ZERO_USAGE }, error: String(err.message || 'error').slice(0, 300) };
  }
  const u = (data.usage || {}) as Record<string, unknown>;
  const details = (u.prompt_tokens_details || {}) as Record<string, unknown>;
  const cached = num(details.cached_tokens);
  const usage: AiUsage = {
    // prompt_tokens includes the cached part; keep the two apart like the Anthropic path.
    inputTokens: Math.max(0, num(u.prompt_tokens) - cached),
    outputTokens: num(u.completion_tokens),
    cacheReadTokens: cached,
    cacheWriteTokens: num(details.cache_write_tokens),
  };
  const choices = Array.isArray(data.choices) ? data.choices as Array<Record<string, unknown>> : [];
  const msg = (choices[0]?.message || {}) as Record<string, unknown>;
  let text = '';
  if (typeof msg.content === 'string') text = msg.content;
  else if (Array.isArray(msg.content)) {
    for (const p of msg.content as Array<{ type?: string; text?: string }>) {
      if (p && p.type === 'text' && typeof p.text === 'string') text += p.text;
    }
  }
  const answeredBy = typeof data.model === 'string' && data.model ? data.model : model;
  if (!text) return { ok: false, status: 200, model: answeredBy, usage, error: 'empty reply' };
  const cost = Number(u.cost);
  const attempt: Attempt = {
    ok: true, status: 200, text, model: answeredBy, usage,
    requestId: (data.id as string) || null,
    costUsd: Number.isFinite(cost) && cost >= 0 ? cost : undefined,
  };
  if (req.jsonSchema) {
    try {
      attempt.json = parseJsonReply(text);
    } catch {
      return { ...attempt, ok: false, error: 'reply was not valid JSON' };
    }
  }
  return attempt;
}

/** Business date as KevaOS buckets it: before 5 AM UTC-shifted counts as the previous day. */
function businessDate(d = new Date()): string {
  return new Date(d.getTime() - 5 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

/** Fire-and-forget usage row. Never throws into the caller. */
function logAttempt(req: AiRequest, route: Route, a: Attempt, latencyMs: number, extra: Record<string, unknown>) {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return;
  const costUsd = route === 'anthropic' ? estimateCost(req.model, a.usage)
    : route === 'openrouter' ? (a.costUsd ?? estimateCost(req.model, a.usage)) : 0;
  const row = {
    business_date: businessDate(),
    actor_id: req.actorId ?? null,
    actor_type: 'manual',
    // The table's CHECK allows anthropic/openai/other; a failed KevaOS hop is
    // 'other' with the route in metadata, as KevaOS logs non-listed providers.
    provider: route === 'anthropic' ? 'anthropic' : 'other',
    model: a.model,
    flow_name: req.flow,
    module: 'counting',
    input_tokens: a.usage.inputTokens,
    output_tokens: a.usage.outputTokens,
    cache_read_tokens: a.usage.cacheReadTokens,
    cache_write_tokens: a.usage.cacheWriteTokens,
    unit_type: 'tokens',
    cost_usd: costUsd,
    latency_ms: latencyMs,
    status: a.ok ? 'ok' : (a.status === 0 && /timeout|abort/i.test(a.error || '') ? 'timeout' : 'error'),
    error_type: a.ok ? null : (a.status ? 'http_' + a.status : (a.error || 'error').slice(0, 60)),
    request_id: a.requestId ?? null,
    metadata: { app: 'counting', provider: route, ...(req.metadata || {}), ...extra },
  };
  const p = (async () => {
    try {
      const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
      const { error } = await sb.from('platform_ai_usage_events').insert(row);
      if (error) console.warn('[ai-router] usage log failed:', error.message);
    } catch (e) {
      console.warn('[ai-router] usage log failed:', (e as Error).message);
    }
  })();
  try {
    if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(p);
  } catch { /* the promise still runs */ }
}

/**
 * Run one Claude request: KevaOS's central AI connection first, then OpenRouter
 * direct, then Anthropic direct -- each tried only when its secret is set, and
 * the next one on any failure. Throws AiRouterError (with the last upstream
 * status) only when every configured path fails.
 */
export async function routeClaude(req: AiRequest): Promise<AiResult> {
  const kvKey = (Deno.env.get('KEVAOS_COUNTING_AI_KEY') || '').trim();
  const kvUrl = (Deno.env.get('KEVAOS_AI_URL') || '').trim() || KEVAOS_DEFAULT_URL;
  const orKey = (Deno.env.get('OPENROUTER_API_KEY') || '').trim();
  const anKey = (Deno.env.get('ANTHROPIC_API_KEY') || '').trim();
  if (!kvKey && !orKey && !anKey) {
    throw new AiRouterError('No AI configured in Edge Function secrets (KEVAOS_COUNTING_AI_KEY, OPENROUTER_API_KEY or ANTHROPIC_API_KEY)', 500);
  }

  let fellBackFrom: string | null = null;
  let lastStatus = 502;
  if (kvKey) {
    const t0 = Date.now();
    const a = await callKevaos(req, kvKey, kvUrl);
    if (a.ok) {
      // KevaOS's gateway logged this call; logging it here would count it twice.
      return { text: a.text || '', json: a.json, route: 'kevaos', model: a.model, usage: a.usage };
    }
    logAttempt(req, 'kevaos', a, Date.now() - t0, {});
    console.warn('[ai-router] kevaos failed, falling back:', a.status, a.error);
    fellBackFrom = 'kevaos ' + (a.status || 'network') + ': ' + (a.error || '').slice(0, 120);
    lastStatus = a.status || 502;
  }

  if (orKey) {
    const t0 = Date.now();
    const o = await callOpenRouter(req, orKey);
    logAttempt(req, 'openrouter', o, Date.now() - t0, fellBackFrom ? { fell_back_from: fellBackFrom } : {});
    if (o.ok) {
      return { text: o.text || '', json: o.json, route: 'openrouter', model: o.model, usage: o.usage };
    }
    console.warn('[ai-router] openrouter failed, falling back:', o.status, o.error);
    fellBackFrom = 'openrouter ' + (o.status || 'network') + ': ' + (o.error || '').slice(0, 120);
    lastStatus = o.status || 502;
  }

  if (!anKey) throw new AiRouterError('AI request failed', lastStatus);

  const t0 = Date.now();
  const b = await callAnthropic(req, anKey);
  logAttempt(req, 'anthropic', b, Date.now() - t0, fellBackFrom ? { fell_back_from: fellBackFrom } : {});
  if (!b.ok) {
    console.error('[ai-router] anthropic failed:', b.status, b.error);
    throw new AiRouterError('AI request failed', b.status || 502);
  }
  return { text: b.text || '', json: b.json, route: 'anthropic', model: b.model, usage: b.usage };
}
