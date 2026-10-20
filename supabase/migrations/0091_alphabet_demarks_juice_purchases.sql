-- =============================================================================
--  0091_alphabet_demarks_juice_purchases   (DATA)
--
--  Alphabet (v12): every Demarks Ice and Spirits invoice line reaches KevaOS as
--  an R365 placeholder ("Missing Vendor Item - Bar Consumables (5315)") with
--  only qty and price, so juice purchases never reached the counted juices and
--  their variance ran on purchases = 0. Price alone cannot tell them apart:
--  lemon and lime are both $45 a 3L pouch; grapefruit, orange and pineapple
--  are all $42.
--
--  SOURCE: h.wood AP's daily "Item Missing in Archimedes" reports
--  (hwoodap@iqbackoffice.com) name the products on each Demarks invoice:
--    105756 Standard Cube 2X2X2, Pineapple 3L Pouch, Lemon 3L Pouch   (report 9/8)
--    105821 Lemon, Lime, Pineapple 3L Pouch                            (report 9/15)
--    105846 Orange, Lemon, Lime 3L Pouch                               (report 9/18)
--    105743 Orange, Lemon 3L Pouch                                     (report 9/18)
--    105697 Orange, Lime, Lemon, Grapefruit 3L Pouch                   (report 9/21)
--    105886 Lemon, Grapefruit 3L Pouch                                 (report 9/28)
--    105932 Lime 3L Pouch, Standard Cube                               (report 10/3)
--  On all five invoices where price alone is unambiguous, R365's line import
--  order matches AP's product order exactly (e.g. 105756 = $55, $42, $45 =
--  cube, pineapple, lemon). That order resolves the two ambiguous invoices:
--    105697  3x$42, 8x$45, 8x$45, 5x$42 -> orange 3, lime 8, lemon 8, grapefruit 5
--    105821  4x$45, 3x$45, 1x$49        -> lemon 4, lime 3, pineapple 1 ($49)
--
--  UNITS = counted units the line holds. Lemon/Lime/Orange/Grapefruit are
--  counted in LITRES (the 1L items), so a 3L pouch = 3 units; Pineapple is
--  counted per 3L pouch, so 1 unit.
--
--  NOT MAPPED: the ice lines ($55 "Standard Cube 2X2X2" is not an item Alphabet
--  counts and its pack size is unknown) and 105743's $15 "Bar Consumables" line.
--
--  Read by compute_avt_for_audit (0071) on the next compute for v12.
--  ROLLBACK: 0091_ROLLBACK_alphabet_demarks_juice_purchases.sql
-- =============================================================================
begin;

insert into public.kount_invoice_line_map (venue_id, invoice_line_id, master_item_id, units, confidence, evidence, set_by)
select 'v12', v.line_id, v.mid, v.units, v.conf, v.ev, 'claude 2026-10-19 (Demarks juices, AP item-missing reports)'
  from (values
  -- 105756 (8/31): Standard Cube, Pineapple, Lemon
  ('0f45668b-0961-4264-aafd-8f8f46246fc1'::uuid, 'd39f6dc1-3fc2-4f63-afae-110dde67da39'::uuid,  4::numeric, 'code',   'Demarks 105756 line 2: 4 x $42 Pineapple 3L Pouch (AP report 9/8; only $42 item) = 4 pouches'),
  ('9e0641f7-bdca-4dff-92cf-c334486dc0fc'::uuid, '29a5d1f8-7abe-4840-82e3-d1937ac43e78'::uuid, 18::numeric, 'code',   'Demarks 105756 line 3: 6 x $45 Lemon 3L Pouch (AP report 9/8; only $45 item) = 18 L'),
  -- 105821 (9/10): Lemon, Lime, Pineapple; lemon/lime split by line order
  ('2fb31293-1b09-4fe3-ab41-49c1f4113de8'::uuid, '29a5d1f8-7abe-4840-82e3-d1937ac43e78'::uuid, 12::numeric, 'manual', 'Demarks 105821 line 1: 4 x $45 Lemon 3L Pouch (AP report 9/15 order Lemon, Lime, Pineapple = R365 line order) = 12 L'),
  ('3e8f2d69-c2c2-4b03-aa82-4779a67f2d41'::uuid, '113090cf-565f-470b-ac9a-b5dca89be420'::uuid,  9::numeric, 'manual', 'Demarks 105821 line 2: 3 x $45 Lime 3L Pouch (AP report 9/15 order) = 9 L'),
  ('00125af0-f792-4384-8c52-e87c5458c4ec'::uuid, 'd39f6dc1-3fc2-4f63-afae-110dde67da39'::uuid,  1::numeric, 'code',   'Demarks 105821 line 3: 1 x $49 Pineapple 3L Pouch (AP report 9/15; only non-$45 line) = 1 pouch'),
  -- 105846 (9/14): Orange, Lemon, Lime (both $45 lines are 2 pouches)
  ('85fba689-2d0b-497b-a537-0c3a4114f85b'::uuid, 'a9bb704b-5f10-45ba-96bd-8c2cacde3369'::uuid, 18::numeric, 'code',   'Demarks 105846 line 1: 6 x $42 Orange 3L Pouch (AP report 9/18; only $42 item) = 18 L'),
  ('8c6a06de-340a-498c-a2a0-fd2ab3408cf7'::uuid, '29a5d1f8-7abe-4840-82e3-d1937ac43e78'::uuid,  6::numeric, 'code',   'Demarks 105846 line 2: 2 x $45 Lemon 3L Pouch (AP report 9/18; lemon and lime are both 2 pouches) = 6 L'),
  ('a1fa8eca-dc08-476b-98d9-ece5ecbb5ce6'::uuid, '113090cf-565f-470b-ac9a-b5dca89be420'::uuid,  6::numeric, 'code',   'Demarks 105846 line 3: 2 x $45 Lime 3L Pouch (AP report 9/18) = 6 L'),
  -- 105697 (9/20): Orange, Lime, Lemon, Grapefruit; orange/grapefruit split by line order
  ('2c792929-dad8-483d-b2d6-1b5f02afb920'::uuid, 'a9bb704b-5f10-45ba-96bd-8c2cacde3369'::uuid,  9::numeric, 'manual', 'Demarks 105697 line 1: 3 x $42 Orange 3L Pouch (AP report 9/21 order Orange, Lime, Lemon, Grapefruit = R365 line order) = 9 L'),
  ('3960a3d4-3be9-44b1-a180-91ae2c67e6a0'::uuid, '113090cf-565f-470b-ac9a-b5dca89be420'::uuid, 24::numeric, 'code',   'Demarks 105697 line 2: 8 x $45 Lime 3L Pouch (AP report 9/21; both $45 lines are 8 pouches) = 24 L'),
  ('777c3f1f-7d52-4946-aef2-febcd758a707'::uuid, '29a5d1f8-7abe-4840-82e3-d1937ac43e78'::uuid, 24::numeric, 'code',   'Demarks 105697 line 3: 8 x $45 Lemon 3L Pouch (AP report 9/21) = 24 L'),
  ('1bab69c5-9936-403f-b1d8-d041546410d2'::uuid, '98667c2c-6f75-4e05-ba7f-03cc1ef6b068'::uuid, 15::numeric, 'manual', 'Demarks 105697 line 4: 5 x $42 Grapefruit 3L Pouch (AP report 9/21 order) = 15 L'),
  -- 105886 (9/21): Lemon, Grapefruit
  ('0ec61c17-526a-4bd8-bca9-d9eb8b1ca4f3'::uuid, '29a5d1f8-7abe-4840-82e3-d1937ac43e78'::uuid, 60::numeric, 'code',   'Demarks 105886 line 1: 20 x $45 Lemon 3L Pouch (AP report 9/28; only $45 item) = 60 L'),
  ('c8894899-8a9b-4263-b9f6-a2d67d7f5134'::uuid, '98667c2c-6f75-4e05-ba7f-03cc1ef6b068'::uuid, 15::numeric, 'code',   'Demarks 105886 line 2: 5 x $42 Grapefruit 3L Pouch (AP report 9/28; only $42 item) = 15 L'),
  -- 105743 (9/23): Orange, Lemon (+ an unmapped $15 named line)
  ('0b7ebc4c-6040-4440-8c60-66f7707d700a'::uuid, 'a9bb704b-5f10-45ba-96bd-8c2cacde3369'::uuid,  6::numeric, 'code',   'Demarks 105743 line 1: 2 x $42 Orange 3L Pouch (AP report 9/18; only $42 item) = 6 L'),
  ('38f4f47f-039e-41b2-838d-1a312a78c142'::uuid, '29a5d1f8-7abe-4840-82e3-d1937ac43e78'::uuid,  9::numeric, 'code',   'Demarks 105743 line 2: 3 x $45 Lemon 3L Pouch (AP report 9/18; only $45 item) = 9 L'),
  -- 105932 (9/29): Lime, Standard Cube
  ('7eab7a7e-7538-48f9-8c36-f1a85631da89'::uuid, '113090cf-565f-470b-ac9a-b5dca89be420'::uuid, 15::numeric, 'code',   'Demarks 105932 line 1: 5 x $45 Lime 3L Pouch (AP report 10/3; only $45 item) = 15 L')
  ) v(line_id, mid, units, conf, ev)
on conflict (venue_id, invoice_line_id, master_item_id) do nothing;

select m.name, count(*) lines, sum(x.units)::text units
  from public.kount_invoice_line_map x join public.master_items m on m.id = x.master_item_id
 where x.set_by = 'claude 2026-10-19 (Demarks juices, AP item-missing reports)'
 group by m.name order by m.name;
commit;
