// deno test supabase/functions/kount-order-mail/rules.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { domainOf, fromBase64, isToVendor, sentToVendor, takeEmailSentDay, idTokenMailbox, isPdfAttachment, kindAllowed, laParts, looksLikePurchaseDoc, MAX_PDF_BYTES, onList, OWN_DOMAINS, invoiceToken, isStubAttachment, matchR365Payments, paidInvoices, safeEqual, sha256Hex, stubInvoices, toBase64, wantsAttachment } from './rules.ts';

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

Deno.test('R365: an invoice split per venue is paid only when every part is', () => {
  const tx = (type: 'AP Invoice' | 'AP Payment', number: string, date: string, amount: number, venue: string) => ({ type, number, date, venue, vendor: 'E&E Mercantile LLC', amount });
  const parts = [tx('AP Invoice', 'INV-2026-857309 Delilah LA', '2026-08-30', 5120.03, 'LA'), tx('AP Invoice', 'INV-2026-857309 Delilah Miami', '2026-08-30', 5120.03, 'MIA'),
                 tx('AP Invoice', 'INV-2026-857309 Delilah Dallas', '2026-08-30', 5120.03, 'DAL')];
  const pays = [tx('AP Payment', 'ACH - 1', '2026-09-03', 5120.03, 'LA'), tx('AP Payment', 'ACH - 2', '2026-09-03', 5120.03, 'MIA')];
  assertEquals(paidInvoices(['INV-2026-857309'], [...parts, ...pays]).size, 0, 'Dallas part unpaid -> not paid');
  const all = paidInvoices(['inv-2026-857309-1'], [...parts, ...pays, tx('AP Payment', 'ACH - 3', '2026-09-04', 5120.03, 'DAL')]);
  assertEquals(all.get('INV-2026-857309')?.map(p => p.number).sort(), ['ACH - 1', 'ACH - 2', 'ACH - 3']);
  const voided = paidInvoices(['INV-2026-291876'], [tx('AP Invoice', 'INV-2026-291876 - Voided', '2026-09-22', 29680.5, 'LA'),
    tx('AP Invoice', 'INV-2026-291876 - Voiding', '2026-09-28', -29680.5, 'LA'), tx('AP Payment', 'ACH - 9', '2026-09-29', 29680.5, 'LA')]);
  assertEquals(voided.size, 0, 'a voided invoice is never paid');
  assertEquals(invoiceToken('INV-2026-291876/2'), 'INV-2026-291876');
  assertEquals(invoiceToken('Invoice-INV-2026-086418.pdf'), 'INV-2026-086418');
});

Deno.test('check stubs: which files, which invoices', () => {
  const att = (over: Record<string, unknown>) => ({ '@odata.type': '#microsoft.graph.fileAttachment', id: 'a', name: 'paystub.pdf', contentType: 'application/pdf', size: 80_000, isInline: false, ...over });
  assertEquals(isStubAttachment(att({})), 'application/pdf');
  assertEquals(isStubAttachment(att({ name: 'IMG_2231.JPG', contentType: 'image/jpeg' })), 'image/jpeg');
  assertEquals(isStubAttachment(att({ name: 'image.png', contentType: 'image/png', isInline: true, size: 22_909 })), null, 'a signature logo is not a stub');
  assertEquals(isStubAttachment(att({ name: 'image.png', contentType: 'image/png', isInline: true, size: 240_000 })), 'image/png', 'a pasted screenshot of the stub is');
  assertEquals(isStubAttachment(att({ name: 'stub.docx', contentType: 'application/msword' })), null);
  assertEquals(stubInvoices('Please find the attached paystub for the invoices INV-2026-569180, INV-2026-466262 and inv-2026-280644.'), ['INV-2026-569180', 'INV-2026-466262', 'INV-2026-280644']);
  assertEquals(stubInvoices('Please find the attached paystub for this invoice. Let us know the ETA'), []);
});

Deno.test('sent to the vendor: the exchange that led to the order's first document', () => {
  const at = (id: string, iso: string, from: string, to: string[], cc: string[] = [], draft = false) => ({
    id, sentDateTime: iso, isDraft: draft, from: { emailAddress: { address: from } },
    toRecipients: to.map(address => ({ emailAddress: { address } })), ccRecipients: cc.map(address => ({ emailAddress: { address } })),
  });
  const v = ['eemercantile.co'];
  const thread = [
    at('a', '2026-04-21T17:00:00Z', 'apurandare@hwoodgroup.com', ['jemma@eemercantile.co']),               // an April order, same thread
    at('b', '2026-04-23T17:00:00Z', 'jemma@eemercantile.co', ['apurandare@hwoodgroup.com']),
    at('c', '2026-09-30T16:00:00Z', 'apurandare@hwoodgroup.com', ['hursh@hwoodgroup.com'], ['jemma@eemercantile.co']), // this order's request (vendor on Cc)
    at('d', '2026-10-01T09:00:00Z', 'apurandare@hwoodgroup.com', ['jemma@eemercantile.co'], [], true),       // a draft
    at('e', '2026-10-02T15:00:00Z', 'apurandare@hwoodgroup.com', ['ap@hwoodgroup.com']),                     // a note to AP
    at('f', '2026-10-03T18:00:00Z', 'jemma@eemercantile.co', ['apurandare@hwoodgroup.com']),                 // the quote: the order's first document
    at('g', '2026-10-15T18:00:00Z', 'apurandare@hwoodgroup.com', ['jemma@eemercantile.co']),                 // later: "please send the invoice"
  ];
  assertEquals(sentToVendor(thread, v, new Set(['f']), '2026-10-03'), '2026-09-30T16:00:00Z', 'starts at this order, not April');
  assertEquals(sentToVendor(thread, v, new Set(), '2026-10-03'), '2026-09-30T16:00:00Z', 'the first document by its day when its e-mail is not in the thread');
  assertEquals(sentToVendor(thread.filter(m => m.id !== 'c'), v, new Set(['f']), '2026-10-03'), null, 'nothing from h.wood to the vendor before the quote: not known');
  assertEquals(sentToVendor(thread, v, new Set(['g']), '2026-08-31'), null, 'never after the first document (an invoice dated 8/31)');
  assertEquals(sentToVendor(thread, v, new Set(), null), null, 'no document, no anchor');
  assert(isToVendor(thread[2], v) && !isToVendor(thread[3], v) && !isToVendor(thread[4], v) && !isToVendor(thread[1], v));
});

Deno.test('the e-mail day replaces the sheet / PO day only when earlier and near the first document', () => {
  assert(takeEmailSentDay('2026-09-28', '2026-10-05', '2026-10-05'), 'the request a week before the PO date');
  assert(takeEmailSentDay('2026-10-06', null, '2026-10-21'), 'no day yet');
  assert(!takeEmailSentDay('2026-10-12', '2026-09-28', '2026-10-13'), 'later than the sheet: a follow-up');
  assert(!takeEmailSentDay('2026-04-21', '2026-08-16', '2026-08-16'), 'four months before the invoice: a thread busy since spring');
  assert(!takeEmailSentDay(null, '2026-08-16', '2026-08-16'));
});
