-- =============================================================================
--  0157_kount_ot_quote_approval   (a quote stays flagged until we e-mail the go-ahead)
--
--  The user (2026-11-09): "for the quotes received, there has to be an email sent
--  from my end stating it was approved or good to go ahead / yes, so that things
--  aren't missed - keep the quoted items flagged till that email is sent".
--
--    kount_ot_lines.quote_approved_at          when h.wood's approving e-mail went out
--    kount_ot_lines.quote_approved_for         the quote number it approved (a revised
--                                              quote = another number = flagged again)
--    kount_ot_lines.quote_approval_note        who said what ('apurandare@...: "Approved, good to go ahead."')
--    kount_ot_lines.quote_approval_message_id  that e-mail (Graph immutable id)
--
--  A line is flagged while status = 'QUOTED' and it has no approval for the quote
--  number it carries now (admin: awaitingApproval). Stamped by kount-order-mail
--  (approvalPhase, every pull + the 'approvals' action): the reply from
--  @hwoodgroup.com to the vendor, sent after the quote came in, in the quote's
--  thread (or, for a real quote number, any e-mail that mentions it), whose new
--  text approves ("approved", "good to go", "go ahead", "proceed", a bare "yes").
--  Columns only: read / write as every kount_ot_lines column (table grants, the
--  0149 purchasing:order-tracker policies); the pull writes as the service role.
-- =============================================================================
begin;

alter table public.kount_ot_lines add column if not exists quote_approved_at timestamptz;
alter table public.kount_ot_lines add column if not exists quote_approved_for text;
alter table public.kount_ot_lines add column if not exists quote_approval_note text;
alter table public.kount_ot_lines add column if not exists quote_approval_message_id text;

comment on column public.kount_ot_lines.quote_approved_at is 'When h.wood e-mailed the vendor its go-ahead on this line''s quote (0157, found by the mail pull); a Quoted line without one is flagged';
comment on column public.kount_ot_lines.quote_approved_for is 'The quote number that approval covered (0157): a revised quote (another number) is flagged again';
comment on column public.kount_ot_lines.quote_approval_note is 'Who approved and the sentence that did (0157)';
comment on column public.kount_ot_lines.quote_approval_message_id is 'The approving e-mail (Graph immutable id, 0157)';

commit;

-- verification: 4 columns, and the open Quoted lines that are now flagged (all of them until the first pull reads the mail)
select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'kount_ot_lines'
          and column_name in ('quote_approved_at', 'quote_approved_for', 'quote_approval_note', 'quote_approval_message_id')) as new_columns,
       (select count(*) from public.kount_ot_lines l join public.kount_ot_orders o on o.id = l.order_id
         where l.status = 'QUOTED' and o.archived_at is null and o.completed_at is null and l.quote_approved_at is null) as flagged_lines;
