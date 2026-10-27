-- =============================================================================
--  0113_lady_delilah_r365_invoice_location   (DATA, KevaOS config)
--
--  Lady Delilah (counting v14, ops venue a681b43a) gets no invoices: the R365
--  invoice sync (KevaOS lib/etl/procurement-runner.ts) builds its location map
--  from integration_connections rows with config_json.r365_location_id and
--  SKIPS rows marked gl_only. Lady Delilah had no row at all, so its operating
--  location 0411 "Lady Delilah - Opr" (d508ce87) was never synced -- for GL or
--  invoices (0 ledger lines). Its pre-opening location 0410 (398b4c3c, mapped
--  GL-only to the inactive 'Delilah New York' 0d2907c8) only carries
--  construction AP (GL 1550), no beverage, so it is left alone.
--
--  Same shape as Little Luck's and Alphabet's rows (connection_key 'gl',
--  gl_only false): the location syncs both GL and invoices into a681b43a.
--  Credentials are resolved org-wide by the runner; this row copies Little
--  Luck's server-side, exactly as KevaOS's mapLocationToVenue does.
--  ROLLBACK: delete from integration_connections where provider = 'r365'
--             and venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'
--             and config_json->>'r365_location_id' = 'd508ce87-cc31-459e-8d5d-c2c91b339c3c';
-- =============================================================================
begin;

insert into public.integration_connections
       (organization_id, org_id, venue_id, provider, connection_key, credentials_encrypted, config_json, is_active)
select src.organization_id, src.org_id, v.id, 'r365', 'gl', src.credentials_encrypted,
       jsonb_build_object('gl_only', false,
                          'r365_org_id', src.config_json->>'r365_org_id',
                          'r365_location_id', l.r365_location_id::text),
       true
  from public.integration_connections src
  join public.venues v on v.id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0' and v.name = 'Lady Delilah'
  join public.ledger_r365_locations l on l.r365_location_id::text = 'd508ce87-cc31-459e-8d5d-c2c91b339c3c'
                                     and l.name = 'Lady Delilah - Opr'
 where src.provider = 'r365' and src.is_active and src.connection_key = 'gl'
   and src.venue_id = '1817c273-4fe6-4537-8276-582441641297'   -- Little Luck
   and not exists (select 1 from public.integration_connections x
                    where x.provider = 'r365'
                      and x.config_json->>'r365_location_id' = 'd508ce87-cc31-459e-8d5d-c2c91b339c3c');

do $$ begin
  if (select count(*) from public.integration_connections
       where provider = 'r365' and is_active and (config_json->>'gl_only')::boolean is false
         and venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0'
         and config_json->>'r365_location_id' = 'd508ce87-cc31-459e-8d5d-c2c91b339c3c') <> 1 then
    raise exception '0113: Lady Delilah R365 invoice row not in place';
  end if;
end $$;

select v.name venue, ic.connection_key, ic.config_json->>'r365_location_id' loc, ic.config_json->>'gl_only' gl_only, ic.is_active
  from public.integration_connections ic join public.venues v on v.id = ic.venue_id
 where ic.provider = 'r365' and ic.venue_id = 'a681b43a-5cba-4656-b8bd-ae6d86e744c0';
commit;
