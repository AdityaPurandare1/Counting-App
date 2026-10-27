-- =============================================================================
--  0115_lady_delilah_count_leads   (DATA)
--
--  Kount access for Lady Delilah's opening count (opens 10/31). All three
--  already have h.wood logins (shared Supabase auth, the phone signs in with
--  the same email + password as KevaOS), found via Paycor's Lady Delilah
--  roster:
--    * Robert Ciancimino, General Manager  -- new Kount manager, v14
--    * Andrew Reed, Lead Sommelier         -- new Kount manager, v14
--    * Graysen Garland, Task Force Manager -- already a Kount manager at
--      v1-v6; v14 added
--  ROLLBACK: delete from app_users where email in ('rciancimino@hwoodgroup.com', 'areeds@hwoodgroup.com');
--            update app_users set venue_ids = array_remove(venue_ids, 'v14') where email = 'ggarland@hwoodgroup.com';
-- =============================================================================
begin;

insert into public.app_users (email, name, role, venue_ids, is_active, job_title)
select v.email, v.name, 'manager', array['v14'], true, v.title
  from (values ('rciancimino@hwoodgroup.com', 'Robert Ciancimino', 'General Manager, Lady Delilah'),
               ('areeds@hwoodgroup.com', 'Andrew Reed', 'Lead Sommelier, Lady Delilah')) v(email, name, title)
 where exists (select 1 from auth.users u where lower(u.email) = v.email)
on conflict (email) do nothing;

update public.app_users
   set venue_ids = venue_ids || array['v14'], updated_at = now()
 where email = 'ggarland@hwoodgroup.com' and not ('v14' = any(venue_ids));

do $$ begin
  if (select count(*) from public.app_users
       where email in ('rciancimino@hwoodgroup.com', 'areeds@hwoodgroup.com', 'ggarland@hwoodgroup.com')
         and is_active and 'v14' = any(venue_ids)) <> 3 then
    raise exception '0115: expected 3 Lady Delilah count leads';
  end if;
end $$;

select email, name, role, venue_ids from public.app_users where 'v14' = any(venue_ids) order by email;
commit;
