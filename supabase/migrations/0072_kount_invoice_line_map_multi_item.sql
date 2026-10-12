-- =============================================================================
--  0072_kount_invoice_line_map_multi_item
--
--  Alphabet's opening wine orders reached KevaOS as ONE lump R365 line per invoice
--  (no product, no GL): Beaune 85805 $1,718.20, Martine's IN428116 $1,541.40,
--  Duckhorn 1906733 $987.00 (all 8/6-8/10, pre-opening). Alphabet's opening wine
--  list carries an INITIAL ORDER quantity per wine; per vendor those quantities x
--  bottle cost reconcile to each invoice within $3-$6 (delivery / deposit).
--
--  * kount_invoice_line_map primary key becomes (venue_id, invoice_line_id,
--    master_item_id) so one line can hold several counted items. compute_avt
--    (0071) already joins one row per mapping -- no function change.
--  * Seeds the 12 opening-order rows for v12.
--
--  ROLLBACK:
--    delete from kount_invoice_line_map where set_by = 'claude 2026-10-08 (opening wine orders)';
--    alter table kount_invoice_line_map drop constraint kount_invoice_line_map_pkey,
--      add primary key (venue_id, invoice_line_id);
-- =============================================================================

begin;

alter table public.kount_invoice_line_map drop constraint if exists kount_invoice_line_map_pkey;
alter table public.kount_invoice_line_map add primary key (venue_id, invoice_line_id, master_item_id);
comment on table public.kount_invoice_line_map is
  'Venue-scoped: which counted item(s) an invoice line is, and how many counted units of each, when the line names no product (R365 Missing Vendor Item placeholders, and lump opening-order lines that hold several products). Read by compute_avt_for_audit for venues with purchase_mapping = venue_item_map.';

insert into public.kount_invoice_line_map (venue_id, invoice_line_id, master_item_id, units, confidence, evidence, set_by)
select 'v12', s.line_id, c.mid, s.units, 'price', s.ev, 'claude 2026-10-08 (opening wine orders)'
  from (values
  ('83fcf690-9313-4f17-93c9-5887f8652e82'::uuid, 'Firmin Dezat, Sancerre 2024 750ml', 24.0, 'opening order: Alphabet wine list INITIAL ORDER 24 x Sancerre, Fermin Dezat, Loire Valley, FR 2025; invoice 85805 lump line $1,718.20 reconciles to the initial order within $6'),
  ('83fcf690-9313-4f17-93c9-5887f8652e82'::uuid, 'G.D. Vajra, ''Albe'', Barolo 2021 750ml', 12.0, 'opening order: Alphabet wine list INITIAL ORDER 12 x Barolo, G.D. Vajra, Albe, Piedmont, IT 2021; invoice 85805 lump line $1,718.20 reconciles to the initial order within $6'),
  ('83fcf690-9313-4f17-93c9-5887f8652e82'::uuid, 'Radio Coteau, ''La Neblina'', Pinot Noir', 12.0, 'opening order: Alphabet wine list INITIAL ORDER 12 x Pinot. Noir, Radio Coteau, La Neblina; invoice 85805 lump line $1,718.20 reconciles to the initial order within $6'),
  ('83fcf690-9313-4f17-93c9-5887f8652e82'::uuid, 'Le Ragnaie, Rosso di Montalcino 2022 750ml', 12.0, 'opening order: Alphabet wine list INITIAL ORDER 12 x Rosso di Montalcino, La Ragnaie, Tuscany, IT 2022; invoice 85805 lump line $1,718.20 reconciles to the initial order within $6'),
  ('36376f0a-c044-45b5-bd5e-18b98aa204cb'::uuid, 'Domaine des Justices, Bordeaux Superieur 2020 750ml', 24.0, 'opening order: Alphabet wine list INITIAL ORDER 24 x Bordeaux Superieur Rouge, Domaine des Justices, Bordeaux, FR 2020; invoice IN428116 lump line $1,541.40 reconciles to the initial order within $6'),
  ('36376f0a-c044-45b5-bd5e-18b98aa204cb'::uuid, 'Niepoort, 10 Year Tawny Port 750ml', 6.0, 'opening order: Alphabet wine list INITIAL ORDER 6 x Tawny Port, Niepoort, 10 year, Douro Valley, PT; invoice IN428116 lump line $1,541.40 reconciles to the initial order within $6'),
  ('36376f0a-c044-45b5-bd5e-18b98aa204cb'::uuid, 'Chateau les Justices, Sauternes 2023 375ml', 12.0, 'opening order: Alphabet wine list INITIAL ORDER 12 x Sauternes, Chateau les Justices, Bordeaux, FR 2023 375ml; invoice IN428116 lump line $1,541.40 reconciles to the initial order within $6'),
  ('36376f0a-c044-45b5-bd5e-18b98aa204cb'::uuid, 'Chateau Respide-Medeville, Graves 2022 750ml', 12.0, 'opening order: Alphabet wine list INITIAL ORDER 12 x Bordeaux, Chateau Respide - Medeville, Graves, FR 2022; invoice IN428116 lump line $1,541.40 reconciles to the initial order within $6'),
  ('36376f0a-c044-45b5-bd5e-18b98aa204cb'::uuid, 'Roc de Cambes, Cotes de Bourg 2022 750ml', 6.0, 'opening order: Alphabet wine list INITIAL ORDER 6 x Bordeaux, Roc de Cambes, Cotes de Bourg, FR 2022; invoice IN428116 lump line $1,541.40 reconciles to the initial order within $6'),
  ('32108319-125d-4209-aa49-62ce8dad133a'::uuid, 'Duckhorn, Sauvignon Blanc 2025 750ml', 12.0, 'opening order: Alphabet wine list INITIAL ORDER 12 x Sauv Blanc, Duckhorn, North Coast 2025; invoice 1906733 lump line $987.00 reconciles to the initial order within $6'),
  ('32108319-125d-4209-aa49-62ce8dad133a'::uuid, 'Duckhorn, Merlot 2022 750ml', 12.0, 'opening order: Alphabet wine list INITIAL ORDER 12 x Merlot, Duckhorn, Napa Valley 2023; invoice 1906733 lump line $987.00 reconciles to the initial order within $6'),
  ('32108319-125d-4209-aa49-62ce8dad133a'::uuid, 'Kosta Browne, Pinot Noir Sonoma Coast 2023 750ml', 6.0, 'opening order: Alphabet wine list INITIAL ORDER 6 x Pinot Noir, Kosta Browne, Sonoma Coast, CA 2023; invoice 1906733 lump line $987.00 reconciles to the initial order within $6')
  ) s(line_id, master_name, units, ev)
  join lateral (select distinct e.master_item_id mid from public.kount_entries e join public.kount_audits a on a.id=e.audit_id
                 join public.master_items mi on mi.id=e.master_item_id where a.venue_id='v12' and mi.name=s.master_name limit 1) c on true
on conflict do nothing;

do $$ begin
  if (select count(*) from public.kount_invoice_line_map where set_by = 'claude 2026-10-08 (opening wine orders)') <> 12 then
    raise exception '0072: expected 12 opening-order rows';
  end if;
end $$;

commit;
