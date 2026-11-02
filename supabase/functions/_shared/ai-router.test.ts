// Run: npx deno test --allow-env supabase/functions/_shared/ai-router.test.ts
// The network is mocked; SUPABASE_URL is unset so no usage row is written.

import { AiRouterError, buildAnthropicBody, buildKevaosBody, buildOpenRouterBody, hasDocument, jsonInstruction, parseJsonReply, routeClaude } from './ai-router.ts';

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error('assertion failed: ' + msg);
}
function eq(a: unknown, b: unknown, msg: string) {
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) throw new Error(msg + '\n  got:      ' + sa + '\n  expected: ' + sb);
}

type Call = { url: string; body: Record<string, unknown>; headers: Record<string, string> };
const realFetch = globalThis.fetch;
const KV_URL = 'https://kevaos.ai/api/external/counting/ai';

function mockFetch(handlers: { kevaos?: () => Response; openrouter?: () => Response; anthropic?: () => Response }): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, body: JSON.parse(String(init?.body || '{}')), headers: (init?.headers || {}) as Record<string, string> });
    if (url.includes('/api/external/counting/ai')) {
      if (!handlers.kevaos) throw new Error('unexpected KevaOS call');
      return Promise.resolve(handlers.kevaos());
    }
    if (url.includes('openrouter.ai')) {
      if (!handlers.openrouter) throw new Error('unexpected OpenRouter call');
      return Promise.resolve(handlers.openrouter());
    }
    if (url.includes('api.anthropic.com')) {
      if (!handlers.anthropic) throw new Error('unexpected Anthropic call');
      return Promise.resolve(handlers.anthropic());
    }
    throw new Error('unexpected fetch ' + url);
  }) as typeof fetch;
  return calls;
}

function setKeys(kv: string | null, an: string | null, url: string | null = null, or: string | null = null) {
  if (kv === null) Deno.env.delete('KEVAOS_COUNTING_AI_KEY'); else Deno.env.set('KEVAOS_COUNTING_AI_KEY', kv);
  if (or === null) Deno.env.delete('OPENROUTER_API_KEY'); else Deno.env.set('OPENROUTER_API_KEY', or);
  if (an === null) Deno.env.delete('ANTHROPIC_API_KEY'); else Deno.env.set('ANTHROPIC_API_KEY', an);
  if (url === null) Deno.env.delete('KEVAOS_AI_URL'); else Deno.env.set('KEVAOS_AI_URL', url);
  Deno.env.delete('SUPABASE_URL');
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const kvOk = (text: string) => () => json({ text, provider: 'openrouter', model: 'anthropic/claude-haiku-4.5' });
const anOk = (text: string) => () =>
  json({ id: 'msg_1', content: [{ type: 'text', text }], usage: { input_tokens: 200, output_tokens: 40, cache_read_input_tokens: 1000 } });

const chat = {
  flow: 'counting-ask-ai', kevaosFlow: 'ask' as const, model: 'claude-sonnet-4-6' as const, maxTokens: 100,
  messages: [{ role: 'user' as const, content: 'hi' }],
};
const schema = { name: 'x', schema: { type: 'object', properties: { a: { type: 'string' } }, required: ['a'], additionalProperties: false } };

Deno.test('no KevaOS key: goes straight to Anthropic (today\'s behaviour)', async () => {
  setKeys(null, 'an');
  const calls = mockFetch({ anthropic: anOk('hello') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'anthropic', 'route');
    eq(r.text, 'hello', 'text');
    eq(calls.length, 1, 'one call');
    eq(calls[0].body.model, 'claude-sonnet-4-6', 'anthropic model id');
    eq(calls[0].headers['x-api-key'], 'an', 'anthropic key header');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('KevaOS first: partner key as bearer, flow + messages forwarded, its model reported', async () => {
  setKeys('kva_live_x', 'an');
  const calls = mockFetch({ kevaos: kvOk('hello') });
  try {
    const r = await routeClaude({ ...chat, actorId: '11111111-1111-4111-8111-111111111111' });
    eq(r.route, 'kevaos', 'route');
    eq(r.text, 'hello', 'text');
    eq(r.model, 'anthropic/claude-haiku-4.5', 'model from KevaOS');
    eq(calls.length, 1, 'no fallback');
    eq(calls[0].url, KV_URL, 'default URL');
    eq(calls[0].headers.Authorization, 'Bearer kva_live_x', 'partner key bearer');
    eq(calls[0].body, { flow: 'ask', messages: chat.messages, max_tokens: 100, actor_id: '11111111-1111-4111-8111-111111111111' }, 'body');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('KEVAOS_AI_URL overrides the endpoint', async () => {
  setKeys('k', 'an', 'https://staging.example/api/external/counting/ai');
  const calls = mockFetch({ kevaos: kvOk('x') });
  try {
    await routeClaude(chat);
    eq(calls[0].url, 'https://staging.example/api/external/counting/ai', 'override');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('KevaOS 401 (proxy or key): falls back to Anthropic', async () => {
  setKeys('k', 'an');
  const calls = mockFetch({ kevaos: () => json({ error: 'Unauthorized' }, 401), anthropic: anOk('from anthropic') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'anthropic', 'route');
    eq(r.text, 'from anthropic', 'text');
    eq(calls.map((c) => c.url.includes('kevaos') ? 'kv' : 'an'), ['kv', 'an'], 'order');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('KevaOS network error: falls back', async () => {
  setKeys('k', 'an');
  let first = true;
  globalThis.fetch = ((input: RequestInfo | URL) => {
    if (first && String(input).includes('kevaos')) { first = false; return Promise.reject(new TypeError('connection reset')); }
    return Promise.resolve(anOk('ok')());
  }) as typeof fetch;
  try {
    eq((await routeClaude(chat)).route, 'anthropic', 'route');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('structured output: schema contract appended to the KevaOS system prompt, JSON parsed', async () => {
  setKeys('k', 'an');
  const calls = mockFetch({ kevaos: kvOk('```json\n{"a":"z"}\n```') });
  try {
    const r = await routeClaude({ ...chat, kevaosFlow: 'photo-label', system: [{ text: 'SYS' }, { text: 'CATALOG', cache: true }], jsonSchema: schema });
    eq(r.route, 'kevaos', 'route');
    eq(r.json, { a: 'z' }, 'parsed');
    eq(calls[0].body.flow, 'photo-label', 'flow');
    eq(calls[0].body.system, 'SYS\n\nCATALOG\n\n' + jsonInstruction(schema.schema), 'system joined + contract');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('structured output: non-JSON from KevaOS falls back to Anthropic native structured output', async () => {
  setKeys('k', 'an');
  const calls = mockFetch({ kevaos: kvOk('Sure! It is a Reposado.'), anthropic: anOk('{"a":"b"}') });
  try {
    const r = await routeClaude({ ...chat, jsonSchema: schema });
    eq(r.route, 'anthropic', 'route');
    eq(r.json, { a: 'b' }, 'parsed json');
    eq((calls[1].body.output_config as Record<string, unknown>).format, { type: 'json_schema', schema: schema.schema }, 'anthropic output_config');
    eq(calls[1].headers['anthropic-beta'], 'structured-outputs-2025-11-13', 'beta header');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('KevaOS empty reply: falls back', async () => {
  setKeys('k', 'an');
  mockFetch({ kevaos: () => json({ text: '' }), anthropic: anOk('ok') });
  try {
    eq((await routeClaude(chat)).route, 'anthropic', 'route');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('both fail: AiRouterError carries the last upstream status', async () => {
  setKeys('k', 'an');
  mockFetch({ kevaos: () => json({}, 502), anthropic: () => json({ error: {} }, 429) });
  try {
    let err: unknown;
    try { await routeClaude(chat); } catch (e) { err = e; }
    assert(err instanceof AiRouterError, 'AiRouterError thrown');
    eq((err as AiRouterError).status, 429, 'status');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('KevaOS only (no Anthropic key) and it fails: error, no Anthropic call', async () => {
  setKeys('k', null);
  const calls = mockFetch({ kevaos: () => json({}, 500) });
  try {
    let err: unknown;
    try { await routeClaude(chat); } catch (e) { err = e; }
    assert(err instanceof AiRouterError, 'error');
    eq(calls.length, 1, 'one call');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('no keys at all: 500', async () => {
  setKeys(null, null);
  let err: unknown;
  try { await routeClaude(chat); } catch (e) { err = e; }
  assert(err instanceof AiRouterError && err.status === 500, '500');
});

Deno.test('buildKevaosBody: images pass through in the Anthropic shape the KevaOS route accepts', () => {
  const content = [
    { type: 'image' as const, source: { type: 'base64' as const, media_type: 'image/png', data: 'AAAA' } },
    { type: 'text' as const, text: 'go' },
  ];
  const b = buildKevaosBody({ flow: 'p', kevaosFlow: 'photo-label', model: 'claude-sonnet-4-6', maxTokens: 10, messages: [{ role: 'user', content }] });
  eq(b, { flow: 'photo-label', messages: [{ role: 'user', content }], max_tokens: 10 }, 'no system, no actor');
});

Deno.test('parseJsonReply', () => {
  eq(parseJsonReply(' {"x":1} '), { x: 1 }, 'plain');
  eq(parseJsonReply('```json\n{"x":2}\n```'), { x: 2 }, 'fenced');
});

// ---- OpenRouter direct (OPENROUTER_API_KEY), added 2026-10-26 ----

const orOk = (text: string, usage: Record<string, unknown> = { prompt_tokens: 1200, completion_tokens: 50, prompt_tokens_details: { cached_tokens: 1000 }, cost: 0.0021 }) => () =>
  json({ id: 'gen-1', model: 'anthropic/claude-sonnet-4.6', choices: [{ message: { role: 'assistant', content: text } }], usage });

Deno.test('OpenRouter key only: bearer key, OpenRouter model id, data_collection deny, usage split', async () => {
  setKeys(null, null, null, 'sk-or-x');
  const calls = mockFetch({ openrouter: orOk('hello') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'openrouter', 'route');
    eq(r.text, 'hello', 'text');
    eq(r.model, 'anthropic/claude-sonnet-4.6', 'model reported');
    eq(r.usage, { inputTokens: 200, outputTokens: 50, cacheReadTokens: 1000, cacheWriteTokens: 0 }, 'cached part kept apart');
    eq(calls.length, 1, 'one call');
    eq(calls[0].headers.Authorization, 'Bearer sk-or-x', 'bearer');
    eq(calls[0].body.model, 'anthropic/claude-sonnet-4.6', 'model id');
    eq((calls[0].body.provider as Record<string, unknown>).data_collection, 'deny', 'no data collection');
    eq(calls[0].body.messages, [{ role: 'user', content: 'hi' }], 'messages');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter photo label: image as data URL, cached catalog part, json_schema, JSON parsed', async () => {
  setKeys(null, 'an', null, 'sk-or-x');
  const calls = mockFetch({ openrouter: orOk('{"a":"z"}') });
  const content = [
    { type: 'image' as const, source: { type: 'base64' as const, media_type: 'image/jpeg', data: 'AAAA' } },
    { type: 'text' as const, text: 'go' },
  ];
  try {
    const r = await routeClaude({ ...chat, model: 'claude-haiku-4-5', kevaosFlow: 'photo-label',
      system: [{ text: 'SYS' }, { text: 'CATALOG', cache: true }], jsonSchema: schema, messages: [{ role: 'user', content }] });
    eq(r.route, 'openrouter', 'route (no Anthropic call)');
    eq(r.json, { a: 'z' }, 'parsed');
    eq(calls.length, 1, 'one call');
    const b = calls[0].body;
    eq(b.model, 'anthropic/claude-haiku-4.5', 'haiku id');
    eq((b.messages as unknown[])[0], { role: 'system', content: [
      { type: 'text', text: 'SYS' }, { type: 'text', text: 'CATALOG', cache_control: { type: 'ephemeral' } }] }, 'system + cache breakpoint');
    eq((b.messages as unknown[])[1], { role: 'user', content: [
      { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,AAAA' } }, { type: 'text', text: 'go' }] }, 'image as data URL');
    eq(b.response_format, { type: 'json_schema', json_schema: { name: 'x', strict: true, schema: schema.schema } }, 'json_schema');
    eq((b.provider as Record<string, unknown>).require_parameters, true, 'only providers that honour the schema');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter 402 (no credit): falls back to Anthropic', async () => {
  setKeys(null, 'an', null, 'sk-or-x');
  const calls = mockFetch({ openrouter: () => json({ error: { code: 402, message: 'Insufficient credits' } }, 402), anthropic: anOk('from anthropic') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'anthropic', 'route');
    eq(calls.map((c) => c.url.includes('openrouter') ? 'or' : 'an'), ['or', 'an'], 'order');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter 200 carrying an error object: treated as a failure, falls back', async () => {
  setKeys(null, 'an', null, 'sk-or-x');
  mockFetch({ openrouter: () => json({ error: { code: 503, message: 'provider down' } }), anthropic: anOk('ok') });
  try {
    eq((await routeClaude(chat)).route, 'anthropic', 'route');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter non-JSON for a schema request: falls back to Anthropic', async () => {
  setKeys(null, 'an', null, 'sk-or-x');
  mockFetch({ openrouter: orOk('Sure! A Reposado.'), anthropic: anOk('{"a":"b"}') });
  try {
    const r = await routeClaude({ ...chat, jsonSchema: schema });
    eq(r.route, 'anthropic', 'route');
    eq(r.json, { a: 'b' }, 'parsed');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('order: KevaOS fails -> OpenRouter answers -> Anthropic never called', async () => {
  setKeys('k', 'an', null, 'sk-or-x');
  const calls = mockFetch({ kevaos: () => json({}, 500), openrouter: orOk('from openrouter') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'openrouter', 'route');
    eq(calls.map((c) => c.url.includes('kevaos') ? 'kv' : c.url.includes('openrouter') ? 'or' : 'an'), ['kv', 'or'], 'order');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter only and it fails: AiRouterError with its status, no Anthropic call', async () => {
  setKeys(null, null, null, 'sk-or-x');
  const calls = mockFetch({ openrouter: () => json({ error: { code: 402, message: 'x' } }, 402) });
  try {
    let err: unknown;
    try { await routeClaude(chat); } catch (e) { err = e; }
    assert(err instanceof AiRouterError, 'error');
    eq((err as AiRouterError).status, 402, 'status');
    eq(calls.length, 1, 'one call');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('buildOpenRouterBody: plain chat has no response_format and does not require parameters', () => {
  const b = buildOpenRouterBody({ ...chat });
  eq(b.response_format, undefined, 'no response_format');
  eq(b.provider, { data_collection: 'deny', require_parameters: false }, 'provider');
  eq(b.usage, { include: true }, 'cost reported');
});

// ---- PDF documents + Opus 5.5 (kount-read-purchase-doc), added 2026-11-02 ----

const pdfReq = {
  flow: 'kount-read-purchase-doc', kevaosFlow: 'ask' as const, model: 'claude-opus-5-5' as const, maxTokens: 100,
  messages: [{ role: 'user' as const, content: [
    { type: 'document' as const, source: { type: 'base64' as const, media_type: 'application/pdf' as const, data: 'JVBERi0x' }, title: 'INV-1.pdf' },
    { type: 'text' as const, text: 'read it' },
  ] }],
  jsonSchema: schema,
};

Deno.test('hasDocument: only true when a document block is present', () => {
  assert(hasDocument(pdfReq), 'pdf request');
  assert(!hasDocument(chat), 'plain chat');
});

Deno.test('document: OpenRouter gets a file part with a pdf data URL, on the Opus 5.5 id', () => {
  const b = buildOpenRouterBody(pdfReq);
  eq(b.model, 'anthropic/claude-opus-5.5', 'model id');
  const msg = (b.messages as Array<{ content: Array<Record<string, unknown>> }>)[0];
  eq(msg.content[0], { type: 'file', file: { filename: 'INV-1.pdf', file_data: 'data:application/pdf;base64,JVBERi0x' } }, 'file part');
  eq(msg.content[1], { type: 'text', text: 'read it' }, 'text kept');
});

Deno.test('document: Anthropic body keeps the native block, Opus 5.5 asks for the default fallback', () => {
  const b = buildAnthropicBody(pdfReq);
  eq((b.messages as Array<{ content: unknown[] }>)[0].content[0], pdfReq.messages[0].content[0], 'native document block');
  eq(b.fallbacks, 'default', 'fallbacks');
  eq(buildAnthropicBody(chat).fallbacks, undefined, 'no fallbacks for sonnet 4.6');
});

Deno.test('document: KevaOS is skipped even when configured; OpenRouter answers', async () => {
  setKeys('kv-key', 'an-key', null, 'or-key');
  const calls = mockFetch({ openrouter: orOk('{"a":"x"}') });
  try {
    const r = await routeClaude(pdfReq);
    eq(r.route, 'openrouter', 'route');
    eq(r.json, { a: 'x' }, 'json');
    assert(!calls.some((c) => c.url.includes('/api/external/counting/ai')), 'no KevaOS call');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('Opus 5.5 on Anthropic direct: both beta flags sent; a refusal is a failure, not an answer', async () => {
  setKeys(null, 'an-key');
  const calls = mockFetch({ anthropic: () => json({ id: 'msg_r', stop_reason: 'refusal', content: [{ type: 'text', text: '{"a":"nope"}' }], usage: {} }) });
  let err: unknown;
  try { await routeClaude(pdfReq); } catch (e) { err = e; } finally { globalThis.fetch = realFetch; }
  eq(calls[0].headers['anthropic-beta'], 'structured-outputs-2025-11-13,server-side-fallback-2026-07-01', 'betas');
  assert(err instanceof AiRouterError && err.status === 422, 'refusal surfaces as an error');
});

Deno.test('chat without a document still goes to KevaOS first', async () => {
  setKeys('kv-key', null);
  const calls = mockFetch({ kevaos: kvOk('hello') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'kevaos', 'route');
    assert(calls.length === 1, 'one call');
  } finally { globalThis.fetch = realFetch; }
});
