-- =============================================================================
--  0100_transfers_read_policy_and_grants
--
--  Found by the 0099 diagnostics (2026-10-21): public.transfers has NO select policy (only
--  transfer_lines has one, using (true)), so with RLS on, every signed-in user -- admins
--  included -- read 0 transfers, and the admin's Transfers screen (v0.72) listed nothing while
--  14 rows existed. Both tables also carried Supabase's default full grants to anon and
--  authenticated; the missing policies meant writes affected 0 rows, but nothing should rely
--  on that.
--
--  Now: a transfer is readable when the user can see either venue (kount_can_see_venue via
--  kount_venues.ops_venue_id); a line is readable when its transfer is. All writes go through the
--  SECURITY DEFINER RPCs (kount_create_transfer / kount_delete_transfer), so every direct write
--  grant and anon's read grant are revoked.
--  ROLLBACK: 0100_ROLLBACK_transfers_read_policy_and_grants.sql
-- =============================================================================
begin;

drop policy if exists transfers_sel on public.transfers;
create policy transfers_sel on public.transfers
  for select to authenticated
  using (exists (select 1 from public.kount_venues kv
                  where kv.ops_venue_id in (transfers.from_venue_id, transfers.to_venue_id)
                    and public.kount_can_see_venue(kv.id)));

drop policy if exists transfer_lines_sel on public.transfer_lines;
create policy transfer_lines_sel on public.transfer_lines
  for select to authenticated
  using (exists (select 1 from public.transfers t where t.id = transfer_lines.transfer_id));

revoke all on public.transfers, public.transfer_lines from anon;
revoke insert, update, delete, truncate, references, trigger on public.transfers, public.transfer_lines from authenticated;
grant select on public.transfers, public.transfer_lines to authenticated;

do $$ begin
  if (select count(*) from pg_policies where tablename = 'transfers' and policyname = 'transfers_sel') <> 1
  or (select count(*) from pg_policies where tablename = 'transfer_lines' and policyname = 'transfer_lines_sel') <> 1
  or has_table_privilege('anon', 'public.transfers', 'select')
  or has_table_privilege('authenticated', 'public.transfers', 'delete')
  or has_table_privilege('authenticated', 'public.transfer_lines', 'update') then
    raise exception '0100: policies or grants not as expected';
  end if;
end $$;

commit;
