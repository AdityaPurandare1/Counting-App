-- =============================================================================
--  0094_little_luck_invoice_item_packs   (DATA)
--
--  Little Luck (v11): pack sizes for 23 vendor items whose invoice lines the
--  0093 rules could not resolve on their own (no pack in the description and
--  no reference price, or two packs equally plausible). Each pack was read
--  from the line itself -- quantity, line price, bottle size, and the prices
--  of the same vendor's other lines on the same invoice -- and is recorded in
--  kount_invoice_item_map so that:
--    * kount_refresh_venue_invoice_costs (nightly) prices the item per bottle,
--      now and on every future invoice of the same vendor item;
--    * compute_avt_for_audit credits purchases as cases x pack.
--  NOT mapped (still in review): 818 Blanco 750ml ($85.50 is a 3- or 6-pack),
--  Chilled Red Sabroso! '25 ($198 x 3), Edible Flower Mix (its purchase item
--  is mis-linked to a Vesta "5 LB YAMS" line).
--  ROLLBACK: 0094_ROLLBACK_little_luck_invoice_item_packs.sql
-- =============================================================================
begin;

insert into public.kount_invoice_item_map (venue_id, purchase_item_id, master_item_id, units_per_case, note, set_by)
select 'v11', v.pid, v.mid, v.units, v.note, 'claude 2026-10-20 (LL invoice packs)'
  from (values
  ('2596d061-dc02-483c-ab29-4da52248e5c0'::uuid, '096c6ac3-dca8-4e69-bff1-de248cfcd6d9'::uuid, 1, '6 x $42.00 on Breakthru 1291199553: per bottle'),
  ('6b2d8799-b4fe-4fd5-b5b8-c1649f1863dc'::uuid, 'de7dc359-4cce-4e0e-86a0-2baf25f2e8be'::uuid, 1, '6 x $41.00 on Breakthru 1291199553: per bottle'),
  ('785be994-8a37-4b6b-ad43-be594feccf45'::uuid, 'dedb0fe0-f477-4109-a01e-1456d9b0f1f5'::uuid, 1, '6 x $22.75 on Breakthru 1291199553: per bottle'),
  ('5fd1d730-a60b-4c81-a842-19f4491db51a'::uuid, '9d6e3ca3-1052-4d7f-8af6-9397b35141e2'::uuid, 6, '$144.69 Harbor 300913699 = 6-pack ($24.12; Giffard Caribbean Pineapple 750ml is $28.88 the same way)'),
  ('dbf8b5e2-313e-4fd7-880f-80bdc2d1fa21'::uuid, '49e91991-3eca-4383-87fd-aed4f93a176c'::uuid, 12, '6 x $252.00 SGWS 2681620 = 12-packs ($21.00/bottle); a 6-pack would be $42, above any Ketel One 1L price on file'),
  ('12ad11a9-d104-4554-945c-8e3f031f30ac'::uuid, 'e5748085-4edb-44aa-9a1d-4e0d8bdbaf62'::uuid, 6, '$165.50 SGWS 2681620 = 6-pack ($27.58)'),
  ('41b83fbf-9a72-4c6a-8dba-e3ede53cd944'::uuid, 'e2519fde-7530-47b3-be98-97cb65466123'::uuid, 6, '$210.00 Pacific Edge 450518 = 6-pack ($35.00)'),
  ('b84e9f15-fc83-4ddf-994c-75b8c87e5200'::uuid, '534b2b3c-5a66-40d2-b447-870d259437c9'::uuid, 6, '$141.00 SGWS 02699467 = 6-pack ($23.50)'),
  ('0e37b431-d1a9-4506-a830-821e852975ec'::uuid, '8c565759-45e3-41c5-ab9e-dbc14d44771b'::uuid, 6, '$138.00 SGWS 2681620 = 6-pack ($23.00)'),
  ('eb98df7f-9cb4-43b7-ac9e-943a8e9c5db3'::uuid, '90e13186-fa6c-415a-b8b0-889b3287cf13'::uuid, 12, '$369.00 SGWS 2681620 = 12-pack ($30.75)'),
  ('651a25bc-60ab-4407-a452-3f9db769aff4'::uuid, '3f39cafc-ef88-40db-897c-889f3d1ec0a3'::uuid, 1, '6 x $34.00 on SIPT INV-2126: per bottle'),
  ('1d88e115-bed1-4223-80ae-510ac26b0401'::uuid, 'd8a00a7a-6884-419b-9258-09c2e775d854'::uuid, 1, '1 x $105.00 on L&B 1755: one 1.8L bottle'),
  ('3fe9c6a6-8f45-4ccc-91bb-b4451fb31fa9'::uuid, '4e8534fa-0089-4725-958a-ce45c4de84ad'::uuid, 1, '1 x $120.00 on L&B 1755: one 1.8L bottle'),
  ('c3de28cf-b273-4c17-8817-e938aed19c4c'::uuid, '0805c58d-a3a8-4e8b-b71f-4a0d1c52863d'::uuid, 1, '6 x $31.00 on SIPT INV-2126: per bottle'),
  ('04edaa3e-841a-45dd-8210-417c2bcd74b0'::uuid, '2b2769d7-288d-4a32-8e65-fbbad5b80058'::uuid, 1, '1 x $115.00 on L&B 1755: one 1.8L bottle'),
  ('dba9431e-6d10-4d2b-9024-6811ccea8a0f'::uuid, 'ab91502b-be2d-419e-ac96-be4a17f124ce'::uuid, 1, '2 x $115.00 on L&B 1755: per 1.8L bottle'),
  ('a792e6d9-865b-42dc-bc9c-4d4049930109'::uuid, '1233da4b-e4fd-443b-8b81-4660a9b700b8'::uuid, 12, '$480.00 Grand Cru CASO37568-01 = 12-pack ($40.00)'),
  ('f7992547-e7c1-4a81-83b6-f3eeea81ef7d'::uuid, 'b02bd941-e315-425e-bd29-f97bf2ff196b'::uuid, 12, '$360.00 East West 4384-S, description "12 pack" ($30.00)'),
  ('6b303eef-b26a-4fcb-8f99-8ea72a0af371'::uuid, 'b98f600f-72b8-41de-8d23-fd0573d2a292'::uuid, 1, 'L&B 1755: per bottle ($545 for the 2021, $410 for the 2024)'),
  ('d853f904-5afc-45ee-9b85-a792f977c796'::uuid, 'e1cfd247-fbea-43b9-98b6-d02e449d36e3'::uuid, 12, '2 x $264.00 Beaune 86923 = 12-packs ($22.00)'),
  ('6b53f31b-66bc-4b6e-8e98-37b2b60a5a17'::uuid, '5db282cf-c036-49a2-8f76-27c9e8bda81a'::uuid, 1, '6 x $35.00 on SIPT INV-2126: per bottle'),
  ('fa630d72-b362-41e6-9d62-b30e0668c971'::uuid, '6b69d162-f37b-4284-8a7b-6e09376246f5'::uuid, 1, '6 x $36.00 on SIPT INV-2126: per bottle'),
  ('aa0f74b6-2d11-4b55-b76e-0043de8fe9ce'::uuid, 'ef308a89-0ddd-4519-8ec0-7d6f73a93f34'::uuid, 1, '6 x $33.00 on SIPT INV-2126: per bottle')
  ) v(pid, mid, units, note)
on conflict do nothing;

select count(*) as mapped from public.kount_invoice_item_map where set_by = 'claude 2026-10-20 (LL invoice packs)';
commit;
