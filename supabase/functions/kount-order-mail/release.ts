// The release engine's reader (0179, admin v1.30): one e-mail h.wood sent E&E -> is it asking for cases out of
// storage, for which venue, which items, how many. OpenRouter only (the user, 11/17), the small model: a few e-mails
// a day, a short answer.
import { routeClaude } from '../_shared/ai-router.ts';
import type { ReleaseRead } from '../_shared/orderTracker.ts';

export const RELEASE_SYSTEM = `You read e-mails that h.wood Group (a restaurant group) sends to EE Mercantile (E&E). E&E makes h.wood's custom printed supplies (napkins, coasters, tote bags, pizza boxes, chopsticks, matches...) and STORES each big batch in its warehouse. When a venue runs low, h.wood e-mails E&E to send a few cases of that stored stock to the venue (by Uber, UPS, a courier or a pick-up).

Decide whether THIS e-mail asks E&E for cases of an item it already STORES for us (the stock list below) to go to a venue or for a pick-up, or confirms such a request. h.wood often writes these as an order: "I would like to place an order for 2 cases of togo bags for birdstreet" is a release of stored tote bags to The Birdstreet Club. It is NOT one when it orders something to be made or bought (glassware, smallware, equipment, a new production run or re-order of a custom item, anything not on the stock list), or is about a quote, artwork, a sample, a payment, an invoice, a tracking question, or a release only mentioned as something that already happened.

When it is one: the venue it goes to, written as one of the venue names given (empty when none is named); each item with the number written for it. sku = the item's SKU from the stock list when the e-mail clearly means that item, else empty, with the words the e-mail uses in item. qty = the number written (0 when no number is written). unit = what that number counts: case, box, piece, bag... Never guess a number or an item.`;

export const RELEASE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['is_release', 'venue', 'lines'],
  properties: {
    is_release: { type: 'boolean', description: 'true when the e-mail asks E&E to send / deliver / release stored stock to a venue or for a pick-up' },
    venue: { type: 'string', description: 'The venue it goes to, as one of the venue names given; empty string if none is named.' },
    lines: {
      type: 'array',
      description: 'Each item asked for; empty when it is not a release.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['sku', 'item', 'qty', 'unit'],
        properties: {
          sku: { type: 'string', description: "The item's SKU from the stock list, or empty string when not clearly one of them." },
          item: { type: 'string', description: 'The words the e-mail uses for the item.' },
          qty: { type: 'number', description: 'The number written for it; 0 when none is written.' },
          unit: { type: 'string', description: 'What the number counts: case, box, piece, bag... Empty when no number.' },
        },
      },
    },
  },
} as const;

/** The reader's answer as the engine keeps it (empty -> null). */
export function toReleaseRead(j: unknown): ReleaseRead {
  const o = (j ?? {}) as { is_release?: unknown; venue?: unknown; lines?: unknown };
  const str = (x: unknown) => (typeof x === 'string' && x.trim() ? x.trim() : null);
  const lines = Array.isArray(o.lines) ? o.lines : [];
  return {
    is_release: o.is_release === true,
    venue: str(o.venue),
    lines: lines.map(l => {
      const x = (l ?? {}) as { sku?: unknown; item?: unknown; qty?: unknown; unit?: unknown };
      const q = Number(x.qty);
      return { sku: str(x.sku), item: str(x.item) ?? '', qty: Number.isFinite(q) && q > 0 ? q : null, unit: str(x.unit) };
    }).filter(l => l.sku || l.item),
  };
}

/** The stock list and venues the reader picks from: "SKU | name | brand". */
export function releaseContext(items: Array<{ sku: string | null; name: string; category: string | null }>, venues: Array<{ name: string }>): string {
  return `Stock E&E holds for us (SKU | name | brand):\n${items.map(i => `${i.sku ?? '(no SKU)'} | ${i.name} | ${i.category ?? ''}`).join('\n')}\n\n`
    + `Venues: ${venues.map(v => v.name).join(', ')}`;
}

export async function readReleaseMail(a: { subject: string; from: string; sentAt: string; body: string; context: string; messageId: string }): Promise<{ read: ReleaseRead; model: string }> {
  const r = await routeClaude({
    flow: 'kount-release-mail',
    model: 'claude-haiku-4-5',
    maxTokens: 1200,
    system: [{ text: RELEASE_SYSTEM }, { text: a.context, cache: true }],
    messages: [{ role: 'user', content: `From: ${a.from}\nSent: ${a.sentAt}\nSubject: ${a.subject}\n\n${a.body.slice(0, 6000)}` }],
    jsonSchema: { name: 'release_mail', schema: RELEASE_SCHEMA as unknown as Record<string, unknown> },
    metadata: { message_id: a.messageId },
  });
  return { read: toReleaseRead(r.json), model: r.model };
}
