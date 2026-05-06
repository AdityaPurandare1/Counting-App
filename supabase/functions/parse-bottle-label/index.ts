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
  'the provided catalog.\n\n' +
  'MATCHING PRIORITY (try in order, stop at first hit):\n' +
  '1. CARRIED ITEMS — the venue\'s stocked list. Always preferred. If the ' +
  'label plausibly matches a carried item, that is the match — even if ' +
  'something in "Other catalog" looks like a closer name match.\n' +
  '2. OTHER CATALOG — broader inventory the venue could carry but doesn\'t ' +
  'currently. Only consider these when no carried item plausibly matches.\n' +
  '3. NO MATCH — set matchedId to null. The mobile app will route this to a ' +
  'pending-items review queue. Still extract every label field you can read.\n\n' +
  'MATCHING RULES — be liberal, not conservative:\n' +
  '- Match across abbreviations, missing words, reordering. "818 Reposado" ' +
  'MUST match "818 Tequila Reposado" — the missing "Tequila" is implicit ' +
  'from the bottle. Same for "Don Julio 1942" matching "Don Julio Anejo 1942".\n' +
  '- UPC match (label barcode == catalog UPC) is definitive and overrides ' +
  'name/brand differences.\n' +
  '- SIZE COMES FROM THE LABEL, NOT THE CATALOG. If the label clearly shows ' +
  '"1.5L" or "3L" or "1L", return that exact value in the size field even ' +
  'when the matched catalog row says "750ml". DO NOT substitute the ' +
  'catalog\'s size onto the size field. The catalog size only helps you ' +
  'pick the right SKU when multiple sizes exist for the same product.\n' +
  '- When multiple catalog rows differ only by size (e.g. a 750ml SKU and ' +
  'a 1.5L SKU of the same wine), match the SKU whose size matches the label.\n' +
  '- Confidence: "high" for UPC matches or near-exact name matches; ' +
  '"medium" for fuzzy/partial matches where brand and product type clearly ' +
  'align; "low" for guesses. Withholding a match the counter can clearly ' +
  'see costs them an inventory row — err on the side of matching.\n' +
  '- Output `name` and `brand` using the LABEL\'s spelling, not the ' +
  'catalog\'s. matchedId still points to the catalog row.\n\n' +
  "Use empty strings (not null) for label fields you can't read.\n" +
  'Use null for matchedId only when no row in either list plausibly matches.';

interface CatalogItem {
  id: string;
  name: string;
  brand?: string | null;
  size?: string | null;
  upc?: string | null;
}

interface RequestBody {
  image: string; // base64 string OR data URL ("data:image/jpeg;base64,...")
  carried?: CatalogItem[]; // venue-specific stocked items, matched first
  catalog?: CatalogItem[]; // broader inventory, matched second
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

function renderCatalogLines(items: CatalogItem[], cap: number): string {
  return items.slice(0, cap).map((item) => {
    const parts = [item.id, '|', item.name];
    if (item.brand) parts.push(' — ', item.brand);
    if (item.size)  parts.push(' (', item.size, ')');
    if (item.upc)   parts.push(' [UPC ', item.upc, ']');
    return parts.join('');
  }).join('\n');
}

function buildCatalogText(carried: CatalogItem[] | undefined, other: CatalogItem[] | undefined): string {
  const sections: string[] = [];
  // Two-tier rendering so Claude knows which list to try first. The
  // venue's carried items get the full payload; the broader catalog is
  // capped harder to bound prompt size. Include UPC inline so a label
  // barcode can short-circuit name fuzziness.
  if (carried && carried.length > 0) {
    sections.push(
      '=== CARRIED ITEMS (this venue stocks these — match these FIRST) ===\n' +
      'Format: id|name — brand (size) [UPC code]\n' +
      renderCatalogLines(carried, 250),
    );
  } else {
    sections.push('=== CARRIED ITEMS ===\n(none — this venue\'s carried list is empty)');
  }
  if (other && other.length > 0) {
    sections.push(
      '=== OTHER CATALOG (broader inventory — match only when no carried item fits) ===\n' +
      renderCatalogLines(other, 250),
    );
  }
  if (sections.length === 0) {
    return '(catalog empty — return matchedId: null)';
  }
  return sections.join('\n\n');
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
  const catalogText = buildCatalogText(body.carried, body.catalog);

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
