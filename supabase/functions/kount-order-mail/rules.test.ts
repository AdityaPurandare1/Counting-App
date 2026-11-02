// deno test supabase/functions/kount-order-mail/rules.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { domainOf, fromBase64, isPdfAttachment, laParts, looksLikePurchaseDoc, MAX_PDF_BYTES, onList, OWN_DOMAINS, safeEqual, sha256Hex, toBase64 } from './rules.ts';

Deno.test('sender domain, with or without a display name', () => {
  assertEquals(domainOf('aleli@eemercantile.co'), 'eemercantile.co');
  assertEquals(domainOf('Aleli Abad <Aleli@EEMercantile.co>'), 'eemercantile.co');
  assertEquals(domainOf(''), '');
  assertEquals(domainOf(undefined), '');
});

Deno.test('vendor list matches the domain and its sub-domains only', () => {
  const list = ['eemercantile.co', 'notification.intuit.com'];
  assert(onList('eemercantile.co', list));
  assert(onList('mail.eemercantile.co', list));
  assert(onList('notification.intuit.com', list));
  assert(!onList('intuit.com', list), 'a parent domain is not on the list');
  assert(!onList('noteemercantile.co', list), 'a look-alike is not a sub-domain');
  assert(onList('hwoodgroup.com', OWN_DOMAINS));
});

Deno.test('only real, readable PDF files are taken', () => {
  const pdf = { '@odata.type': '#microsoft.graph.fileAttachment', id: 'a', name: 'Invoice-INV-2026-086418.pdf', contentType: 'application/pdf', size: 10001, isInline: false };
  assert(isPdfAttachment(pdf));
  assert(isPdfAttachment({ ...pdf, contentType: 'application/octet-stream' }), 'named .pdf counts');
  assert(!isPdfAttachment({ ...pdf, isInline: true }), 'inline images / logos are not documents');
  assert(!isPdfAttachment({ ...pdf, name: 'image.png', contentType: 'image/png' }));
  assert(!isPdfAttachment({ ...pdf, '@odata.type': '#microsoft.graph.itemAttachment' }), 'an attached email is not a PDF');
  assert(!isPdfAttachment({ ...pdf, size: MAX_PDF_BYTES + 1 }), 'over 10 MB is skipped');
  for (const name of ['W9 EE Mercantile.pdf', '2026-07-09T22_01_24-FedEx-Shipping-Label.pdf', 'Coaster mockup v2.pdf', 'COI 2026.pdf', 'Eurototes proof.pdf']) {
    assert(!isPdfAttachment({ ...pdf, name }), name);
  }
});

Deno.test('suggestion hint: quotes, invoices, confirmations — not travel or menus', () => {
  assert(looksLikePurchaseDoc('Re: Alphabet - Eurototes', 'Quote-Q-2026-1182.pdf'));
  assert(looksLikePurchaseDoc('Invoice from KEVIDKO: 379993', 'doc.pdf'));
  assert(looksLikePurchaseDoc('', 'INV-43791.pdf'));
  assert(looksLikePurchaseDoc('Your order confirmation', 'x.pdf'));
  assert(!looksLikePurchaseDoc('Booking.com: Confirmation', 'Booking.com_ Confirmation.pdf'));
  assert(!looksLikePurchaseDoc('Holiday menu', 'menu.pdf'));
});

Deno.test("9 o'clock in Los Angeles, both sides of the DST change", () => {
  assertEquals(laParts(new Date('2026-11-02T17:05:00Z')), { hour: 9, isoDate: '2026-11-02' });   // PST: 17:05 UTC = 9:05
  assertEquals(laParts(new Date('2026-11-02T16:05:00Z')).hour, 8);
  assertEquals(laParts(new Date('2026-10-30T16:05:00Z')).hour, 9);                              // PDT: 16:05 UTC = 9:05
  assertEquals(laParts(new Date('2026-10-30T17:05:00Z')).hour, 10);
  assertEquals(laParts(new Date('2026-11-03T06:30:00Z')).isoDate, '2026-11-02', 'the LA date, not the UTC date');
});

Deno.test('cron secret compare', () => {
  assert(safeEqual('abc123', 'abc123'));
  assert(!safeEqual('abc123', 'abc124'));
  assert(!safeEqual('abc', 'abc123'));
  assert(!safeEqual('', ''), 'an empty secret never matches');
});

Deno.test('base64 round trip + sha256', async () => {
  const bytes = new Uint8Array(70_000).map((_, i) => (i * 7) % 256);
  const b64 = toBase64(bytes);
  assertEquals(fromBase64(b64), bytes);
  assertEquals(await sha256Hex(new TextEncoder().encode('abc') as Uint8Array<ArrayBuffer>), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});
