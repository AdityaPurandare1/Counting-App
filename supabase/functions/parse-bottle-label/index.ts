// supabase/functions/parse-bottle-label/index.ts
//
// Edge Function: take a bottle/label photo + a catalog snapshot, return
// structured JSON the mobile app can drop straight into the photo-entry form.
//
// Replaces the on-device Tesseract path AND the browser-side OpenAI path.
// The Anthropic key never leaves Supabase secrets — set it once via:
//
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//
// Why Sonnet 4.6: tradeoff chosen in favor of accuracy on harder labels
// (faded print, partial views, ambiguous catalog matches) where Haiku 4.5
// was producing too many low-confidence or wrong matchedIds. Sonnet 4.6
// supports vision + structured outputs the same way; the request shape
// below is unchanged.
//
// Why prompt caching: the system prompt + catalog are stable across calls
// within a session (the catalog is sorted deterministically client-side and
// only changes when the user syncs new items). With 4592-item catalogs we
// only send the first 400 to stay well under context limits while still
// crossing Sonnet 4.6's 1024-token cache minimum.

import { corsHeaders } from '../_shared/cors.ts';

const ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages';
const MODEL = 'claude-sonnet-4-6';

// Structured output schema (v1.35 — label extraction only).
//
// Earlier versions asked Claude to also match against a venue catalog
// payload. That produced confident-wrong matches whenever the target
// bottle wasn't in the prompt window (alphabetical caps, dupes, etc).
// The flow is now:
//   1. Edge Function: extract label fields (no catalog, no matching)
//   2. Phone:         counter searches inventory by typed name OR a
//                     read-off-label UPC is looked up locally for a
//                     definitive auto-pick.
// matchedId/candidates are still in the schema as ALWAYS-EMPTY/null so
// older phone clients (still expecting the fields) don't crash. The
// matching responsibility is fully on the phone.
const RESPONSE_SCHEMA = {
  type: 'object',
  properties: {
    name: {
      type: 'string',
      description: "Product name from the label (e.g. 'Reposado', 'Yellow Label Brut'). Empty string if not visible.",
    },
    brand: {
      type: 'string',
      description: "Brand or producer (e.g. 'Don Julio', 'Heineken', 'Veuve Clicquot'). Empty string if not visible.",
    },
    category: {
      type: 'string',
      enum: ['wine', 'spirits', 'beer', 'food', 'other'],
      description: 'Best-fit inventory category for this item.',
    },
    vintage: {
      type: 'string',
      description: "Vintage year if visible (e.g. '2019'). Empty string if no vintage on label.",
    },
    size: {
      type: 'string',
      description: "Bottle/container size with unit (e.g. '750ml', '1.75L', '12oz', '1L'). Empty string if not visible.",
    },
    details: {
      type: 'string',
      description: 'Free-form additional details visible on the label that disambiguate (varietal, region, age statement, expression, etc.).',
    },
    upc: {
      type: 'string',
      description: 'UPC/barcode digits read from the label or back of the bottle. Empty string if no barcode is visible or readable.',
    },
    confidence: {
      type: 'string',
      enum: ['high', 'medium', 'low'],
      description: 'How confident you are that the extracted fields are correct. high = label is clear and you read it cleanly; medium = some fields fuzzy; low = mostly guessing from limited visual info.',
    },
    // Stub fields kept for back-compat with v1.32-v1.34 phone clients
    // that still expect these in the response. Always null/empty in v1.35+.
    matchedId: {
      anyOf: [{ type: 'string' }, { type: 'null' }],
      description: 'DEPRECATED — always null. Catalog matching now happens on the phone.',
    },
    candidates: {
      type: 'array',
      description: 'DEPRECATED — always empty. Catalog matching now happens on the phone.',
      maxItems: 0,
      items: { type: 'object', additionalProperties: true },
    },
  },
  required: ['name', 'brand', 'category', 'vintage', 'size', 'details', 'upc', 'confidence', 'matchedId', 'candidates'],
  additionalProperties: false,
};

const SYSTEM_PROMPT =
  'You are a bar/restaurant inventory assistant. Your single job is to ' +
  'READ a bottle label and return its visible fields as JSON. You do NOT ' +
  'match against any catalog — the phone handles inventory matching ' +
  'separately, locally, and authoritatively.\n\n' +
  'MULTIPLE PHOTOS: You may receive 1–3 photos of the SAME bottle from ' +
  'different angles (front label + back label + neck/seal). Combine ' +
  'information across all photos — vintage, UPC, importer text, varietal, ' +
  'and size frequently only appear on one face.\n\n' +
  'WHAT TO EXTRACT:\n' +
  '- name: the product name as it appears on the label (e.g. "Yellow Label", ' +
  '"Reposado", "Anejo 1942"). Use the LABEL\'s spelling, not a normalized form.\n' +
  '- brand: the producer/brand (e.g. "Veuve Clicquot", "Don Julio"). If the ' +
  'label combines brand+product into one phrase, do your best to split.\n' +
  '- category: the best-fit inventory category — wine, spirits, beer, food, other.\n' +
  '- vintage: the year if printed (wines mainly).\n' +
  '- size: the bottle volume as written on the label — "750ml", "1L", "1.5L", ' +
  '"12oz", "375ml". DO NOT guess based on bottle shape; only return what you ' +
  'can read.\n' +
  '- details: anything extra that helps the counter ID the SKU — varietal, ' +
  'region, age, expression, special edition. Free-form.\n' +
  '- upc: if a barcode is in the photo and the digits are readable, return the ' +
  'digits. Empty string if no barcode is visible.\n' +
  '- confidence: how clean the read was (high / medium / low).\n\n' +
  'WHAT NOT TO DO:\n' +
  '- Do NOT invent fields you cannot see. Empty string is the correct answer ' +
  'for unreadable / not-on-label fields.\n' +
  '- Do NOT translate or normalize names ("Vodka" should stay "Vodka", not ' +
  '"vodka"; "1L" should stay "1L", not "1000ml").\n' +
  '- matchedId is ALWAYS null. candidates is ALWAYS []. These fields exist ' +
  'only for client back-compat — the phone does its own matching.';

interface CatalogItem {
  id: string;
  name: string;
  brand?: string | null;
  size?: string | null;
  upc?: string | null;
}

interface RequestBody {
  // Either pass a single `image` (legacy, single-shot capture) OR an `images`
  // array (new multi-photo capture, up to 3 photos of the same bottle from
  // different angles). When both are provided, `images` wins.
  image?: string;    // base64 string OR data URL ("data:image/jpeg;base64,...")
  images?: string[]; // up to 3 entries; same encoding as `image`
  carried?: CatalogItem[]; // venue-specific stocked items, matched first
  catalog?: CatalogItem[]; // broader inventory, matched second (omit/empty for carried-only first pass)
}

const MAX_IMAGES = 3;

// Strip the optional "data:image/...;base64," prefix off whatever the client
// sent, and pull the media type out so we can pass it to the Anthropic
// vision block. Defaults to JPEG if the client sent raw base64.
function parseImage(input: string): { mediaType: string; data: string } {
  const dataUrlMatch = input.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (dataUrlMatch) {
    return { mediaType: dataUrlMatch[1], data: dataUrlMatch[2] };
  }
  // Raw base64 — assume JPEG (matches what canvas.toDataURL defaults to).
  return { mediaType: 'image/jpeg', data: input };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: corsHeaders });
  }

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) {
    return new Response(
      JSON.stringify({ error: 'ANTHROPIC_API_KEY not set in Edge Function secrets' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Body must be JSON' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  // Normalize input into an array. `images` wins when both are sent so a
  // client retrying with multi-photo support after a partial rollout doesn't
  // accidentally fall back to the legacy single-shot path.
  let rawImages: string[];
  if (Array.isArray(body.images) && body.images.length > 0) {
    rawImages = body.images.filter((s) => typeof s === 'string' && s.length > 0);
  } else if (typeof body.image === 'string' && body.image.length > 0) {
    rawImages = [body.image];
  } else {
    rawImages = [];
  }

  if (rawImages.length === 0) {
    return new Response(JSON.stringify({ error: 'image or images is required (base64 string or data URL)' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
  if (rawImages.length > MAX_IMAGES) {
    rawImages = rawImages.slice(0, MAX_IMAGES);
  }

  const imageBlocks = rawImages.map((raw) => {
    const { mediaType, data } = parseImage(raw);
    return {
      type: 'image' as const,
      source: { type: 'base64' as const, media_type: mediaType, data },
    };
  });

  // v1.35: catalog payload is no longer used by the prompt. Older clients
  // (v1.32-v1.34) still send `carried` and `catalog` in the body — we
  // accept and ignore them for back-compat. Logged so we can confirm
  // when those clients drop off.
  if ((body.carried && body.carried.length) || (body.catalog && body.catalog.length)) {
    console.log('[parse-bottle-label] legacy client sent catalog payload (ignored)');
  }

  // Cache placement: only the system prompt is cached now (no catalog).
  // The system prompt is stable across calls so cache hits are cheap.
  // The image lives in messages — outside the cached prefix — and
  // changes every call.
  const requestBody = {
    model: MODEL,
    max_tokens: 1024,
    system: [
      {
        type: 'text',
        text: SYSTEM_PROMPT,
        cache_control: { type: 'ephemeral' },
      },
    ],
    output_config: {
      format: {
        type: 'json_schema',
        schema: RESPONSE_SCHEMA,
      },
    },
    messages: [
      {
        role: 'user',
        content: [
          ...imageBlocks,
          {
            type: 'text',
            text: imageBlocks.length > 1
              ? 'Read these ' + imageBlocks.length + ' photos of the same bottle (front/back/neck angles) and return JSON of the visible label fields. Combine information across the photos. Do NOT match against any catalog — the phone does that.'
              : 'Read this label and return JSON of the visible fields. Do NOT match against any catalog — the phone does that.',
          },
        ],
      },
    ],
  };

  let upstream: Response;
  try {
    upstream = await fetch(ANTHROPIC_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        // structured-outputs feature flag. The Anthropic SDKs (Python/TS)
        // add this implicitly when output_config is present; raw HTTP
        // needs to send it manually or the API rejects output_config.
        'anthropic-beta': 'structured-outputs-2025-11-13',
      },
      body: JSON.stringify(requestBody),
    });
  } catch (e) {
    console.error('[parse-bottle-label] fetch failed', e);
    return new Response(JSON.stringify({ error: 'Upstream request failed: ' + (e as Error).message }), {
      status: 502,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  if (!upstream.ok) {
    const errText = await upstream.text();
    console.error('[parse-bottle-label] upstream', upstream.status, errText);
    return new Response(
      JSON.stringify({ error: 'Anthropic API error', status: upstream.status, detail: errText.slice(0, 500) }),
      { status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  const data_resp = await upstream.json();

  // The first text block holds the JSON when output_config.format is set.
  // We log cache hits/misses so the caller (or supabase logs) can verify
  // caching is actually working — if cache_read_input_tokens is zero on
  // repeat calls, a silent invalidator is in the prefix.
  const usage = data_resp.usage || {};
  console.log('[parse-bottle-label] usage', JSON.stringify({
    input: usage.input_tokens,
    cache_read: usage.cache_read_input_tokens,
    cache_creation: usage.cache_creation_input_tokens,
    output: usage.output_tokens,
  }));

  const textBlock = (data_resp.content || []).find((b: { type: string }) => b.type === 'text');
  if (!textBlock) {
    return new Response(JSON.stringify({ error: 'No text block in Anthropic response', raw: data_resp }), {
      status: 502,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(textBlock.text);
  } catch {
    return new Response(
      JSON.stringify({ error: 'Anthropic returned non-JSON text', text: String(textBlock.text).slice(0, 500) }),
      { status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  return new Response(
    JSON.stringify({
      ...(parsed as Record<string, unknown>),
      _usage: {
        input_tokens: usage.input_tokens,
        cache_read_input_tokens: usage.cache_read_input_tokens,
        cache_creation_input_tokens: usage.cache_creation_input_tokens,
        output_tokens: usage.output_tokens,
      },
    }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
});
