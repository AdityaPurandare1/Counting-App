-- =============================================================================
--  0098_kount_catalog_prices_rpc   (FUNCTION)
--
--  The admin's month-end Audit Report reads catalog unit costs
--  (purchase_items.avg_cost) under the signed-in user's JWT. purchase_items is
--  KevaOS's table and its RLS only returns rows through organization_users
--  membership, which most counting staff do not have. For them the read comes
--  back EMPTY with no error, and the report refuses to export ("cost lookup
--  returned nothing"). Stephanie Pineda (Finance, Alphabet / Little Luck /
--  Poppy) is one: 0 of 133 catalog-priced LL-038 items were visible to her.
--  compute_avt_for_audit never had this problem -- it is SECURITY DEFINER.
--  This is the fix the 2026-09-02 report work deferred.
--
--  kount_catalog_prices(master ids) returns, for each master, the NEWEST priced
--  purchase_items row (updated_at desc nulls last, id desc) -- the same row
--  compute_avt_for_audit and the report's pickNewestPrices choose -- and only
--  the four columns the report reads. Callers must be an active Kount
--  corporate/admin/manager; anyone else gets an error, never an empty set.
--  purchase_items' own RLS and KevaOS access are unchanged.
--  ROLLBACK: drop function public.kount_catalog_prices(uuid[]);
-- =============================================================================
begin;

create or replace function public.kount_catalog_prices(p_master_ids uuid[])
returns table (id uuid, master_item_id uuid, avg_cost numeric, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1 from public.app_users u
     where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
       and u.is_active
       and u.role = any (array['corporate', 'admin', 'manager'])
  ) then
    raise exception 'Only Kount managers and corporate users can read catalog costs.'
      using errcode = '42501';
  end if;

  return query
  select distinct on (p.master_item_id) p.id, p.master_item_id, p.avg_cost, p.updated_at
    from public.purchase_items p
   where p.master_item_id = any (coalesce(p_master_ids, '{}'))
     and p.avg_cost is not null
   order by p.master_item_id, p.updated_at desc nulls last, p.id desc;
end;
$function$;

revoke execute on function public.kount_catalog_prices(uuid[]) from public, anon;
grant execute on function public.kount_catalog_prices(uuid[]) to authenticated;

select count(*) as fn_installed from pg_proc where proname = 'kount_catalog_prices';
commit;
