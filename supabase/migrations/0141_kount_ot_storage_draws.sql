-- =============================================================================
--  0141_kount_ot_storage_draws   (E&E deliveries out of storage -> stock draws)
--
--  The user (2026-11-02): orders filled from E&E's warehouse have no quote,
--  invoice or tracking -- only a fee line on E&E's "WAREHOUSING AND DELIVERY"
--  invoice: "TNG delivery - 10/12/2026 - 3 CASES TNG-EURO / 2 CASES TNG-PIZZAB".
--  The morning pull (kount-order-mail) now reads each such line into release
--  moves (kount_ot_stock_moves, line_id = the fee line); a line it cannot read
--  ("6 CASES / UBER PICK UP") waits in Warehouse for someone to pick the item.
--
--    kount_ot_lines.stock_draw  null       = not done yet
--                               'recorded' = its stock moves are recorded
--                               'none'     = looked at, not a stock move
--
--  Clients already update lines under the 0132 policies; nothing else changes.
-- =============================================================================
begin;

alter table public.kount_ot_lines
  add column if not exists stock_draw text check (stock_draw in ('recorded', 'none'));

comment on column public.kount_ot_lines.stock_draw is
  'E&E storage line (delivery / return / receiving fee): recorded = its stock moves exist, none = not a stock move, null = not done yet (0141)';

commit;
