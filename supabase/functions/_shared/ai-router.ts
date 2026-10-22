// supabase/functions/_shared/ai-router.ts
//
// One AI path for the counting apps, the same one KevaOS uses
// (Restaurant-App lib/ai/connection.ts + ai-sdk-provider.ts, owner rule
// 2026-10-19):
//
//   1. OpenRouter first, on a PINNED Claude model (never openrouter/auto), with
//        provider.data_collection = 'deny'  only providers that do not store or
//                                            train on our data
//        cache_control                      prompt caching for Claude models
//   2. Anthropic direct as the fallback -- when OPENROUTER_API_KEY is not set,
//      or the OpenRouter call fails, times out, or returns unusable output.
//   3. Every attempt writes a row to platform_ai_usage_events (the table KevaOS
//      logs to), so counting-app spend shows up next to KevaOS's.
//
// Keys live in Supabase Edge Function secrets, never on a device:
//
//   supabase secrets set OPENROUTER_API_KEY=...   (KevaOS's OpenRouter key)
//   supabase secrets set ANTHROPIC_API_KEY=...    (already set)
//
// Callers speak Anthropic's message shape (text + base64 image blocks); this
// module translates to OpenRouter's OpenAI-compatible shape when routing there.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

export type ClaudeModel = 'claude-sonnet-4-6' | 'claude-haiku-4-5';

const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';
const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';

const OPENROUTER_MODEL: Record<ClaudeModel, string> = {
  'claude-sonnet-4-6': 'anthropic/claude-sonnet-4.6',
  'claude-haiku-4-5': 'anthropic/claude-haiku-4.5',
};

// $ per million tokens. Only used when the provider does not report a cost
// (Anthropic direct never does; OpenRouter returns usage.cost).
const PRICE: Record<ClaudeModel, { input: number; output: number; cacheRead: number; cacheWrite: number }> = {
  'claude-sonnet-4-6': { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
  'claude-haiku-4-5': { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 },
};

// OpenRouter gets a shorter leash so a slow attempt still leaves time for the
// Anthropic fallback inside the Edge Function's wall clock.
const OPENROUTER_TIMEOUT_MS = 40_000;
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
  route: 'openrouter' | 'anthropic';
  model: string;
  usage: AiUsage;
  costUsd: number;
}

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
  costUsd?: number;
  requestId?: string | null;
  error?: string;
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

/** Anthropic content -> OpenRouter (OpenAI) content. Null when a block type has no translation. */
export function toOpenRouterContent(content: string | ContentBlock[]): string | unknown[] | null {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return null;
  const parts: unknown[] = [];
  for (const b of content) {
    if (b && b.type === 'text' && typeof b.text === 'string') {
      parts.push({ type: 'text', text: b.text });
    } else if (b && b.type === 'image' && b.source && b.source.type === 'base64') {
      parts.push({ type: 'image_url', image_url: { url: 'data:' + b.source.media_type + ';base64,' + b.source.data } });
    } else {
      return null;
    }
  }
  return parts;
}

/** The OpenRouter request body, with KevaOS's request policy applied. Null if the messages cannot be translated. */
export function buildOpenRouterBody(req: AiRequest): Record<string, unknown> | null {
  const messages: unknown[] = [];
  let partCache = false;
  if (req.system && req.system.length > 0) {
    messages.push({
      role: 'system',
      content: req.system.map((s) => {
        if (s.cache) partCache = true;
        return s.cache
          ? { type: 'text', text: s.text, cache_control: { type: 'ephemeral' } }
          : { type: 'text', text: s.text };
      }),
    });
  }
  for (const m of req.messages) {
    const content = toOpenRouterContent(m.content);
    if (content === null) return null;
    messages.push({ role: m.role, content });
  }
  const body: Record<string, unknown> = {
    model: OPENROUTER_MODEL[req.model],
    max_tokens: req.maxTokens,
    messages,
    // KevaOS policy: never route to a provider that stores or trains on prompts.
    // require_parameters keeps structured-output calls off providers that would
    // silently ignore response_format.
    provider: { data_collection: 'deny', ...(req.jsonSchema ? { require_parameters: true } : {}) },
    usage: { include: true },
  };
  // KevaOS adds a top-level breakpoint (cache the whole prompt). When the caller
  // marked its own breakpoint -- e.g. the catalog before a per-call photo -- that
  // one is kept alone, because caching through the photo would pay a cache write
  // on every call and never read it back.
  if (!partCache) body.cache_control = { type: 'ephemeral' };
  if (req.jsonSchema) {
    body.response_format = {
      type: 'json_schema',
      json_schema: { name: req.jsonSchema.name, strict: true, schema: req.jsonSchema.schema },
    };
  }
  return body;
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

/** OpenRouter reports prompt_tokens INCLUDING cached ones; split them so the log matches Anthropic's fields. */
export function openRouterUsage(u: Record<string, unknown> | undefined): AiUsage {
  if (!u) return { ...ZERO_USAGE };
  const d = (u.prompt_tokens_details || {}) as Record<string, unknown>;
  const cacheRead = num(d.cached_tokens);
  const cacheWrite = num(d.cache_write_tokens);
  return {
    inputTokens: Math.max(0, num(u.prompt_tokens) - cacheRead - cacheWrite),
    outputTokens: num(u.completion_tokens),
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
  };
}

async function callOpenRouter(req: AiRequest, key: string): Promise<Attempt> {
  const model = OPENROUTER_MODEL[req.model];
  const body = buildOpenRouterBody(req);
  if (!body) return { ok: false, status: 0, model, usage: { ...ZERO_USAGE }, error: 'untranslatable message content' };
  let res: Response;
  try {
    res = await fetch(OPENROUTER_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + key,
        // OpenRouter app attribution, as KevaOS sends.
        'HTTP-Referer': 'https://kevaos.ai',
        'X-Title': 'KevaOS Counting',
      },
      body: JSON.stringify(body),
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
  const usageRaw = data.usage as Record<string, unknown> | undefined;
  const usage = openRouterUsage(usageRaw);
  const costUsd = usageRaw && Number.isFinite(Number(usageRaw.cost)) ? Number(usageRaw.cost) : undefined;
  const choice = Array.isArray(data.choices) ? (data.choices[0] as Record<string, unknown>) : undefined;
  const msg = choice && (choice.message as Record<string, unknown>);
  // OpenRouter can return 200 with an error object inside the choice.
  if (choice && choice.error) {
    return { ok: false, status: 200, model, usage, costUsd, error: JSON.stringify(choice.error).slice(0, 300) };
  }
  const text = msg && typeof msg.content === 'string' ? msg.content : '';
  if (!text) return { ok: false, status: 200, model, usage, costUsd, error: 'empty reply' };
  const attempt: Attempt = { ok: true, status: 200, text, model, usage, costUsd, requestId: (data.id as string) || null };
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

/** Business date as KevaOS buckets it: before 5 AM UTC-shifted counts as the previous day. */
function businessDate(d = new Date()): string {
  return new Date(d.getTime() - 5 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

/** Fire-and-forget usage row. Never throws into the caller. */
function logAttempt(req: AiRequest, route: 'openrouter' | 'anthropic', a: Attempt, latencyMs: number, extra: Record<string, unknown>) {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return;
  const costUsd = a.costUsd ?? estimateCost(req.model, a.usage);
  const row = {
    business_date: businessDate(),
    actor_id: req.actorId ?? null,
    actor_type: 'manual',
    // The table's CHECK allows anthropic/openai/other; KevaOS logs OpenRouter as
    // 'other' with the real provider in metadata.
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
 * Run one Claude request: OpenRouter first, Anthropic direct on any failure.
 * Throws AiRouterError (with the last upstream status) only when both fail.
 */
export async function routeClaude(req: AiRequest): Promise<AiResult> {
  const orKey = (Deno.env.get('OPENROUTER_API_KEY') || '').trim();
  const anKey = (Deno.env.get('ANTHROPIC_API_KEY') || '').trim();
  if (!orKey && !anKey) throw new AiRouterError('No AI key set in Edge Function secrets (OPENROUTER_API_KEY or ANTHROPIC_API_KEY)', 500);

  let fellBackFrom: string | null = null;
  if (orKey) {
    const t0 = Date.now();
    const a = await callOpenRouter(req, orKey);
    logAttempt(req, 'openrouter', a, Date.now() - t0, {});
    if (a.ok) {
      return {
        text: a.text || '', json: a.json, route: 'openrouter', model: a.model, usage: a.usage,
        costUsd: a.costUsd ?? estimateCost(req.model, a.usage),
      };
    }
    console.warn('[ai-router] openrouter failed, falling back to anthropic:', a.status, a.error);
    fellBackFrom = 'openrouter ' + (a.status || 'network') + ': ' + (a.error || '').slice(0, 120);
    if (!anKey) throw new AiRouterError('AI request failed', a.status || 502);
  }

  const t0 = Date.now();
  const b = await callAnthropic(req, anKey);
  logAttempt(req, 'anthropic', b, Date.now() - t0, fellBackFrom ? { fell_back_from: fellBackFrom } : {});
  if (!b.ok) {
    console.error('[ai-router] anthropic failed:', b.status, b.error);
    throw new AiRouterError('AI request failed', b.status || 502);
  }
  return {
    text: b.text || '', json: b.json, route: 'anthropic', model: b.model, usage: b.usage,
    costUsd: estimateCost(req.model, b.usage),
  };
}
