// Run: npx deno test --allow-env supabase/functions/_shared/ai-router.test.ts
// The network is mocked; SUPABASE_URL is unset so no usage row is written.

import { AiRouterError, buildOpenRouterBody, openRouterUsage, parseJsonReply, routeClaude, toOpenRouterContent } from './ai-router.ts';

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error('assertion failed: ' + msg);
}
function eq(a: unknown, b: unknown, msg: string) {
  const sa = JSON.stringify(a), sb = JSON.stringify(b);
  if (sa !== sb) throw new Error(msg + '\n  got:      ' + sa + '\n  expected: ' + sb);
}

type Call = { url: string; body: Record<string, unknown>; headers: Record<string, string> };
const realFetch = globalThis.fetch;

function mockFetch(handlers: { openrouter?: () => Response; anthropic?: () => Response }): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, body: JSON.parse(String(init?.body || '{}')), headers: (init?.headers || {}) as Record<string, string> });
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

function setKeys(or: string | null, an: string | null) {
  if (or === null) Deno.env.delete('OPENROUTER_API_KEY'); else Deno.env.set('OPENROUTER_API_KEY', or);
  if (an === null) Deno.env.delete('ANTHROPIC_API_KEY'); else Deno.env.set('ANTHROPIC_API_KEY', an);
  Deno.env.delete('SUPABASE_URL');
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const orOk = (content: string) => () =>
  json({
    id: 'gen-1',
    choices: [{ message: { role: 'assistant', content } }],
    usage: { prompt_tokens: 1200, completion_tokens: 40, prompt_tokens_details: { cached_tokens: 1000 }, cost: 0.0021 },
  });
const anOk = (text: string) => () =>
  json({ id: 'msg_1', content: [{ type: 'text', text }], usage: { input_tokens: 200, output_tokens: 40, cache_read_input_tokens: 1000 } });

const chat = {
  flow: 'test', model: 'claude-haiku-4-5' as const, maxTokens: 100,
  messages: [{ role: 'user' as const, content: 'hi' }],
};
const schema = { name: 'x', schema: { type: 'object', properties: { a: { type: 'string' } }, required: ['a'], additionalProperties: false } };

Deno.test('no OpenRouter key: goes straight to Anthropic (today\'s behaviour)', async () => {
  setKeys(null, 'an');
  const calls = mockFetch({ anthropic: anOk('hello') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'anthropic', 'route');
    eq(r.text, 'hello', 'text');
    eq(calls.length, 1, 'one call');
    eq(calls[0].body.model, 'claude-haiku-4-5', 'anthropic model id');
    eq(calls[0].headers['x-api-key'], 'an', 'anthropic key header');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter first, with KevaOS policy: pinned model, data_collection deny, cache_control', async () => {
  setKeys('or', 'an');
  const calls = mockFetch({ openrouter: orOk('hello') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'openrouter', 'route');
    eq(r.text, 'hello', 'text');
    eq(calls.length, 1, 'no fallback call');
    const b = calls[0].body;
    eq(b.model, 'anthropic/claude-haiku-4.5', 'pinned OpenRouter model');
    eq((b.provider as Record<string, unknown>).data_collection, 'deny', 'data_collection deny');
    eq(b.cache_control, { type: 'ephemeral' }, 'top-level cache_control when no part breakpoint');
    eq(calls[0].headers.Authorization, 'Bearer or', 'OpenRouter bearer');
    eq(r.costUsd, 0.0021, 'reported cost used');
    eq(r.usage, { inputTokens: 200, outputTokens: 40, cacheReadTokens: 1000, cacheWriteTokens: 0 }, 'usage split');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter 5xx: falls back to Anthropic', async () => {
  setKeys('or', 'an');
  const calls = mockFetch({ openrouter: () => json({ error: { message: 'down' } }, 503), anthropic: anOk('from anthropic') });
  try {
    const r = await routeClaude(chat);
    eq(r.route, 'anthropic', 'route');
    eq(r.text, 'from anthropic', 'text');
    eq(calls.map((c) => c.url.includes('openrouter') ? 'or' : 'an'), ['or', 'an'], 'order');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter 200 with an error inside the choice: falls back', async () => {
  setKeys('or', 'an');
  mockFetch({ openrouter: () => json({ choices: [{ error: { code: 502 }, message: { content: '' } }] }), anthropic: anOk('ok') });
  try {
    eq((await routeClaude(chat)).route, 'anthropic', 'route');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('structured output: OpenRouter non-JSON reply falls back; Anthropic JSON parsed', async () => {
  setKeys('or', 'an');
  const calls = mockFetch({ openrouter: orOk('Sure! Here it is'), anthropic: anOk('{"a":"b"}') });
  try {
    const r = await routeClaude({ ...chat, jsonSchema: schema });
    eq(r.route, 'anthropic', 'route');
    eq(r.json, { a: 'b' }, 'parsed json');
    const ob = calls[0].body;
    eq((ob.response_format as Record<string, unknown>).type, 'json_schema', 'response_format sent');
    eq((ob.provider as Record<string, unknown>).require_parameters, true, 'require_parameters with schema');
    eq((calls[1].body.output_config as Record<string, unknown>).format, { type: 'json_schema', schema: schema.schema }, 'anthropic output_config');
    eq(calls[1].headers['anthropic-beta'], 'structured-outputs-2025-11-13', 'beta header');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('structured output via OpenRouter, fenced JSON accepted', async () => {
  setKeys('or', 'an');
  mockFetch({ openrouter: orOk('```json\n{"a":"z"}\n```') });
  try {
    const r = await routeClaude({ ...chat, jsonSchema: schema });
    eq(r.route, 'openrouter', 'route');
    eq(r.json, { a: 'z' }, 'parsed');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('both fail: AiRouterError carries the last upstream status', async () => {
  setKeys('or', 'an');
  mockFetch({ openrouter: () => json({}, 502), anthropic: () => json({ error: {} }, 429) });
  try {
    let err: unknown;
    try { await routeClaude(chat); } catch (e) { err = e; }
    assert(err instanceof AiRouterError, 'AiRouterError thrown');
    eq((err as AiRouterError).status, 429, 'status');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter only (no Anthropic key) and it fails: error, no Anthropic call', async () => {
  setKeys('or', null);
  const calls = mockFetch({ openrouter: () => json({}, 500) });
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

Deno.test('photo request: image -> image_url data URL, breakpoint kept on the catalog, no top-level cache', () => {
  const b = buildOpenRouterBody({
    flow: 'p', model: 'claude-sonnet-4-6', maxTokens: 10,
    system: [{ text: 'SYS' }, { text: 'CATALOG', cache: true }],
    messages: [{ role: 'user', content: [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAAA' } },
      { type: 'text', text: 'go' },
    ] }],
  })!;
  eq(b.model, 'anthropic/claude-sonnet-4.6', 'sonnet pinned');
  eq(b.cache_control, undefined, 'no top-level breakpoint');
  const msgs = b.messages as Array<{ role: string; content: unknown }>;
  eq(msgs[0], { role: 'system', content: [{ type: 'text', text: 'SYS' }, { type: 'text', text: 'CATALOG', cache_control: { type: 'ephemeral' } }] }, 'system parts');
  eq(msgs[1].content, [{ type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } }, { type: 'text', text: 'go' }], 'image translated');
});

Deno.test('untranslatable block -> null (router then goes to Anthropic)', () => {
  eq(toOpenRouterContent([{ type: 'document' } as never]), null, 'null');
});

Deno.test('helpers', () => {
  eq(parseJsonReply(' {"x":1} '), { x: 1 }, 'plain');
  eq(openRouterUsage({ prompt_tokens: 50, completion_tokens: 5, prompt_tokens_details: { cached_tokens: 10, cache_write_tokens: 30 } }),
    { inputTokens: 10, outputTokens: 5, cacheReadTokens: 10, cacheWriteTokens: 30 }, 'usage');
  eq(openRouterUsage(undefined), { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 }, 'none');
});
