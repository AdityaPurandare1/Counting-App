-- =============================================================================
--  0067_bar_shishi_costs_from_shishi_docs  (DATA)
--
--  Second pass on v13 (Bar Shishi) costs, from Shishi's OWN documents found in
--  the ShiShi Mgmt SharePoint (Shared Documents/Beverage/Orders):
--    · "Cost Bar Shi Shi Beverage Order Guide 2026 Opening - Costed.xlsx"
--      (unit costs from Azul Spirits & Wine receipts = Shishi's opening
--      purchases; fallback Delilah Miami Craftable audit)
--    · "Bar Shi Shi Beverage Order Guide 2026.xlsx" Wine List + BEER tabs
--      ($/btl per Shishi's distributors)
--  35 rows: 24 previously-unpriced items + 11 proxies replaced by Shishi's
--  own figure (beer, by-the-glass wines). Same conventions as 0066
--  (is_manual=false, price_date 2026-08-01, set_by for rollback).
--  REVERSIBLE: delete ... where venue_id='v13' and set_by='shishi-doc-costing-2026-10-07'
--  (then re-run 0066 to restore the replaced proxies).
-- =============================================================================
begin;
insert into public.kount_venue_cost_overrides
  (venue_id, master_item_id, cost_per_unit, source, set_by, is_manual, price_date, updated_at)
select 'v13', v.mid, v.cost, v.source, 'shishi-doc-costing-2026-10-07', false, date '2026-08-01', now()
from (values
  ('10462da5-8772-42f7-9f77-ea2c2635e0a5'::uuid, 39.4700, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $42.29/750ml scaled to 700ml (receipt calls it a sake - confirm)'),
  ('da52190a-99f9-42d7-919e-f9d536e71de8'::uuid, 39.3400, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Delilah Miami Craftable audit 1L $52.45 scaled to 750ml (low confidence: order guide lists 1L)'),
  ('8c8c338d-b9be-41a8-a754-12d743db0aed'::uuid, 47.0300, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $50.39/750ml scaled to 700ml'),
  ('97e3f532-e897-4e79-9c08-afd69cceb6bf'::uuid, 22.7000, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Delilah Miami Craftable audit Giffard Pamplemousse $22.70 used as substitute (low confidence: different brand)'),
  ('924bb307-e734-401c-a433-953a235694a4'::uuid, 25.3000, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Delilah Miami Craftable audit $25.30'),
  ('c30e7e59-9ec2-4e20-92e1-30e054a4bdb5'::uuid, 32.8200, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $34.19/750ml scaled to 720ml'),
  ('a0d9cfa6-cc54-4689-8a7f-c7307750e1ca'::uuid, 33.2900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $33.29'),
  ('dc5a95b9-0d61-43cd-81a6-b43419f9bc93'::uuid, 23.0000, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Delilah Miami Craftable audit $23.00'),
  ('e3002bc3-395d-405f-893a-032b0831ef7f'::uuid, 17.2500, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Delilah Miami Craftable audit 1L $23.00 scaled to 750ml (low confidence)'),
  ('c7d9eae0-b0e6-491e-8673-8875496a158e'::uuid, 40.4900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $40.49'),
  ('ff8959fe-0790-4ff7-a0ec-036f77d2b446'::uuid, 31.4900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $31.49'),
  ('da6d10e7-ccd8-4c3a-8c03-7a669f7dde0f'::uuid, 44.3900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $33.29/750ml scaled to 1L (order guide now lists Haku Yuzu 750ml)'),
  ('1db561f9-7138-4c2f-9b86-e817a37cc40e'::uuid, 734.6000, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Delilah Miami Craftable audit $734.60'),
  ('c0091c2d-d1de-45be-9da3-172ea9041bb2'::uuid, 40.4900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $37.79/700ml scaled to 750ml'),
  ('c079b13f-723b-42f5-806a-43abc0888421'::uuid, 29.3900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $31.49/750ml scaled to 700ml'),
  ('1366792d-8574-4c6d-8c30-d9943353ac2f'::uuid, 41.3900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $41.39'),
  ('3b2a4ba0-f706-4679-b091-ca9a027c76d6'::uuid, 39.5900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $39.59'),
  ('2fb16cf8-feb8-449f-81ff-5d442806c91b'::uuid, 51.2900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $51.29'),
  ('87a25c7d-017f-4109-8168-53cce15f5a0b'::uuid, 3169.9800, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Delilah Miami Craftable audit $3,169.98'),
  ('7c8899c0-638c-496a-ba2f-3a5c35672d73'::uuid, 42.2900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) $42.29/100ml'),
  ('38576e0d-859b-4a3b-a460-52367add7729'::uuid, 42.2900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) Umami $42.29 - same brand/size assumed (low confidence)'),
  ('61fac17e-a5a8-492a-bc85-62f9c4eaace8'::uuid, 42.2900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) Umami $42.29 - same brand/size assumed (low confidence)'),
  ('e68aa266-bf10-4910-9a94-f6bdbcaecd22'::uuid, 42.2900, 'SHISHI costed order guide (Bev/Orders, 2026-09-19): Azul Spirits & Wine receipt (Shishi own purchase) Umami $42.29 - same brand/size assumed (low confidence)'),
  ('fc5a1670-02ad-4c98-b311-6e912d1f99ee'::uuid, 1.2300, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) BEER tab: Mutual $29.40/24'),
  ('a8804849-a61b-48b1-90df-17123dfdd18e'::uuid, 1.2400, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) BEER tab: Cavalier $29.76/24'),
  ('4a80dae2-6f67-4dd5-9e7a-d06ef15a90f5'::uuid, 1.1400, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) BEER tab: Eagle Brands $27.36/24'),
  ('7a71d089-5ddf-4e15-84d0-6aa72c290e48'::uuid, 1.2900, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) BEER tab: Eagle Brands $30.85/24'),
  ('52942b50-37fc-4a22-b90f-9a0cc1879783'::uuid, 1.6900, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) BEER tab: Reyes $40.60/24'),
  ('013b71d5-c080-427a-af2f-895f8d21b8e7'::uuid, 27.0000, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) Wine List: Chappellet Mountain Cuvee, Winebow $27.00'),
  ('87413678-b691-4b3b-8e09-d6781b263e1c'::uuid, 29.1600, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) Wine List: SGWS $29.16'),
  ('9f9e4347-ad96-40d1-8c6b-3517bcd08b27'::uuid, 68.2500, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) Wine List: SGWS $68.25'),
  ('28ed14ac-a99e-429a-b91b-6b6cacf50c74'::uuid, 12.2500, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) Wine List: SGWS $12.25'),
  ('ca81955c-6005-4365-b6a9-a438d303696d'::uuid, 22.5000, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) Wine List: Les Climats $22.50'),
  ('ab9746fe-0025-4c11-94d5-8321022999eb'::uuid, 16.0000, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) Wine List: Minuty Prestige SGWS $16.00'),
  ('2a17ca8f-f6f1-4c5f-8473-a9db5cd058f0'::uuid, 28.6700, 'SHISHI Beverage Order Guide 2026 (Bev/Orders, 2026-09-26) Wine List: Winebow $28.67')
) v(mid, cost, source)
on conflict (venue_id, master_item_id) do update
  set cost_per_unit = excluded.cost_per_unit, source = excluded.source, set_by = excluded.set_by,
      is_manual = false, price_date = excluded.price_date, updated_at = now();
do $$ declare n int; begin
  select count(*) into n from public.kount_venue_cost_overrides where venue_id='v13' and set_by='shishi-doc-costing-2026-10-07';
  if n <> 35 then raise exception 'expected 35 rows, got %', n; end if;
end $$;
commit;
