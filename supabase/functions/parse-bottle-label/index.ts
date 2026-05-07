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
      description: 'Catalog id of your single best match (= candidates[0].id when candidates is non-empty). null when no catalog row is plausible.',
    },
    candidates: {
      type: 'array',
      description: 'Up to 5 plausible catalog rows ranked by confidence (best first). Empty array when nothing matches. The phone uses this for ambiguity resolution: if 2+ have UPCs the counter picks; if 0 have UPCs the counter picks. Be liberal — when a label could plausibly be one of two SKUs (e.g. 750ml vs 1.5L of the same wine), include both.',
      maxItems: 5,
      items: {
        type: 'object',
        properties: {
          id:    { type: 'string',  description: 'Catalog id (must be one from the lists above).' },
          name:  { type: 'string',  description: 'Catalog name.' },
          brand: { type: 'string',  description: 'Catalog brand. Empty string if not in the catalog row.' },
          size:  { type: 'string',  description: 'Catalog size. Empty string if not in the catalog row.' },
          upc:   { type: 'string',  description: 'Catalog UPC. Empty string when the catalog row has none.' },
        },
        required: ['id', 'name', 'brand', 'size', 'upc'],
        additionalProperties: false,
      },
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
  required: ['name', 'brand', 'category', 'vintage', 'size', 'details', 'matchedId', 'candidates', 'upc', 'confidence'],
  additionalProperties: false,
};

const SYSTEM_PROMPT =
  'You are a bar/restaurant inventory assistant. Given one or more photos of ' +
  'a wine, liquor, or beer label/bottle, extract the key fields AND match ' +
  'against the provided catalog.\n\n' +
  'MULTIPLE PHOTOS: You may receive 1–3 photos of the SAME bottle taken from ' +
  'different angles (e.g. front label + back label + neck/seal). Combine ' +
  'information across all photos before deciding — vintage, UPC, importer ' +
  'text, varietal, and size frequently appear on only one face.\n\n' +
  'MATCHING PRIORITY (try in order, stop at first hit):\n' +
  '1. CARRIED ITEMS — the venue\'s stocked list. Always preferred. If the ' +
  'label plausibly matches a carried item, that is the match — even if ' +
  'something in "Other catalog" looks like a closer name match.\n' +
  '2. OTHER CATALOG — broader inventory the venue could carry but doesn\'t ' +
  'currently. Only consider these when no carried item plausibly matches.\n' +
  '3. NO MATCH — set matchedId to null AND candidates to []. The mobile app ' +
  'will route this to a pending-items review queue. Still extract every ' +
  'label field you can read.\n\n' +
  'CANDIDATES (the array): include up to 5 catalog rows you considered ' +
  'plausible, ranked best-first. matchedId MUST equal candidates[0].id when ' +
  'candidates is non-empty. The phone disambiguates downstream — if 2+ ' +
  'candidates have UPCs the counter picks; if 0 have UPCs the counter picks. ' +
  'So when in doubt between two near-equal SKUs (especially same-name ' +
  'different-size, e.g. 750ml vs 1.5L), include BOTH in candidates rather ' +
  'than guessing — the counter can see the bottle.\n\n' +
  'MATCHING RULES — accuracy over coverage:\n' +
  '- Match across abbreviations, missing words, reordering. "818 Reposado" ' +
  'MUST match "818 Tequila Reposado" — the missing "Tequila" is implicit ' +
  'from the bottle. Same for "Don Julio 1942" matching "Don Julio Anejo 1942".\n' +
  '- UPC match (label barcode == catalog UPC) is definitive and overrides ' +
  'name/brand differences.\n' +
  '- ANTI-CONFABULATION: The catalog you receive may be incomplete (a venue ' +
  'subset). If the label\'s brand and product name are NOT clearly listed in ' +
  'either CARRIED or OTHER CATALOG, return matchedId=null AND candidates=[]. ' +
  'Do NOT pick a "similar but different" product just to give an answer. ' +
  'Example: a Ketel One photo with NO "Ketel" entry in the catalog must ' +
  'return null/empty — never match it to "Tito\'s" or "Egg Nog" because ' +
  'they happen to be 1L bottles. The phone surfaces null/empty as a clean ' +
  '"no catalog match" UI; a wrong match is a counted-wrong-bottle bug.\n' +
  '- SIZE COMES FROM THE LABEL, NOT THE CATALOG. If the label clearly shows ' +
  '"1.5L" or "3L" or "1L", return that exact value in the size field even ' +
  'when the matched catalog row says "750ml". DO NOT substitute the ' +
  'catalog\'s size onto the size field. The catalog size only helps you ' +
  'pick the right SKU when multiple sizes exist for the same product.\n' +
  '- When multiple catalog rows differ only by size (e.g. a 750ml SKU and ' +
  'a 1.5L SKU of the same wine), match the SKU whose size matches the label. ' +
  'If you cannot tell from the photos, include both in candidates.\n' +
  '- Confidence: "high" for UPC matches or near-exact name matches; ' +
  '"medium" for fuzzy/partial matches where brand and product type clearly ' +
  'align; "low" for guesses (and prefer null over a "low" confidence guess).\n' +
  '- Output `name` and `brand` using the LABEL\'s spelling, not the ' +
  'catalog\'s. matchedId still points to the catalog row.\n\n' +
  "Use empty strings (not null) for label fields you can't read.\n" +
  'Use null for matchedId AND empty array for candidates whenever the bottle ' +
  'in the photo is not clearly represented in either list — the phone has a ' +
  'first-class "no catalog match" path that handles this gracefully.';

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
          ...imageBlocks,
          {
            type: 'text',
            text: imageBlocks.length > 1
              ? 'Analyze these ' + imageBlocks.length + ' photos of the same bottle (different angles/labels) and return JSON matching the schema. Combine information across the photos. Use the catalog above to populate candidates and matchedId when confident.'
              : 'Analyze this label and return JSON matching the schema. Use the catalog above to populate candidates and matchedId when confident.',
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
