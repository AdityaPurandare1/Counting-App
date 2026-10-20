-- =============================================================================
--  0096_little_luck_costs_deeper_invoice_search   (DATA)
--
--  After 0093-0095, 102 of LL-038's 325 products still had no cost: none was on
--  an itemised Little Luck invoice line linked to that product. A deeper search
--  of every invoice line in KevaOS (all venues, by link and by name) found two
--  kinds of evidence:
--    A) Little Luck's OWN lines linked to a DUPLICATE catalog product (the
--       invoice says "Midori Melon Liqueur 750ml", the count says "Midori
--       750ml"; same for Daiyame, Caffo, Pierre Peters, Dolin Genepy, Jager,
--       Tobiroku, Diet Coke, Haku Yuzu) -- mapped venue-scoped, with the pack,
--       so the nightly job prices them and variance credits the purchases.
--       The catalog itself is not changed.
--    B) Products bought only at other h.wood venues -- Little Luck's cost set
--       from the newest sensible invoice line there, each line read for pack
--       (cu_qty, "1/6", "12/750", or per bottle); the source text names venue,
--       vendor, date, line and arithmetic.
--  Still NO invoice evidence anywhere (left uncosted): the 6 (Prep) batches
--  (recipe-costed), Brucato x2, Kuleana, Zucca, Guillotine, Fernet Vallet,
--  Empirical, Combier Cassis, Ambros, El Tesoro Don Felipe, Nankai, Mizu Green
--  Tea / Sakura, Kikusui, Calpico, Kokuto, Sakura Bitters, Agara Yuzu Ale,
--  Kirin, Yamazaki Distiller's Reserve and the three 22yr, Littorai Haven 1.5L,
--  Mio Sparkling, Von Winning Riesling, Roots Divino Rosso. Ambiguous packs,
--  not guessed: Bouchard Le Corton / Clos de la Mousse 1.5L, Chevalier de
--  Lascombes, Blue Cheese Olives (64oz jar vs a 1lb item), Sabroso!, 818
--  Blanco. Giffard Passion is held back: counted as 50ml minis on a 750ml item.
--  ROLLBACK: 0096_ROLLBACK_little_luck_costs_deeper_invoice_search.sql
-- =============================================================================
begin;

-- A) Little Luck's own lines linked to a duplicate catalog product: map the vendor
--    item to the product Little Luck counts, with its pack.
insert into public.kount_invoice_item_map (venue_id, purchase_item_id, master_item_id, units_per_case, note, set_by)
select 'v11', v.pid, v.mid, v.units, v.note, 'claude 2026-10-20 (LL dup-linked lines)'
  from (values
  ('a6978ce1-8501-492c-a114-182c651e7470'::uuid, 'f1cbd3cf-0660-48dc-85c4-21c1a710dc85'::uuid, 12, 'Grand Cru CASO37568-01 $660.00 = 12-pack ($55.00)'),
  ('a6978ce1-8501-492c-a114-182c651e7470'::uuid, '06cbd606-91ff-4a40-8086-a9aa7b1cd169'::uuid, 12, 'Grand Cru CASO37568-01 $660.00 = 12-pack ($55.00)'),
  ('f2bed7b6-2e1f-49d6-9b1f-dfe22e904293'::uuid, 'dee4339d-e59e-4b1c-876f-c5bfbeeb82db'::uuid, 12, 'USA Wine West JSC000063172 "12/300ml" $145.50 ($12.13)'),
  ('33a17556-3223-498d-8d13-d31916d82273'::uuid, '956ad607-2d73-4411-950c-4d28cb1254eb'::uuid, 24, 'Kevidko "6/4/CS" $37.99 = 24 ($1.58)'),
  ('0d360223-1c95-4c9a-b377-7624f2aa614f'::uuid, '37ad946e-f570-4bce-96a4-c78482c86b8c'::uuid, 12, 'Pacific Edge 450518 $282.00 = 12-pack ($23.50)'),
  ('8f1fb809-e9cf-4660-aa0f-a19bf65f5b0b'::uuid, '0a921286-a5e5-4168-9aaf-9b68b615ce98'::uuid, 12, 'Grand Cru CASO37568-01 Federspiel Ried Klaus $288.00 = 12-pack ($24.00)'),
  ('b668f241-fa05-4853-ab48-6acaa22174fd'::uuid, 'aeab2dd6-f739-4dd6-a614-85efa069f113'::uuid, 1, 'SGWS 2681620 6 x $19.83: per bottle'),
  ('ddb85cfc-43a2-4f91-9495-b1c6fd1214c5'::uuid, 'dedba732-726e-45a4-8e33-de2cc14be7aa'::uuid, 6, 'Skurnik 284443 "6/900" 4 x $150.00 = 6-packs ($25.00)'),
  ('7ecf7a24-c785-46c6-ab49-fb687475e945'::uuid, 'b746917f-16ec-4f71-90ae-97d4fdd36491'::uuid, 1, 'Skurnik 284443 6 x $20.00: per bottle'),
  ('c9742be1-3769-43ee-947b-2927bede90b6'::uuid, 'da6d10e7-ccd8-4c3a-8c03-7a669f7dde0f'::uuid, 6, 'SGWS 2681620 $126.00 = 6-pack ($21.00)'),
  ('c9742be1-3769-43ee-947b-2927bede90b6'::uuid, 'd6dbd242-3713-40b0-a1d3-c75ecd87993c'::uuid, 6, 'SGWS 2681620 $126.00 = 6-pack ($21.00)')
  ) v(pid, mid, units, note)
on conflict do nothing;

-- Choya has no vendor item at all (unlinked line): place the line itself. 1 case x 12 = 12 bottles.
insert into public.kount_invoice_line_map (venue_id, invoice_line_id, master_item_id, units, confidence, evidence, set_by)
values ('v11', '1c9d0a61-34a6-463a-a98b-c4e46a93008d'::uuid, '90b11579-8007-4c8b-a218-3027d135071d'::uuid, 12, 'manual',
        'Mutual Trading SILA00037324 "CHOYA WITH FRUIT PLUM WINE 12/750ml" 1 x $128.00 = 12 bottles ($10.67)',
        'claude 2026-10-20 (LL dup-linked lines)')
on conflict do nothing;

-- B) Products Little Luck has no itemised invoice for: its cost from the newest sensible
--    line on another h.wood venue's invoice. price_date = that invoice date and
--    is_manual false, so Little Luck's own (newer) invoice replaces it.
insert into public.kount_venue_cost_overrides (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v11', v.mid, v.cost, v.src, 'claude 2026-10-20 (other-venue invoices)', false, v.d, now()
  from (values
  ('87d01170-2286-4ba8-93ca-baa78c6a41cb'::uuid, 2.4992, date '2026-10-13', 'Other h.wood venue invoice: Bird Streets Club, Kevidko 2026-10-13 "ACQUA PANNA 1L (12/CS)" $29.99 / 12'),
  ('46dcd245-26cd-425d-aaec-ad7df8972cd4'::uuid, 24.75, date '2026-09-15', 'Other h.wood venue invoice: Delilah LA, Southern Wine & Spirits 2026-09-15 ANGOSTURA BITTERS $297.00 / 12'),
  ('6f864756-a1ef-4dcc-a25c-c6065d196fc9'::uuid, 26.5, date '2026-10-07', 'Other h.wood venue invoice: Nice Guy LA, Southern Wine & Spirits 2026-10-07 Bulleit Rye $26.50 per bottle'),
  ('cfe1aa09-cb51-4ef4-b1a7-aaf5f84b3a15'::uuid, 14.55, date '2026-09-24', 'Other h.wood venue invoice: Nice Guy LA, Harbor 2026-09-24 Carpano Dry Vermouth $14.55 per bottle'),
  ('805fe9d1-9007-4b3e-8e3d-4cca2f1f358c'::uuid, 24.8, date '2023-05-17', 'Other h.wood venue invoice: Bird Streets Club, RNDC 2023-05-17 Carpano Punt E Mes $24.80 per bottle (old price)'),
  ('99392c9c-97dd-43be-b402-7e5ad1685668'::uuid, 122.0, date '2026-09-16', 'Other h.wood venue invoice: Bird Streets Club, Southern Wine & Spirits 2026-09-16 CLASE AZUL TEQ PLATA $122.00 per bottle'),
  ('5c6d88f5-b5c8-4013-bef6-f006e3a7d078'::uuid, 8.4433, date '2026-09-23', 'Other h.wood venue invoice: Nice Guy LA, Southern Wine & Spirits 2026-09-23 Dirty Sue Olive Juice $101.32 / 12'),
  ('2244cb8d-3cab-4f3d-ac1f-4e19d624ccae'::uuid, 4.2217, date '2026-06-05', 'Other h.wood venue invoice: Bird Streets Club, Southern Wine & Spirits 2026-06-05 Dirty Sue Olive Juice 375ml $50.66 / 12'),
  ('ec273b01-223f-4b4f-860e-f71a9018558b'::uuid, 28.08, date '2025-10-09', 'Other h.wood venue invoice: Nice Guy LA, Southern Wine & Spirits 2025-10-09 Dom Benedictine $28.08 per bottle'),
  ('5d3cbbb5-fd31-4bde-be37-04e3d9235663'::uuid, 18.95, date '2026-06-02', 'Other h.wood venue invoice: Delilah Miami, Superior Superfoods 2026-06-02 Edible Flower Mix $18.95 each'),
  ('3897a88e-c857-4c0a-8097-2576fdef2a12'::uuid, 15.06, date '2026-09-17', 'Other h.wood venue invoice: Delilah LA, Vesta 2026-09-17 EDIBLE FLOWER-VIOLAS $15.06 each'),
  ('e32d490b-b56d-4dc1-9787-579954016bf5'::uuid, 17.1, date '2026-10-15', 'Other h.wood venue invoice: Delilah LA, Vesta 2026-10-15 EDIBLE FLOWER-MICRO $17.10 each'),
  ('8d3a4dbb-c270-4c7f-89c7-b4f20e07a91c'::uuid, 16.34, date '2024-07-08', 'Other h.wood venue invoice: Bird Streets Club, Vesta 2024-07-08 Pansies, Edible Flowers $16.34 each'),
  ('8671b401-f170-487d-9454-8ebf5356c670'::uuid, 0.9458, date '2026-10-01', 'Other h.wood venue invoice: Little Luck''s own Fever-Tree 200ml price: Beauchamp $22.70 / 24 (same as its Ginger Ale / Ginger Beer / Club Soda 200ml)'),
  ('c103d565-e86a-4a63-9e48-6d89eb40c22a'::uuid, 26.5, date '2024-03-26', 'Other h.wood venue invoice: Delilah Miami, Breakthru 2024-03-26 Giffard Banane $159.00 / 6'),
  ('c185606d-22c7-4f49-9171-078331886b65'::uuid, 16.83, date '2023-05-05', 'Other h.wood venue invoice: Nice Guy LA, RNDC 2023-05-05 Giffard Coconut $16.83 per bottle (old price)'),
  ('3f3a875f-d27b-42ee-b10b-6973e98ecaf0'::uuid, 27.43, date '2026-07-10', 'Other h.wood venue invoice: Poppy, Harbor 2026-07-10 GIFFARD MANGUE B6 750ML $27.43 per bottle'),
  ('c2836083-4943-4c80-8fa4-e8dfd984b95d'::uuid, 17.68, date '2025-07-03', 'Other h.wood venue invoice: Nice Guy LA, RNDC 2025-07-03 Giffard Orgeat $17.68 per bottle'),
  ('ff8959fe-0790-4ff7-a0ec-036f77d2b446'::uuid, 21.8333, date '2023-07-21', 'Other h.wood venue invoice: Nice Guy LA, RNDC 2023-07-21 Giffard Rhubarb $131.00 / 6 (old price)'),
  ('fdf6ac46-61bd-488e-b311-00ff40aceab8'::uuid, 562.49, date '2026-03-04', 'Other h.wood venue invoice: Delilah LA, Southern Wine & Spirits 2026-03-04 Hakushu 18yr $562.49 per bottle'),
  ('c061b34d-2c58-4eb3-b569-4997602997d5'::uuid, 51.0, date '2026-09-16', 'Other h.wood venue invoice: Bird Streets Club, Southern Wine & Spirits 2026-09-16 HEAVENSAKE URAKASUMI $306.00 / 6'),
  ('b6b776b0-e04e-4fb4-a308-33a8c89a3b75'::uuid, 24.6667, date '2024-05-02', 'Other h.wood venue invoice: Bird Streets Club, Grand Cru 2024-05-02 Hermann Ludes Thornicher Ritsch $296.00 / 12'),
  ('13c831da-d84c-4543-89aa-fca513c50ed5'::uuid, 23.0, date '2026-07-10', 'Other h.wood venue invoice: Bird Streets Club, Skurnik 2026-07-10 Kafe Anme $23.00 per bottle'),
  ('e4a7ccb0-b46d-4282-b0ee-abe9908fad4a'::uuid, 23.0, date '2026-07-10', 'Other h.wood venue invoice: Bird Streets Club, Skurnik 2026-07-10 Zoranj Anme $23.00 per bottle'),
  ('6c36c6c1-391c-49c8-8e80-4b73a8dbc176'::uuid, 27.0, date '2026-07-10', 'Other h.wood venue invoice: Bird Streets Club, Skurnik 2026-07-10 Yuzu Liqueur, OKA BRAND $27.00 per bottle'),
  ('b7284393-b003-4da7-80fc-e84d13e36f54'::uuid, 23.0, date '2026-07-10', 'Other h.wood venue invoice: Bird Streets Club, Skurnik 2026-07-10 Sweet Sake Vermouth ''Japanese Bermutto'' OKA BRAND $23.00 per bottle'),
  ('b71690b4-54cc-4733-970d-212eec678765'::uuid, 35.2, date '2025-11-25', 'Other h.wood venue invoice: Bird Streets Club, SGWS 2025-11-25 KNOB CREEK RYE $35.20 per bottle'),
  ('3d0b74af-7851-4039-ab13-8f1021242728'::uuid, 20.0, date '2026-09-29', 'Other h.wood venue invoice: Delilah Miami, SGWS 2026-09-29 LIQUID ALCHEMIST ORGEAT 1/6 $120.00 / 6'),
  ('2e80d269-308b-4130-9bfb-4912dfe2b4a7'::uuid, 20.5, date '2025-08-13', 'Other h.wood venue invoice: Delilah Miami, SGWS 2025-08-13 Minuty ''Prestige Blanc'' $123.00 / 6'),
  ('1cf44429-c16d-4b10-a97f-2c3baa53432f'::uuid, 21.53, date '2026-09-27', 'Other h.wood venue invoice: Delilah Dallas, Spec''s 2026-09-27 MR. BLACK 750ML 6 x $21.53 per bottle'),
  ('a2c83145-c672-48e8-9627-ad81fe0ae6ed'::uuid, 65.2, date '2025-08-13', 'Other h.wood venue invoice: Delilah LA, Southern Wine & Spirits 2025-08-13 Pernod Absinthe $65.20 per bottle'),
  ('d8a8132b-1fab-44b8-8175-e43508422589'::uuid, 24.2, date '2024-10-01', 'Other h.wood venue invoice: Catering, SGWS 2024-10-01 PLANTATION XAYMACA $24.20 per bottle'),
  ('cf513f42-ed28-4a52-967a-aa558b8ba144'::uuid, 187.7775, date '2024-05-10', 'Other h.wood venue invoice: Delilah LA, RNDC 2024-05-10 Remy Martin Night XO $2,253.33 / 12'),
  ('fd8c0216-6f73-40fd-b631-ceef9526d22d'::uuid, 44.75, date '2026-10-14', 'Other h.wood venue invoice: Bird Streets Club, Southern Wine & Spirits 2026-10-14 RON ZACAPA 23YR $44.75 per bottle'),
  ('f528acb7-326c-419a-83b6-69ab575aff8f'::uuid, 1.08, date '2026-10-12', 'Other h.wood venue invoice: Bird Streets Club, Mutual Trading 2026-10-12 Sapporo $12.96 / 12'),
  ('bbf9e1b2-8fa9-4711-8140-18d7709c1deb'::uuid, 8.0, date '2025-09-16', 'Other h.wood venue invoice: Delilah Miami, SGWS 2025-09-16 St Germain 1/12 375ml $96.00 / 12'),
  ('24d05996-1582-43e4-959d-e2209d490a0b'::uuid, 47.97, date '2026-07-28', 'Other h.wood venue invoice: Delilah Miami, The Chef''s Warehouse 2026-07-28 BOIRON SUDACHI PUREE $47.97 each'),
  ('7d9feed3-7b86-4f45-a031-192a568cbbfd'::uuid, 47.1, date '2026-02-26', 'Other h.wood venue invoice: Delilah Miami, SGWS 2026-02-26 SWEETENS COVE 750ML $47.10 per bottle'),
  ('253d57f3-bac6-4aea-aab4-48e2837826e9'::uuid, 45.75, date '2023-04-03', 'Other h.wood venue invoice: Bird Streets Club, Thatchers Wine 2023-04-03 Verget Pouilly-Fuisse Les Combes $45.75 per bottle'),
  ('e6f35bd2-d49f-4900-9577-cb88670905cd'::uuid, 597.49, date '2026-09-11', 'Other h.wood venue invoice: Bird Streets Club, Southern Wine & Spirits 2026-09-11 Yamazaki 18yr $597.49 per bottle'),
  ('407340ec-c148-47d3-8567-d4a4d0fc36ae'::uuid, 4202.5, date '2026-09-01', 'Other h.wood venue invoice: Keys, Southern Wine & Spirits 2026-09-01 Yamazaki 25yr $4,202.50 per bottle'),
  ('2084e38b-833e-48e3-9f92-f0b31d511fbc'::uuid, 142.49, date '2026-09-16', 'Other h.wood venue invoice: Nice Guy LA, Southern Wine & Spirits 2026-09-16 Yamazaki 12yr $142.49 per bottle (standard 12yr)'),
  ('25b70268-27db-4902-b101-451bda0dd6d3'::uuid, 25.7, date '2024-03-20', 'Other h.wood venue invoice: Bird Streets Club, Boisson 2024-03-20 Almave Ambar $25.70 per bottle'),
  ('beb23fcb-09e0-43c8-aa64-e47467b36cfa'::uuid, 13.99, date '2026-06-23', 'Other h.wood venue invoice: Delilah Miami, Winebow 2026-06-23 DOLIN BLANC 3 x $13.99 per bottle'),
  ('d674dadf-e21e-49c4-8221-0b96cd26f699'::uuid, 17.5, date '2026-10-09', 'Other h.wood venue invoice: Bird Streets Club, Pacific Edge 2026-10-09 Dolin Dry $210.00 / 12'),
  ('2a71fe1a-e165-4943-a843-69eba65566a2'::uuid, 51.3333, date '2026-05-15', 'Other h.wood venue invoice: Nice Guy LA, Breakthru 2026-05-15 FELSINA RANCIA RISERVA 2020 $308.00 / 6'),
  ('54dc9a2d-5d5b-4db0-9d5c-0a545ebae4bb'::uuid, 65.0, date '2026-03-24', 'Other h.wood venue invoice: Bird Streets Club, Duckhorn Wine Co 2026-03-24 KOSTA BROWNE CERISE 2021 $780.00 / 12'),
  ('265cad0e-cd9c-4fdd-9294-6a8139d00e30'::uuid, 78.55, date '2024-09-27', 'Other h.wood venue invoice: Delilah Miami, SGWS 2024-09-27 Mayacamas Chardonnay $78.55 per bottle (vintage not stated)'),
  ('4a04503f-46cb-4581-b0a0-f48b4f7ebed7'::uuid, 135.0, date '2024-07-01', 'Other h.wood venue invoice: Bird Streets Club, Veritas 2024-07-01 JF Mugnier Chambolle Musigny $135.00 per bottle'),
  ('e0812f7a-48e3-4cf0-9026-b6c3a089a543'::uuid, 230.0, date '2024-07-01', 'Other h.wood venue invoice: Bird Streets Club, Veritas 2024-07-01 JF Mugnier ''Clos Marechale'' $230.00 (750ml is $115.00)'),
  ('24756ff6-dc26-4626-8ef7-88b22315e878'::uuid, 116.67, date '2026-03-17', 'Other h.wood venue invoice: Bird Streets Club, Mosaic Wine 2026-03-17 PAUL PERNOT FOLATIERES 2024 12/750 6 x $116.67 per bottle')
  ) v(mid, cost, d, src)
on conflict (venue_id, master_item_id) do nothing;

select (select count(*) from public.kount_invoice_item_map where set_by = 'claude 2026-10-20 (LL dup-linked lines)') item_maps,
       (select count(*) from public.kount_invoice_line_map where set_by = 'claude 2026-10-20 (LL dup-linked lines)') line_maps,
       (select count(*) from public.kount_venue_cost_overrides where set_by = 'claude 2026-10-20 (other-venue invoices)') other_venue_costs;
commit;
