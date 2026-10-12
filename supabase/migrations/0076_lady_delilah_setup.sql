-- =============================================================================
--  0076_lady_delilah_setup  (DATA, not schema)
--
--  Puts Lady Delilah (Delilah New York; KevaOS venue a681b43a-5cba-4656-b8bd-ae6d86e744c0, Toast, 50 9th Ave NYC, not yet
--  open) into the counting system the way Alphabet is set up, from the first batch of opening
--  deliveries: four Southern Glazer's NY draft invoices dated 10/8-10/9 (611 bottles, 76 products,
--  $31,809.80). "Delilah New York" (0d2907c8..., inactive CSV placeholder) is NOT used.
--
--  1. kount_venues v14 'Lady Delilah' -> ops venue; depletion_source item_day_facts (Toast daily
--     aggregates, as Alphabet); purchase_mapping venue_item_map (venue-scoped invoice maps, venue
--     costs first, counted-scope report -- 0064/0071/0073/0074). Zones are a starting set; rename
--     or merge them in the admin once the floor plan is known.
--  2. procurement_kount_venue_map row (as Bar Shishi 0065).
--  3. 3 new master_items (no catalog item at that size): Bulleit 95 Rye 10yr 750ml, Luxardo
--     Maraschino 375ml, Mount Gay Silver 750ml. The other 73 products reuse existing items.
--  4. venue_item_settings (no PAR) for all 76 items.
--  5. kount_venue_cost_overrides v14: net per-bottle cost from each invoice line, is_manual=false,
--     price_date = invoice date, so real R365 invoice costs replace them as they arrive.
--  NOT loaded as count entries: these are deliveries. Once they reach R365 they are purchases in
--  Lady Delilah's first count (no previous audit = all purchases up to that close).
--  ROLLBACK: 0076_ROLLBACK_lady_delilah_setup.sql
-- =============================================================================
begin;

insert into public.kount_venues (id, name, address, default_zones, store_aliases, ordinal, is_active, ops_venue_id, depletion_source, purchase_mapping)
values ('v14', 'Lady Delilah', '50 9th Ave, New York, NY 10011',
        array['Bar','Back Bar','Well','Liquor Room','Bar Fridges','Champagne Fridge','Wine Room','Walk-In Fridge','Office Safe','Storage'],
        array['lady delilah','delilah new york','delilah nyc','delilah ny','lady delilah nyc'], 140, true, 'a681b43a-5cba-4656-b8bd-ae6d86e744c0', 'item_day_facts', 'venue_item_map')
on conflict (id) do nothing;

insert into public.procurement_kount_venue_map (kount_venue_id, venue_id, note)
values ('v14', 'a681b43a-5cba-4656-b8bd-ae6d86e744c0', 'Lady Delilah — created 2026-10-09 from the SGWS NY opening invoices')
on conflict (kount_venue_id) do nothing;

insert into public.master_items (name, category, base_size, base_unit, organization_id, is_active)
values ('Bulleit 95 Rye 10yr 750ml', 'Liquor Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true), ('Luxardo Maraschino 375ml', 'Liquor Cost', 375, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true), ('Mount Gay Silver 750ml', 'Liquor Cost', 750, 'ml', '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41', true)
on conflict (organization_id, name, category) do nothing;

create temp table _ld (mid uuid, cost numeric, source text, price_date date) on commit drop;
insert into _ld values
  ('1db561f9-7138-4c2f-9b86-e817a37cc40e'::uuid, 734.6500::numeric, 'SGWS NY draft invoice #2678155 2026-10-08 item# 366673 "HIBIKI WHISKY 21YR 86" 3 btl @ $734.65/btl net', date '2026-10-08'),
  ('adfb34d3-3947-4e97-b892-7d951d11fdea'::uuid, 28.0000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 557367 "APEROL APERITIVO 22" 12 btl @ $28.00/btl net', date '2026-10-08'),
  ('938fb6b8-85fe-4eef-be2f-0d83d4cfa40f'::uuid, 39.2800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 387851 "BLADE & BOW BBN 91" 12 btl @ $39.28/btl net', date '2026-10-08'),
  ('c4c4949b-0845-4490-bbb3-8b4406f470dc'::uuid, 38.6300::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 352429 "BULLEIT BOURBON 90" 12 btl @ $38.63/btl net', date '2026-10-08'),
  ((select id from public.master_items where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41' and name = 'Bulleit 95 Rye 10yr 750ml' and category = 'Liquor Cost' and is_active), 37.7800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 634645 "BULLEIT 95 RYE 10YR 91.2" 12 btl @ $37.78/btl net', date '2026-10-08'),
  ('d992c4a7-1268-458a-a804-90bdc9415f62'::uuid, 36.0000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 606739 "CAMPARI APERITIVO 48" 6 btl @ $36.00/btl net', date '2026-10-08'),
  ('f5bb589e-8e9d-440e-903a-03b91d182f8f'::uuid, 59.8200::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 904165 "CASAMIGOS MEZCAL JOVEN 80" 6 btl @ $59.82/btl net', date '2026-10-08'),
  ('fd839573-3a1a-41de-9336-b2561bd774a3'::uuid, 37.8800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 446128 "CASAMIGOS TEQUILA BLANCO 80" 30 btl @ $37.88/btl net', date '2026-10-08'),
  ('11b9d430-885f-4c15-ba96-e7e707f390ac'::uuid, 41.6300::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 446127 "CASAMIGOS TEQUILA REPOSADO 80" 24 btl @ $41.63/btl net', date '2026-10-08'),
  ('60d6ced8-d028-4990-88da-440a6884c540'::uuid, 23.0000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 655521 "CHABLISIENNE LA PIERRELEE 22" 24 btl @ $23.00/btl net -- wine', date '2026-10-08'),
  ('a588ce3b-28ee-4a12-8788-14c37e7051c1'::uuid, 56.5300::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 624006 "DON JULIO TEQ ANEJO 70TH ANN" 6 btl @ $56.53/btl net', date '2026-10-08'),
  ('d103ec46-67d5-47b8-9c1a-43bd60cd7aa2'::uuid, 42.2800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 971837 "DON JULIO TEQ REPOSADO 80" 24 btl @ $42.28/btl net', date '2026-10-08'),
  ('1a59437d-c5a2-43dd-b6f7-ca40270eef82'::uuid, 295.4100::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 449741 "DON JULIO TEQ 1942 80" 4 btl @ $295.41/btl net', date '2026-10-08'),
  ('a2bc7577-514c-47c3-ab76-333ccc152ff0'::uuid, 133.0300::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 411403 "DON JULIO TEQ 1942 80 YRC" 18 btl @ $133.03/btl net', date '2026-10-08'),
  ('78ec2743-3f26-4dd8-9c80-b0d9e561de9e'::uuid, 45.6600::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 893113 "EL TESORO TEQ BLANCO 80" 6 btl @ $45.66/btl net', date '2026-10-08'),
  ('437161a7-db59-41f8-98cd-fd904f8d95f4'::uuid, 57.2000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 911824 "EL TESORO TEQ REPOSADO 80" 6 btl @ $57.20/btl net', date '2026-10-08'),
  ('28ed14ac-a99e-429a-b91b-6b6cacf50c74'::uuid, 14.6500::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 481187 "GIULIANA PROSECCO" 24 btl @ $14.65/btl net -- wine', date '2026-10-08'),
  ('ea38a945-b29f-4162-9a4c-f29d82ef23f0'::uuid, 69.5100::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 389170 "HIBIKI WHISKY JAPANESE HARMONY" 6 btl @ $69.51/btl net', date '2026-10-08'),
  ('e2a6d558-83ee-469f-8a82-c9f9f1ca4a01'::uuid, 62.0000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 650805 "IL POGGIONE BRUN DI MONT 20" 6 btl @ $62.00/btl net -- wine', date '2026-10-08'),
  ('49e91991-3eca-4383-87fd-aed4f93a176c'::uuid, 30.8800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 36126 "KETEL ONE VODKA 80" 48 btl @ $30.88/btl net', date '2026-10-08'),
  ('7b2d3a25-341a-4e03-9dd6-afb3e59012bd'::uuid, 26.6700::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 550224 "LOBOS 1707 TEQ JOVEN 80" 6 btl @ $26.67/btl net', date '2026-10-08'),
  ('16d0ee08-a2bc-4f2b-ba2f-803a0786a650'::uuid, 38.7700::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 601092 "LOBOS 1707 TEQ REPOSADO 80" 6 btl @ $38.77/btl net', date '2026-10-08'),
  ('e5c5d09f-949e-47c8-b4e8-a7c4a4e86cb4'::uuid, 24.2800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 636668 "MR BLACK COFFEE LIQUEUR 50" 18 btl @ $24.28/btl net', date '2026-10-08'),
  ('eccf40fb-ea67-4e89-9ae8-f4b814f2400a'::uuid, 28.0000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 947163 "NONINO L''APERITIVO 42" 6 btl @ $28.00/btl net', date '2026-10-08'),
  ('61ccf4dd-118d-45b0-ab3d-bc6d6548d2a1'::uuid, 37.1300::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 655169 "ROSALUNA MEZCAL JOVEN(ORG)80" 6 btl @ $37.13/btl net', date '2026-10-08'),
  ('f404645f-7754-4b15-9bcb-3e3c3ee94005'::uuid, 28.1700::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 175921 "ST GERMAIN LIQUEUR 40" 18 btl @ $28.17/btl net', date '2026-10-08'),
  ('cca37bff-7c25-4396-9580-5a0ea5b7840b'::uuid, 27.2000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 638219 "STILL G.I.N. DRY GIN 85" 6 btl @ $27.20/btl net', date '2026-10-08'),
  ('d6dbd242-3713-40b0-a1d3-c75ecd87993c'::uuid, 24.2200::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 964280 "SUNTORY HAKU VODKA 80" 6 btl @ $24.22/btl net', date '2026-10-08'),
  ('b55f9964-46c0-42c8-ad33-3c9f4c1c2ac2'::uuid, 31.1400::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 597885 "SUNTORY ROKU GIN 86" 6 btl @ $31.14/btl net', date '2026-10-08'),
  ('71fa4736-713c-42be-a471-dc6cbb38d21b'::uuid, 39.6000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 916648 "SUNTORY WHISKY TOKI 86" 6 btl @ $39.60/btl net', date '2026-10-08'),
  ('be711154-6432-4024-bd28-5e6b1021e3da'::uuid, 26.5800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 636855 "TANQUERAY GIN 94.6" 24 btl @ $26.58/btl net', date '2026-10-08'),
  ('cdb01060-ea48-413d-8d8d-51a30e830d1b'::uuid, 37.0000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 517026 "TELMONT BRUT RSV HERITAGE" 30 btl @ $37.00/btl net -- wine', date '2026-10-08'),
  ('65b1e21a-1d13-4c5a-a362-8ac0e837fd82'::uuid, 16.0800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 74001 "TIO PEPE SHERRY FINO" 12 btl @ $16.08/btl net', date '2026-10-08'),
  ('3f7469d8-9e57-4ff8-9916-986ac06fb3fa'::uuid, 43.3500::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 332775 "BAILEYS IRISH CREAM 34" 2 btl @ $43.35/btl net', date '2026-10-08'),
  ('d8078b79-b487-4a1e-bbf6-6128e4ae9a6f'::uuid, 73.1000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 704412 "BOOKERS BBN MILKSHAKE 2026-2" 2 btl @ $73.10/btl net', date '2026-10-08'),
  ('f89b648e-0297-4fc3-b0e2-61eedccac4ab'::uuid, 50.4800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 446125 "CASAMIGOS TEQUILA ANEJO 80" 2 btl @ $50.48/btl net', date '2026-10-08'),
  ('c34dca95-9a11-4610-8274-a54c527d5a7e'::uuid, 36.5900::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 613713 "CHAMBORD LIQ 33" 1 btl @ $36.59/btl net', date '2026-10-08'),
  ('92b4ffd1-7b7b-4751-a1e6-4dc12ff876f5'::uuid, 47.9800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 991348 "GRAND MARNIER 80" 3 btl @ $47.98/btl net', date '2026-10-08'),
  ('fdf6ac46-61bd-488e-b311-00ff40aceab8'::uuid, 619.2600::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 942532 "HAKUSHU WSKY SINGLE MALT 18Y" 1 btl @ $619.26/btl net', date '2026-10-08'),
  ('3bd370b9-b29a-4937-a928-db2e0f0b38d0'::uuid, 29.3300::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 975690 "JIM BEAM BOURBON 80" 6 btl @ $29.33/btl net', date '2026-10-08'),
  ('c12c67ce-8b31-444a-a032-cc3bc944ac35'::uuid, 54.2300::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 24672 "JOHNNIE WALKER BLACK 80 BAR" 6 btl @ $54.23/btl net', date '2026-10-08'),
  ('360da911-dbca-4ceb-bb4e-4111c12a6e47'::uuid, 178.8800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 402745 "JOHNNIE WALKER BLUE 80" 3 btl @ $178.88/btl net', date '2026-10-08'),
  ('9894504b-01b8-496d-ba18-267c84ee0be2'::uuid, 51.6000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 530397 "KNOB CREEK BBN 100" 2 btl @ $51.60/btl net', date '2026-10-08'),
  ('5285d8bb-063e-4963-8331-4128a3106b62'::uuid, 48.8700::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 581363 "KNOB CREEK RYE 7YR 100" 2 btl @ $48.87/btl net', date '2026-10-08'),
  ('1fd275b0-358f-4071-b0d0-22bbfc0c0b6d'::uuid, 77.3800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 693222 "LAGAVULIN SCO SMALT 16YR 86" 2 btl @ $77.38/btl net', date '2026-10-08'),
  ('2d679c87-e949-47ce-abec-ab014aa59e7c'::uuid, 61.5800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 631029 "LAPHROAIG SCO SMALT 10YR 86" 1 btl @ $61.58/btl net', date '2026-10-08'),
  ('6b40f894-26c1-4099-ae70-5b3672762dec'::uuid, 31.3000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 341716 "LICOR 43 62" 2 btl @ $31.30/btl net', date '2026-10-08'),
  ('434c30c5-d7cb-41a0-a865-5b0fc11214fc'::uuid, 25.2000::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 691614 "LILLET APERITIF BLANC" 2 btl @ $25.20/btl net', date '2026-10-08'),
  ((select id from public.master_items where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41' and name = 'Luxardo Maraschino 375ml' and category = 'Liquor Cost' and is_active), 25.0100::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 395281 "LUXARDO MARASCHINO 64" 2 btl @ $25.01/btl net', date '2026-10-08'),
  ('c40dfeb6-1e88-4374-9f6a-306fd9655e68'::uuid, 39.2600::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 650981 "LUXARDO MARASCHINO 64 6P" 2 btl @ $39.26/btl net -- highlighted on invoice', date '2026-10-08'),
  ('c51d0177-661b-4436-9748-2ea493f0b672'::uuid, 36.9400::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 930785 "MCQUEEN&THE VIOLET FOG GIN" 2 btl @ $36.94/btl net', date '2026-10-08'),
  ('bbf60e32-881e-443f-9281-978bd5b5b231'::uuid, 48.8800::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 16569 "NONINO AMARO QUINTESSENTIA" 2 btl @ $48.88/btl net', date '2026-10-08'),
  ('a2c83145-c672-48e8-9627-ad81fe0ae6ed'::uuid, 63.6400::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 324437 "PERNOD ABSINTHE 136" 2 btl @ $63.64/btl net', date '2026-10-08'),
  ('817a5996-e67b-4200-a1c6-1d482f2182df'::uuid, 138.4900::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 10761 "YAMAZAKI WSKY SMALT 12YR 86" 2 btl @ $138.49/btl net', date '2026-10-08'),
  ('563e76db-c178-4ab6-9a5b-621e75d585d6'::uuid, 32.2900::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 9998 "MAKERS MARK BOURBON 90" 5 btl @ $32.29/btl net', date '2026-10-08'),
  ('f3872cb1-5ab7-4585-89cb-a7b8c288293a'::uuid, 21.1400::numeric, 'SGWS NY draft invoice #10/8 main 2026-10-08 item# 618251 "JIM BEAM BBN BLACK 7YR 90" 1 btl @ $21.14/btl net', date '2026-10-08'),
  ('a6c077dc-890a-4f83-9480-cb41173acf92'::uuid, 37.1700::numeric, 'SGWS NY draft invoice #2678158 2026-10-08 item# 233901 "COINTREAU 80" 18 btl @ $37.17/btl net', date '2026-10-08'),
  ((select id from public.master_items where organization_id = '13dacb8a-d2b5-42b8-bcc3-50bc372c0a41' and name = 'Mount Gay Silver 750ml' and category = 'Liquor Cost' and is_active), 15.2800::numeric, 'SGWS NY draft invoice #2678158 2026-10-08 item# 696931 "MT GAY RUM SILVER 80" 12 btl @ $15.28/btl net', date '2026-10-08'),
  ('4ceb4123-a8db-483f-aa1b-4d374269d284'::uuid, 3360.4500::numeric, 'SGWS NY draft invoice #2678158 2026-10-08 item# 706412 "REMY MARTIN COG LOUIS XIII" 1 btl @ $3360.45/btl net', date '2026-10-08'),
  ('76d3cecc-1eea-4a13-af44-9418f757bd05'::uuid, 54.2400::numeric, 'SGWS NY draft invoice #2678158 2026-10-08 item# 27456 "REMY MARTIN COG VSOP 80" 12 btl @ $54.24/btl net', date '2026-10-08'),
  ('428b35cf-4d82-4e0a-82e6-9e75c082b2c2'::uuid, 29.1700::numeric, 'SGWS NY draft invoice #2678158 2026-10-08 item# 27414 "MT GAY RUM ECLIPSE 80" 6 btl @ $29.17/btl net', date '2026-10-08'),
  ('d6479572-639b-438c-baa2-b15cc381c9de'::uuid, 216.6300::numeric, 'SGWS NY draft invoice #2678158 2026-10-08 item# 27466 "REMY MARTIN COG XO EXCELLENCE" 2 btl @ $216.63/btl net', date '2026-10-08'),
  ('6f864756-a1ef-4dcc-a25c-c6065d196fc9'::uuid, 28.7800::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 469598 "BULLEIT 95 RYE 90" 12 btl @ $28.78/btl net -- highlighted ''Pick up'' on invoice', date '2026-10-09'),
  ('e3fc6422-0e32-4b46-bd62-fd96e3a70cc9'::uuid, 36.6100::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 17098 "GREY GOOSE VODKA 80" 18 btl @ $36.61/btl net', date '2026-10-09'),
  ('2bc29b7d-99f4-449d-b41b-75c652eddb18'::uuid, 19.3800::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 666789 "818 TEQ BLANCO 80" 6 btl @ $19.38/btl net', date '2026-10-09'),
  ('7eacbebb-99d9-4593-b57c-7c4148a245cf'::uuid, 25.0300::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 511787 "818 TEQ REPOSADO 80" 6 btl @ $25.03/btl net', date '2026-10-09'),
  ('ff12d405-22aa-4c91-92d6-ebde179a6a24'::uuid, 77.8800::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 360265 "CASA DRAGONES TEQ BLANCO 80" 2 btl @ $77.88/btl net', date '2026-10-09'),
  ('94af6e0a-e0c7-4123-994b-618d76dea71d'::uuid, 125.8800::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 966903 "CINCORO TEQ ANEJO 80 GB" 2 btl @ $125.88/btl net', date '2026-10-09'),
  ('4e9b3dad-0b71-45d6-85c7-9a3cf6b73301'::uuid, 71.8800::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 966904 "CINCORO TEQ BLANCO 80 GB" 4 btl @ $71.88/btl net', date '2026-10-09'),
  ('22104f4f-ca2d-4fc6-903d-e049693a7c4b'::uuid, 91.8800::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 966901 "CINCORO TEQ REPOSADO 80" 4 btl @ $91.88/btl net', date '2026-10-09'),
  ('1196a840-9570-449f-8459-09abf80e2f00'::uuid, 45.1300::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 697553 "LO SIENTO TEQ ANEJO 80" 1 btl @ $45.13/btl net', date '2026-10-09'),
  ('89ada23a-c1a9-4389-be14-347ec942b2d3'::uuid, 30.1300::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 697551 "LO SIENTO TEQ BLANCO 80" 2 btl @ $30.13/btl net', date '2026-10-09'),
  ('caef84e2-7cb9-46af-b541-185004320567'::uuid, 36.1300::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 697552 "LO SIENTO TEQ REPOSADO 80" 2 btl @ $36.13/btl net', date '2026-10-09'),
  ('ef0f434c-f92a-4b9c-ba53-5345b181e2a4'::uuid, 46.6300::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 635609 "RON ZACAPA RUM CENT 23YR 80" 3 btl @ $46.63/btl net', date '2026-10-09'),
  ('d91c5e8f-48c2-4b20-a701-c3289d6cdaf2'::uuid, 108.8800::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 697225 "818 EIGHT RESERVE TEQ ANEJO" 2 btl @ $108.88/btl net', date '2026-10-09'),
  ('7c65515c-d935-4b60-9375-8fd1fcf83f73'::uuid, 46.5500::numeric, 'SGWS NY draft invoice #2680494 2026-10-09 item# 511785 "818 TEQ ANEJO 80" 2 btl @ $46.55/btl net', date '2026-10-09');

insert into public.venue_item_settings (venue_id, master_item_id, notes)
select 'a681b43a-5cba-4656-b8bd-ae6d86e744c0', mid, 'Lady Delilah: SGWS NY opening invoices 10/8-10/9 (import 2026-10-09)' from _ld
on conflict (venue_id, master_item_id) do nothing;

insert into public.kount_venue_cost_overrides (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v14', mid, cost, source, 'lady-delilah-sgws-opening-2026-10-09', false, price_date, now() from _ld
on conflict (venue_id, master_item_id) do nothing;

do $$
declare n_items int; n_null int; n_vis int; n_vco int; n_bad int; n_venue int;
begin
  select count(distinct mid), count(*) filter (where mid is null) into n_items, n_null from _ld;
  select count(*) into n_vis from public.venue_item_settings where venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0';
  select count(*) into n_vco from public.kount_venue_cost_overrides where venue_id = 'v14';
  select count(*) into n_bad from _ld x join public.master_items m on m.id = x.mid where not m.is_active or m.merged_into_id is not null;
  select count(*) into n_venue from public.kount_venues where id = 'v14' and ops_venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and purchase_mapping = 'venue_item_map';
  if n_items <> 76 or n_null <> 0 or n_vis <> 76 or n_vco <> 76 or n_bad <> 0 or n_venue <> 1 then
    raise exception 'lady delilah setup check failed: items=% null=% vis=% vco=% inactive=% venue=%', n_items, n_null, n_vis, n_vco, n_bad, n_venue;
  end if;
end $$;

commit;
