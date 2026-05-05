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
// Why Haiku 4.5: label extraction is a structured-output task with vision
// input, not a reasoning-heavy job. Sonnet 4.6 would be ~3x the cost for
// roughly the same accuracy on this workload, and Haiku 4.5 supports both
// vision and structured outputs.
//
// Why prompt caching: the system prompt + catalog are stable across calls
// within a session (the catalog is sorted deterministically client-side and
// only changes when the user syncs new items). With 4592-item catalogs we
// only send the first 400 to stay well under context limits while still
// crossing Haiku 4.5's 4096-token cache minimum.

import { corsHeaders } from '../_shared/cors.ts';

const ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages';
const MODEL = 'claude-haiku-4-5';

// Structured output schema. Mirrors the field shape the mobile app's
// parsePhotoLabel wrapper already expects from the OpenAI path so we can
// drop this in without touching the form-population logic.
const RESPONSE_SCHEMA = {
  type: 'object',
  properties: {
    name: {
      type: 'string',
      description: "Product name from the label (e.g. 'Reposado'). Empty string if not visible.",
    },
    brand: {
      type: 'string',
      description: "Brand or producer (e.g. 'Don Julio', 'Heineken'). Empty string if not visible.",
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
      description: "Bottle/container size with unit (e.g. '750ml', '1.75L', '12oz'). Empty string if not visible.",
    },
    details: {
      type: 'string',
      description: 'Free-form additional details visible on the label that might disambiguate (region, varietal, etc.).',
    },
    matchedId: {
      // anyOf instead of type: ['string', 'null'] — the array-of-types form
      // isn't reliably accepted by Anthropic's strict JSON-schema validator,
      // even though it's valid per the JSON Schema spec. anyOf is the
      // documented-supported way to express nullability.
      anyOf: [{ type: 'string' }, { type: 'null' }],
      description: 'Catalog id of the matching row. Be liberal: missing-word matches like "818 Reposado" → "818 Tequila Reposado" should set this. Only null if no catalog row is plausible.',
    },
    upc: {
      type: 'string',
      description: 'UPC/barcode for the matched catalog row. If matchedId is set and that row has a [UPC ...] entry, copy the digits exactly. If you can read a UPC from the label itself, return that. Empty string when neither is available.',
    },
    confidence: {
      type: 'string',
      enum: ['high', 'medium', 'low'],
      description: 'How confident you are in the match. high = UPC or near-exact name match, medium = fuzzy/partial name match, low = guess.',
    },
  },
  required: ['name', 'brand', 'category', 'vintage', 'size', 'details', 'matchedId', 'upc', 'confidence'],
  additionalProperties: false,
};

const SYSTEM_PROMPT =
  'You are a bar/restaurant inventory assistant. Given a photo of a wine, ' +
  'liquor, or beer label/bottle, extract the key fields AND match against ' +
  'the provided catalog. ' +
  '\n\n' +
  'MATCHING RULES — be liberal here, not conservative:\n' +
  '1. Match aggressively across abbreviations, missing words, and reordering. ' +
  '"818 Reposado" on a label MUST match "818 Tequila Reposado" in the catalog ' +
  '— the missing "Tequila" is implicit from the bottle. Same for "Don Julio ' +
  '1942" matching "Don Julio Anejo 1942".\n' +
  '2. If a UPC is visible on the label and any catalog row has the same UPC, ' +
  'that is a definitive match. UPC match overrides name/brand differences.\n' +
  '3. Size on the label should match the catalog row\'s size if both are known. ' +
  '"750ml" and "750 ml" and "0.75L" all match.\n' +
  '4. Use confidence "high" for UPC matches or near-exact name matches. ' +
  '"medium" for fuzzy / partial-name matches where brand and product type ' +
  'clearly align. Only return matchedId=null if NO catalog row plausibly ' +
  'matches — withholding a match the user can clearly see costs them an ' +
  'inventory entry.\n' +
  '5. Prefer the exact spelling on the label for the name and brand output ' +
  'fields, but still set matchedId to the catalog row when you find one.\n' +
  '\n' +
  "Use empty strings (not null) for label fields you can't see. " +
  'Use null for matchedId only when no catalog row is even a plausible match.';

interface CatalogItem {
  id: string;
  name: string;
  brand?: string | null;
  size?: string | null;
  upc?: string | null;
}

interface RequestBody {
  image: string; // base64 string OR data URL ("data:image/jpeg;base64,...")
  catalog?: CatalogItem[];
}

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

function buildCatalogText(catalog: CatalogItem[] | undefined): string {
  if (!catalog || catalog.length === 0) {
    return '(catalog empty — return matchedId: null)';
  }
  // Cap at 400 to bound token usage. The mobile client is responsible for
  // ranking which 400 to send (typically alphabetical or recently-counted).
  // Include UPC inline so Claude can match by UPC when the label shows a
  // barcode region and a catalog row has the same code — that's an exact
  // match that beats name fuzziness.
  const lines = catalog.slice(0, 400).map((item) => {
    const parts = [item.id, '|', item.name];
    if (item.brand) parts.push(' — ', item.brand);
    if (item.size)  parts.push(' (', item.size, ')');
    if (item.upc)   parts.push(' [UPC ', item.upc, ']');
    return parts.join('');
  });
  return 'Catalog (id|name — brand (size) [UPC code]):\n' + lines.join('\n');
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

  if (!body.image || typeof body.image !== 'string') {
    return new Response(JSON.stringify({ error: 'image is required (base64 string or data URL)' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const { mediaType, data } = parseImage(body.image);
  const catalogText = buildCatalogText(body.catalog);

  // Cache placement: render order is tools → system → messages. We put the
  // system prompt + catalog both in the system array, and put the
  // cache_control marker on the LAST system block (the catalog). Because
  // caching matches a prefix, this caches both blocks together using one
  // breakpoint. The image lives in messages — outside the cached prefix —
  // so it can change every call without invalidating anything.
  const requestBody = {
    model: MODEL,
    max_tokens: 1024,
    system: [
      { type: 'text', text: SYSTEM_PROMPT },
      {
        type: 'text',
        text: catalogText,
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
          {
            type: 'image',
            source: { type: 'base64', media_type: mediaType, data },
          },
          {
            type: 'text',
            text: 'Analyze this label and return JSON matching the schema. Use the catalog above to set matchedId when confident.',
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
