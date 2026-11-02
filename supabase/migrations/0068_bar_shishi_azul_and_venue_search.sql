-- =============================================================================
--  0068_bar_shishi_azul_and_venue_search  (DATA)
--
--  1. Aditya 2026-10-07: value Shishi liquor at what Shishi actually paid where an
--     Azul Spirits & Wine receipt exists ("Cost Bar Shi Shi Beverage Order Guide
--     2026 Opening - Costed.xlsx"), replacing the Delilah Miami distributor proxies.
--     45 rows, set_by 'shishi-azul-receipts-2026-10-07'.
--  2. All-time / all-venue search (invoice_lines + vendor_items + purchase_items)
--     for the 58 still-unpriced items: 13 found, set_by 'shishi-venue-search-2026-10-07'.
--  Same conventions as 0066 (is_manual=false, price_date 2026-08-01).
-- =============================================================================
begin;
insert into public.kount_venue_cost_overrides
  (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v13', v.mid, v.cost, v.source, 'shishi-azul-receipts-2026-10-07', false, date '2026-08-01', now()
from (values
  ('490107a5-a5dc-445e-a79b-db4226f83271'::uuid, 30.0000, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $30.00/1L'),
  ('d674dadf-e21e-49c4-8221-0b96cd26f699'::uuid, 17.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $17.99/750ml'),
  ('d6525c26-a8aa-474a-b96c-ac19f2d3db47'::uuid, 65.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $49.49/750ml scaled to 1L'),
  ('18d4a9f4-3bf2-49e2-899a-b3d7040dfac5'::uuid, 52.1900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $52.19/750ml'),
  ('a2b35fba-9844-412b-8058-85ca217766fb'::uuid, 47.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $35.99/750ml scaled to 1L'),
  ('77d51701-045c-4b79-a73d-1d4687342119'::uuid, 32.3900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $32.39'),
  ('0baaeed5-1efa-49a3-8e3b-7d791ca8a005'::uuid, 29.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $22.49/750ml scaled to 1L'),
  ('adfb34d3-3947-4e97-b892-7d951d11fdea'::uuid, 31.4900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $31.49/1L'),
  ('d992c4a7-1268-458a-a804-90bdc9415f62'::uuid, 46.7900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) "Campari Bitters 1.0L" $46.79 (assumed Campari Aperitivo)'),
  ('7ba37613-b5e7-44b5-a4b0-db68046bfe6b'::uuid, 35.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $35.99/750ml'),
  ('a6c077dc-890a-4f83-9480-cb41173acf92'::uuid, 47.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $35.99/750ml scaled to 1L'),
  ('e5c5d09f-949e-47c8-b4e8-a7c4a4e86cb4'::uuid, 25.0000, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) generic "Coffee Liqueur 750ml" $25.00 believed Mr. Black (low confidence)'),
  ('f404645f-7754-4b15-9bcb-3e3c3ee94005'::uuid, 34.1900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $34.19'),
  ('45706799-df7b-4f5c-9623-3e5080cd7192'::uuid, 30.5900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $30.59'),
  ('6576dc84-fdd2-4188-a198-0f4d61b5dc52'::uuid, 38.6900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $38.69'),
  ('6a38a4b5-0ab7-4f97-9427-9851275167d4'::uuid, 30.5900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $30.59'),
  ('2a885162-89b9-4fa2-8369-a0f28c6ebe70'::uuid, 30.5900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $30.59'),
  ('676eae43-57fb-49d7-9dbc-edfbbda6723d'::uuid, 21.5900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $21.59/1L'),
  ('ef0f434c-f92a-4b9c-ba53-5345b181e2a4'::uuid, 40.4900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) Zacapa 23 $40.49'),
  ('435529eb-0ce0-40f6-887d-ddfb7f5eec45'::uuid, 36.8900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $36.89/750ml'),
  ('c12c67ce-8b31-444a-a032-cc3bc944ac35'::uuid, 50.3900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $50.39/1L'),
  ('45119ac4-0e60-4e91-a2c1-c69ef1f256d9'::uuid, 33.7500, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $33.75/1L'),
  ('d6dbd242-3713-40b0-a1d3-c75ecd87993c'::uuid, 43.1900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $32.39/750ml scaled to 1L'),
  ('dc0bf15f-858a-4d26-91cb-5acfb0e19af6'::uuid, 32.3900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $32.39/750ml'),
  ('49e91991-3eca-4383-87fd-aed4f93a176c'::uuid, 35.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $35.99/1L'),
  ('71fa4736-713c-42be-a471-dc6cbb38d21b'::uuid, 44.3900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $33.29/750ml scaled to 1L'),
  ('817a5996-e67b-4200-a1c6-1d482f2182df'::uuid, 157.4900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $157.49'),
  ('d659c806-7f01-4010-98bc-d6629ac5d169'::uuid, 31.7200, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $42.29/1L scaled to 750ml'),
  ('ea38a945-b29f-4162-9a4c-f29d82ef23f0'::uuid, 88.1900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $88.19'),
  ('a2bc7577-514c-47c3-ab76-333ccc152ff0'::uuid, 152.0000, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $152.00'),
  ('004ac288-0c52-4850-aff1-cb81ef70807e'::uuid, 44.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $44.99'),
  ('9dab3b49-1168-486f-a7ad-38371f3c0f5d'::uuid, 34.1900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $34.19'),
  ('5a64791a-f03f-47b7-a510-38326f9ff1e0'::uuid, 26.0900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $26.09'),
  ('bbbfdaac-5123-4205-993d-64c769da0012'::uuid, 44.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $44.99'),
  ('927c06d0-9272-4dd4-ac9f-4af857bd093f'::uuid, 48.5900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $48.59'),
  ('04e5128c-3568-4bdc-822d-758c4f09a078'::uuid, 33.2900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $33.29/750ml'),
  ('7df5f3ca-d52e-452c-9e51-ee1fc591783f'::uuid, 35.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $35.99'),
  ('aeab2dd6-f739-4dd6-a614-85efa069f113'::uuid, 25.1900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $25.19/750ml'),
  ('81d5817d-110b-4e08-b0c2-ecce534256cd'::uuid, 26.9900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $26.99'),
  ('97ff57c0-ffba-4ee4-8662-f8ffe50d9a4c'::uuid, 24.2900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $24.29'),
  ('87f56a0c-31ec-40a2-b08a-b4b646a9c996'::uuid, 31.4900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $31.49'),
  ('5f4bd2b3-184d-4349-a414-db297d215db6'::uuid, 31.4900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $31.49'),
  ('b7284393-b003-4da7-80fc-e84d13e36f54'::uuid, 31.4900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $31.49/720ml'),
  ('362cc19e-95c0-4302-839b-c8f655fe5ccd'::uuid, 31.4900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $31.49/720ml'),
  ('dc4b78c5-3b91-4caa-b356-fc62b7c6bef0'::uuid, 11.6900, 'SHISHI costed order guide: Azul Spirits & Wine receipt (Shishi opening purchase) $11.69/4oz')
) v(mid, cost, source)
on conflict (venue_id, master_item_id) do update
  set cost_per_unit = excluded.cost_per_unit, source = excluded.source, set_by = excluded.set_by,
      is_manual = false, price_date = excluded.price_date, updated_at = now();

insert into public.kount_venue_cost_overrides
  (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v13', v.mid, v.cost, v.source, 'shishi-venue-search-2026-10-07', false, date '2026-08-01', now()
from (values
  ('73365f09-2680-43a7-a663-daab74622115'::uuid, 15.9000, 'PROXY Delilah LA/Keys RNDC: Bushmills Original 12/1L $254.40 = $21.20/L, scaled to 750ml (2024 price, low confidence)'),
  ('e60e90e7-a1e6-4fb4-a950-2c051fc72a3f'::uuid, 21.2000, 'PROXY Keys RNDC 2024-07-30: Bushmills Original 12/1L $254.40 = $21.20 (replaces $10.66 Miami reading)'),
  ('6f236930-f00c-440e-8555-fd26b3ab9de6'::uuid, 19.0000, 'catalog purchase_item "WINE Hubert Meyer Pinot 750ml" $19.00 (low confidence: may be a different cuvee)'),
  ('f255d8ce-9f25-4926-934f-41761dec0ea2'::uuid, 0.8500, 'PROXY Delilah Miami/BSC Fat Ice branded 2in cube $85/100 = $0.85 (low confidence: size)'),
  ('379289d1-88e1-4046-8477-fe8c740e7cc6'::uuid, 54.0000, 'PROXY Nice Guy LA 2023: Art of Tea Mandarin Silk 1lb $54.00 (old price)'),
  ('9b7452fa-9634-4236-8f6b-2effb2969ae5'::uuid, 46.0000, 'PROXY Bird Streets 2026-07-10: Matcha Powder Jpn $46.00 (low confidence: grade)'),
  ('deec0b05-5860-4396-9e30-f1790ee507c5'::uuid, 74.5000, 'PROXY SGWS 2023-01-24 vendor catalog: NIKKA WHISKY SM MIYAGIKYO $74.50 (old price)'),
  ('d48839a7-f3f5-468f-bc43-b8d04b23e622'::uuid, 75.0000, 'PROXY Delilah Miami 2026-09-11 "Nitrogen" $75.00 (low confidence: may be gas cylinder, coded R&M)'),
  ('f69ddd46-d96c-4532-82d0-3bf6e150d91d'::uuid, 25.9500, 'PROXY Bird Streets 2025-08-13: Nori, Premium, Half $25.95 per pack'),
  ('5ce001df-ee69-407f-9b5a-bd9ac3c2f9e9'::uuid, 17.1000, 'PROXY Vesta vendor catalog: PUREE-PLUM DARK RED BOIRON $17.10/kg'),
  ('c03049f2-9ab5-427d-9be6-85afb45fb44b'::uuid, 40.8300, 'PROXY Nice Guy LA 2026-03-20: Stevia in the Raw 1000ct $40.83 per box'),
  ('b5b7c630-a1f9-47e3-90a1-5e936692028f'::uuid, 13.9500, 'PROXY Shure Hospitality: In the Raw 1200ct $41.85 = $13.95 per 400 (low confidence)'),
  ('e5085ad0-ee92-462d-aeae-9a23627f6a26'::uuid, 16.9000, 'PROXY Bird Streets 2023-12-29: WAKAMOMO SYRUP ZUKE $16.90 (old price)')
) v(mid, cost, source)
on conflict (venue_id, master_item_id) do update
  set cost_per_unit = excluded.cost_per_unit, source = excluded.source, set_by = excluded.set_by,
      is_manual = false, price_date = excluded.price_date, updated_at = now();

commit;
