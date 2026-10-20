-- =============================================================================
--  0092_kount_reopen_audit_rpc   (FUNCTION)
--
--  Reopen a SUBMITTED audit from the admin (Summary > Historic audits >
--  "Reopen audit"). Until now the admin could only reactivate a CANCELLED
--  audit; reopening a submitted one took a hand-written migration each time
--  (0087 for LL-038 on 10/19). Aditya asked for the button on 10/20 when
--  LL-038 needed reopening again.
--
--  Does exactly what 0087 did, as one checked transaction:
--    * status 'active', phase 'count1' -- counters rejoin with the same code,
--      every entry is kept;
--    * count1_closed_at, count2_closed_at, completed_at cleared. They MUST be
--      cleared: the phone only stamps count1_closed_at when it is null, and
--      compute_avt_for_audit ends its window at coalesce(count2_closed_at,
--      completed_at, count1_closed_at) -- a stale stamp would silently drop
--      every sale after it from the next variance;
--    * the computed variance report is removed (derived data; the next close
--      recomputes it), so a reopened count never shows as the venue's latest.
--
--  Refuses (nothing changed) when:
--    * the caller is not corporate/admin (kount_is_corporate);
--    * the audit is not 'submitted';
--    * the venue already has an ACTIVE audit -- two live counts at one venue
--      would split counters between them;
--    * the audit has recount rows -- going back to Count 1 would leave a
--      recount list from the old close behind. Reopen those by hand.
--
--  The 0089 new-product step runs again at the next close; it is idempotent.
--  ROLLBACK: 0092_ROLLBACK_kount_reopen_audit_rpc.sql
-- =============================================================================
begin;

create or replace function public.kount_reopen_audit(p_audit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  a          public.kount_audits;
  v_active   text;
  v_recounts integer;
  v_reports  integer;
  v_entries  integer;
begin
  if not public.kount_is_corporate() then
    raise exception 'Only corporate or admin users can reopen a submitted audit.'
      using errcode = '42501';
  end if;

  select * into a from public.kount_audits where id = p_audit_id for update;
  if not found then
    raise exception 'Audit % not found.', p_audit_id using errcode = 'P0002';
  end if;
  if a.status <> 'submitted' then
    raise exception '% is %, only a submitted audit can be reopened.', a.join_code, a.status
      using errcode = '22023';
  end if;

  select string_agg(b.join_code, ', ') into v_active
    from public.kount_audits b
   where b.venue_id = a.venue_id and b.status = 'active' and b.id <> a.id;
  if v_active is not null then
    raise exception '% already has an active audit (%). Close or cancel it before reopening %.',
      a.venue_name, v_active, a.join_code using errcode = '22023';
  end if;

  select count(*) into v_recounts from public.kount_recounts where audit_id = a.id;
  if v_recounts > 0 then
    raise exception '% has % recount row(s); reopening to Count 1 would orphan them. Reopen it by hand.',
      a.join_code, v_recounts using errcode = '22023';
  end if;

  delete from public.kount_avt_rows
   where report_id in (select id from public.kount_avt_reports
                        where audit_id = a.id and source = 'computed');
  delete from public.kount_avt_reports where audit_id = a.id and source = 'computed';
  get diagnostics v_reports = row_count;

  update public.kount_audits
     set status = 'active', count_phase = 'count1',
         count1_closed_at = null, count2_closed_at = null, completed_at = null
   where id = a.id;

  select count(*) into v_entries from public.kount_entries where audit_id = a.id;

  return jsonb_build_object('ok', true, 'audit_id', a.id, 'join_code', a.join_code,
    'venue_name', a.venue_name, 'entries', v_entries, 'reports_removed', v_reports);
end;
$function$;

revoke execute on function public.kount_reopen_audit(uuid) from public, anon;
grant execute on function public.kount_reopen_audit(uuid) to authenticated;

select count(*) as fn_installed from pg_proc where proname = 'kount_reopen_audit';
commit;
