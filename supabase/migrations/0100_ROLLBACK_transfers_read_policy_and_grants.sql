-- ROLLBACK for 0100: back to the pre-0100 state (no select policy on transfers, using (true) on
-- transfer_lines, Supabase default grants to anon and authenticated).
begin;
drop policy if exists transfers_sel on public.transfers;
drop policy if exists transfer_lines_sel on public.transfer_lines;
create policy transfer_lines_sel on public.transfer_lines for select to authenticated using (true);
grant all on public.transfers, public.transfer_lines to anon, authenticated;
commit;
