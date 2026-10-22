-- =============================================================================
--  0107_ROLLBACK_kount_bev_purchase_lines
--  Removes the read-only function added by 0107. Nothing else depends on it in
--  the database; the admin "Purchase prices" screen shows a load error until the
--  function is back.
-- =============================================================================
begin;
drop function if exists public.kount_bev_purchase_lines(date, date);
commit;
