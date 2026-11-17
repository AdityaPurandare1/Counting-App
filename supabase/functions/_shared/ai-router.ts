// supabase/functions/_shared/ai-router.ts
//
// One AI path for the counting apps: OPENROUTER ONLY.
//
// The user, 2026-11-17: "can we please check if any of the process is falling into claude API key ? I want all
// the key usage to be open router only." Until then a call went KevaOS's gateway (when KEVAOS_COUNTING_AI_KEY was
// set; its own fallback is KevaOS's Anthropic key), then OpenRouter, then Anthropic direct with ANTHROPIC_API_KEY.
// The 30 days before showed 63 photo-label calls falling from OpenRouter (402 no credit, 401) to the Anthropic key
// (all 401). Now every call goes to OpenRouter with the key in this project's Edge Function secrets
// (OPENROUTER_API_KEY): Claude models by OpenRouter's ids, structured output via response_format json_schema,
// provider.data_collection = 'deny'. When OpenRouter fails the call fails (AiRouterError with its status) -- the
// callers already cope (photo labels fall back to on-device OCR). Nothing here reads ANTHROPIC_API_KEY.
//
// Every call is logged to platform_ai_usage_events (module 'counting', metadata.provider 'openrouter').

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

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


export type ClaudeModel = 'claude-sonnet-4-6' | 'claude-haiku-4-5' | 'claude-opus-5-5';

const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';

// The same models, by OpenRouter's ids (both take images and structured output).
const OPENROUTER_MODEL: Record<ClaudeModel, string> = {
  'claude-sonnet-4-6': 'anthropic/claude-sonnet-4.6',
  'claude-haiku-4-5': 'anthropic/claude-haiku-4.5',
  'claude-opus-5-5': 'anthropic/claude-opus-5.5',
};

// $ per million tokens, for the Anthropic-direct usage rows (Anthropic does not report cost).
const PRICE: Record<ClaudeModel, { input: number; output: number; cacheRead: number; cacheWrite: number }> = {
  'claude-sonnet-4-6': { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  'claude-haiku-4-5': { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 },
  'claude-opus-5-5': { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5 },
};

const OPENROUTER_TIMEOUT_MS = 50_000;

export type TextBlock = { type: 'text'; text: string };
export type ImageBlock = { type: 'image'; source: { type: 'base64'; media_type: string; data: string } };
/** A PDF, read natively by Claude. KevaOS's counting gateway does not take
 *  documents, so a request carrying one skips straight to OpenRouter. */
export type DocumentBlock = { type: 'document'; source: { type: 'base64'; media_type: 'application/pdf'; data: string }; title?: string };
export type ContentBlock = TextBlock | ImageBlock | DocumentBlock;
export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string | ContentBlock[];
}

export interface AiRequest {
  /** Stable code-path name, logged as flow_name (e.g. 'counting-photo-label'). */
  flow: string;
  /** Which KevaOS counting flow this was (kept for the callers; unused since the router is OpenRouter only). */
  kevaosFlow?: 'photo-label' | 'ask';
  /** The Claude model, sent to OpenRouter by its id (OPENROUTER_MODEL). */
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
  /** The model that answered (as OpenRouter reports it). */
  model: string;
  /** Token usage as OpenRouter reports it. */
  usage: AiUsage;
}

export type Route = 'openrouter';

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

/** True when any message carries a PDF document block. */
export function hasDocument(req: AiRequest): boolean {
  return req.messages.some((m) => Array.isArray(m.content) && m.content.some((b) => b.type === 'document'));
}

function num(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : 0;
}

function toOpenRouterPart(b: ContentBlock): Record<string, unknown> {
  if (b.type === 'image') {
    return { type: 'image_url', image_url: { url: 'data:' + b.source.media_type + ';base64,' + b.source.data } };
  }
  if (b.type === 'document') {
    return { type: 'file', file: { filename: b.title || 'document.pdf', file_data: 'data:application/pdf;base64,' + b.source.data } };
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
  const key = NEW_SECRET_KEY();
  if (!url || !key) return;
  const costUsd = a.costUsd ?? estimateCost(req.model, a.usage);
  const row = {
    business_date: businessDate(),
    actor_id: req.actorId ?? null,
    actor_type: 'manual',
    // The table's CHECK allows anthropic/openai/other: OpenRouter is 'other', the route in metadata.
    provider: 'other',
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
 * Run one Claude request on OpenRouter (the only path, 11/17). Throws AiRouterError with OpenRouter's status when
 * it fails or the key is not set.
 */
export async function routeClaude(req: AiRequest): Promise<AiResult> {
  const orKey = (Deno.env.get('OPENROUTER_API_KEY') || '').trim();
  if (!orKey) throw new AiRouterError('No AI configured: OPENROUTER_API_KEY is not set in the Edge Function secrets', 500);
  const t0 = Date.now();
  const o = await callOpenRouter(req, orKey);
  logAttempt(req, 'openrouter', o, Date.now() - t0, {});
  if (!o.ok) {
    console.error('[ai-router] openrouter failed:', o.status, o.error);
    throw new AiRouterError('AI request failed', o.status || 502);
  }
  return { text: o.text || '', json: o.json, route: 'openrouter', model: o.model, usage: o.usage };
}
