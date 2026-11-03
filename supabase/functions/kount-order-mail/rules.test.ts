// deno test supabase/functions/kount-order-mail/rules.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { domainOf, fromBase64, idTokenMailbox, isPdfAttachment, kindAllowed, laParts, looksLikePurchaseDoc, MAX_PDF_BYTES, onList, OWN_DOMAINS, matchR365Payments, safeEqual, sha256Hex, toBase64, wantsAttachment } from './rules.ts';

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

Deno.test('mailbox from the sign-in id token', () => {
  const b64url = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const tok = (claims: unknown) => `${b64url({ alg: 'none' })}.${b64url(claims)}.sig`;
  assertEquals(idTokenMailbox(tok({ preferred_username: 'APurandare@hwoodgroup.com', name: 'Aditya' })), 'apurandare@hwoodgroup.com');
  assertEquals(idTokenMailbox(tok({ email: 'x@hwoodgroup.com' })), 'x@hwoodgroup.com');
  assertEquals(idTokenMailbox(tok({ name: 'no address' })), '');
  assertEquals(idTokenMailbox('not-a-jwt'), '');
  assertEquals(idTokenMailbox(undefined), '');
});

Deno.test('invoices only: which attachments are opened, which readings are kept', () => {
  const inv = ['invoice'];
  assert(wantsAttachment(inv, 'Re: Delilah LA - Quote Request - Collins Glass', 'Invoice-INV-2026-086418.pdf'), 'E&E invoice in a quote thread');
  assert(wantsAttachment(inv, 'Re: TNG Order', 'CM INV-2026-86333.pdf'), 'credit memo');
  assert(wantsAttachment(inv, 'Invoice from KEVIDKO: 379993', '379993.pdf'), 'subject says invoice');
  assert(!wantsAttachment(inv, 'Re: Lady Delilah Scalloped Coasters', 'Quote-Q-2026-1182.pdf'), 'a quote is not opened');
  assert(!wantsAttachment(inv, 'Re: Order TNG - OS&E 7/20', 'TNG delivery list.pdf'));
  assert(wantsAttachment(['quote', 'confirmation', 'invoice', 'shipping'], 'anything', 'anything.pdf'), 'all types on: every PDF');
  assert(wantsAttachment(['invoice', 'quote'], '', 'Quote-Q-1.pdf'));
  assert(kindAllowed(inv, { doc_kind: 'invoice' }));
  assert(!kindAllowed(inv, { doc_kind: 'quote' }), 'read as a quote -> skipped');
  assert(kindAllowed(inv, { doc_kind: 'other', is_credit: true }), 'a credit memo goes with invoices');
  assert(!kindAllowed(['quote'], { doc_kind: 'other', is_credit: true }));
});

Deno.test('R365: a payment for exactly one invoice', () => {
  const tx = (type: 'AP Invoice' | 'AP Payment', number: string, date: string, amount: number, venue = 'TNG') => ({ type, number, date, venue, vendor: 'E&E Mercantile LLC', amount });
  const m = matchR365Payments([
    tx('AP Invoice', 'INV-2026-817036', '2026-10-15', 13682.74), tx('AP Invoice', 'INV-2026-927468', '2026-10-15', 241.38),
    tx('AP Payment', 'ACH - 24737', '2026-10-22', 13682.74), tx('AP Payment', 'ACH - 24589', '2026-10-22', 241.38),
  ]);
  assertEquals(m.get('INV-2026-817036')?.number, 'ACH - 24737');
  assertEquals(m.get('INV-2026-927468')?.number, 'ACH - 24589');
});

Deno.test('R365: one payment for several invoices, only when exactly one combination fits', () => {
  const tx = (type: 'AP Invoice' | 'AP Payment', number: string, date: string, amount: number, venue = 'TNG') => ({ type, number, date, venue, vendor: 'E&E Mercantile LLC', amount });
  const m = matchR365Payments([
    tx('AP Invoice', 'A', '2026-10-01', 100.10), tx('AP Invoice', 'B', '2026-10-02', 250.25), tx('AP Invoice', 'C', '2026-10-03', 49.65),
    tx('AP Payment', 'ACH - 1', '2026-10-10', 350.35),
  ]);
  assertEquals([...m.keys()].sort(), ['A', 'B']);
  const amb = matchR365Payments([
    tx('AP Invoice', 'A', '2026-10-01', 100), tx('AP Invoice', 'B', '2026-10-02', 200), tx('AP Invoice', 'C', '2026-10-03', 150), tx('AP Invoice', 'D', '2026-10-04', 150),
    tx('AP Payment', 'ACH - 2', '2026-10-10', 300),
  ]);
  assertEquals(amb.size, 0, '100+200 and 150+150 both fit -> not sure -> nothing');
});

Deno.test('R365: never across companies, never a payment before the invoice', () => {
  const tx = (type: 'AP Invoice' | 'AP Payment', number: string, date: string, amount: number, venue: string) => ({ type, number, date, venue, vendor: 'E&E Mercantile LLC', amount });
  assertEquals(matchR365Payments([tx('AP Invoice', 'A', '2026-10-01', 500, 'TNG'), tx('AP Payment', 'P', '2026-10-05', 500, 'Delilah')]).size, 0);
  assertEquals(matchR365Payments([tx('AP Invoice', 'A', '2026-10-20', 500, 'TNG'), tx('AP Payment', 'P', '2026-10-05', 500, 'TNG')]).size, 0);
  const twice = matchR365Payments([tx('AP Invoice', 'A', '2026-10-01', 500, 'TNG'), tx('AP Invoice', 'B', '2026-10-02', 500, 'TNG'),
    tx('AP Payment', 'P1', '2026-10-05', 500, 'TNG'), tx('AP Payment', 'P2', '2026-10-06', 500, 'TNG')]);
  assertEquals([twice.get('A')?.number, twice.get('B')?.number], ['P1', 'P2'], 'equal amounts: oldest invoice first, each paid once');
});
