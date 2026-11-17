// Run: npx deno test --allow-env supabase/functions/_shared/ai-router.test.ts
// The network is mocked; SUPABASE_URL is unset so no usage row is written.

import { AiRouterError, buildOpenRouterBody, hasDocument, parseJsonReply, routeClaude } from './ai-router.ts';

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
const anOk = (text: string) => () =>
  json({ id: 'msg_1', content: [{ type: 'text', text }], usage: { input_tokens: 200, output_tokens: 40, cache_read_input_tokens: 1000 } });

const chat = {
  flow: 'counting-ask-ai', kevaosFlow: 'ask' as const, model: 'claude-sonnet-4-6' as const, maxTokens: 100,
  messages: [{ role: 'user' as const, content: 'hi' }],
};
const schema = { name: 'x', schema: { type: 'object', properties: { a: { type: 'string' } }, required: ['a'], additionalProperties: false } };

const orOk = (text: string, usage: Record<string, unknown> = { prompt_tokens: 1200, completion_tokens: 50, prompt_tokens_details: { cached_tokens: 1000 }, cost: 0.0021 }) => () =>
  json({ id: 'gen-1', model: 'anthropic/claude-sonnet-4.6', choices: [{ message: { role: 'assistant', content: text } }], usage });

Deno.test('parseJsonReply', () => {
  eq(parseJsonReply(' {"x":1} '), { x: 1 }, 'plain');
  eq(parseJsonReply('```json\n{"x":2}\n```'), { x: 2 }, 'fenced');
});
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

// ---- OpenRouter only (the user, 11/17: "I want all the key usage to be open router only") ----

async function fails(req: Parameters<typeof routeClaude>[0]): Promise<AiRouterError> {
  let err: unknown;
  try { await routeClaude(req); } catch (e) { err = e; }
  assert(err instanceof AiRouterError, 'an AiRouterError');
  return err as AiRouterError;
}

Deno.test('every key set (KevaOS, OpenRouter, Anthropic): only OpenRouter is called', async () => {
  setKeys('kv', 'sk-ant-x', null, 'sk-or-x');
  const calls = mockFetch({ openrouter: orOk('hello') });
  try {
    eq((await routeClaude(chat)).route, 'openrouter', 'route');
    eq(calls.map((c) => new URL(c.url).hostname), ['openrouter.ai'], 'one call, to OpenRouter');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter 402 (no credit): the call fails - the Anthropic key is never used', async () => {
  setKeys('kv', 'sk-ant-x', null, 'sk-or-x');
  const calls = mockFetch({ openrouter: () => json({ error: { code: 402, message: 'Insufficient credits' } }, 402) });
  try {
    eq((await fails(chat)).status, 402, 'status');
    eq(calls.length, 1, 'no second call');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('OpenRouter 200 carrying an error object, or non-JSON for a schema: a failure, no fallback', async () => {
  setKeys(null, 'sk-ant-x', null, 'sk-or-x');
  let calls = mockFetch({ openrouter: () => json({ error: { code: 503, message: 'provider down' } }) });
  try { eq((await fails(chat)).status, 503, 'error object'); eq(calls.length, 1, 'one call'); } finally { globalThis.fetch = realFetch; }
  calls = mockFetch({ openrouter: orOk('Sure! A Reposado.') });
  try { await fails({ ...chat, jsonSchema: schema }); eq(calls.length, 1, 'one call'); } finally { globalThis.fetch = realFetch; }
});

Deno.test('no OpenRouter key: 500, even with the Anthropic and KevaOS keys set', async () => {
  setKeys('kv', 'sk-ant-x', null, null);
  const calls = mockFetch({});
  try {
    const e = await fails(chat);
    eq(e.status, 500, 'status');
    assert(/OPENROUTER_API_KEY/.test(e.message), 'says which key');
    eq(calls.length, 0, 'nothing called');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('a PDF (the purchase-document reader) goes to OpenRouter too', async () => {
  setKeys('kv', 'sk-ant-x', null, 'sk-or-x');
  const calls = mockFetch({ openrouter: orOk('{"a":"z"}') });
  try {
    eq((await routeClaude(pdfReq)).json, { a: 'z' }, 'parsed');
    eq(calls.map((c) => new URL(c.url).hostname), ['openrouter.ai'], 'OpenRouter only');
  } finally { globalThis.fetch = realFetch; }
});

Deno.test('the router has no Anthropic or KevaOS path left', async () => {
  const src = await Deno.readTextFile(new URL('./ai-router.ts', import.meta.url));
  const code = src.split('// Every call is logged')[1];
  for (const t of ['ANTHROPIC_API_KEY', 'api.anthropic.com', 'KEVAOS_COUNTING_AI_KEY', 'x-api-key']) assert(!code.includes(t), t);
});
