-- Migration 0010: Audit logs
-- Project: Bright Future Academy (BFA) school platform
-- Run once, after migrations 0001 to 0009.
-- Everything runs in one transaction: if any statement fails, nothing is applied.
--
-- Design notes
--  * audit_logs is append-only: rows cannot be updated, deleted or truncated,
--    and browser keys have no access at all. It has NO foreign keys on purpose,
--    so the history survives whatever happens to the records it describes.
--  * Database triggers record changes to sensitive tables automatically:
--      - permission and settings changes
--      - academic changes (results, grading, enrollments, report cards)
--      - finance changes (invoices, discounts, payments, receipts)
--      - attendance modifications (updates and deletes)
--      - parent-child links and media consents
--    Tables holding personal details (students, guardians, staff, admission
--    applications) log only WHICH columns changed, never the personal values.
--  * Who made the change: auth.uid() when the change comes from a signed-in
--    user, otherwise the id the backend supplies with
--      select set_config('app.actor_id', '<profile uuid>', true);
--    Changes made by the backend through the service key without that setting
--    show no actor, so the backend also writes explicit entries with
--    write_audit_event() for admin actions and sensitive access.
--  * Not audited here: routine volume tables (notifications, messages,
--    email_logs) which already keep their own history.

begin;

-- ---------------------------------------------------------------
-- audit_logs
-- ---------------------------------------------------------------
create table public.audit_logs (
  id               uuid primary key default gen_random_uuid(),
  occurred_at      timestamptz not null default now(),
  event_type       text not null
                   check (event_type in ('data_change', 'admin_action', 'security', 'sensitive_access')),
  action           text not null check (length(trim(action)) > 0),
  actor_id         uuid,
  table_name       text,
  record_id        text,
  old_data         jsonb,
  new_data         jsonb,
  changed_columns  text[],
  reason           text,
  details          jsonb,
  ip_address       inet,
  request_id       text,
  source           text not null default 'database' check (source in ('database', 'backend'))
);

create index audit_logs_occurred_at_idx on public.audit_logs (occurred_at desc);
create index audit_logs_record_idx on public.audit_logs (table_name, record_id);
create index audit_logs_actor_idx on public.audit_logs (actor_id, occurred_at desc);
create index audit_logs_event_type_idx on public.audit_logs (event_type, occurred_at desc);

alter table public.audit_logs enable row level security;
revoke all on public.audit_logs from anon, authenticated;

-- Append-only: no updates, deletes or truncation
create trigger audit_logs_append_only
  before update or delete on public.audit_logs
  for each row execute function public.prevent_row_modification();

create trigger audit_logs_no_truncate
  before truncate on public.audit_logs
  for each statement execute function public.prevent_row_modification();

-- ---------------------------------------------------------------
-- Generic row-change recorder used by the triggers below.
-- Argument 'full' stores old and new values; 'columns_only' stores
-- only the names of the columns that changed.
-- ---------------------------------------------------------------
create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode       text := coalesce(tg_argv[0], 'full');
  v_old        jsonb;
  v_new        jsonb;
  v_changed    text[];
  v_actor      uuid;
  v_record_id  text;
begin
  v_actor := coalesce(
    auth.uid(),
    nullif(current_setting('app.actor_id', true), '')::uuid
  );

  if tg_op = 'INSERT' then
    v_new := to_jsonb(new);
    v_record_id := v_new ->> 'id';
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    v_record_id := v_new ->> 'id';

    select coalesce(array_agg(n.key order by n.key), '{}')
      into v_changed
      from jsonb_each(v_new) n
     where v_old -> n.key is distinct from n.value;

    -- A change that only touched updated_at is not worth recording
    v_changed := array_remove(v_changed, 'updated_at');
    if coalesce(array_length(v_changed, 1), 0) = 0 then
      return null;
    end if;
  else
    v_old := to_jsonb(old);
    v_record_id := v_old ->> 'id';
  end if;

  if v_mode = 'columns_only' then
    v_old := null;
    v_new := null;
  end if;

  insert into public.audit_logs
    (event_type, action, actor_id, table_name, record_id,
     old_data, new_data, changed_columns, source)
  values
    ('data_change', tg_op, v_actor, tg_table_name, v_record_id,
     v_old, v_new, v_changed, 'database');

  return null;
end;
$$;

-- ---------------------------------------------------------------
-- Explicit entries written by the backend (admin actions, sensitive access)
-- ---------------------------------------------------------------
create or replace function public.write_audit_event(
  p_event_type  text,
  p_action      text,
  p_actor_id    uuid default null,
  p_table_name  text default null,
  p_record_id   text default null,
  p_details     jsonb default null,
  p_reason      text default null,
  p_ip_address  inet default null,
  p_request_id  text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.audit_logs
    (event_type, action, actor_id, table_name, record_id,
     details, reason, ip_address, request_id, source)
  values
    (p_event_type, p_action, p_actor_id, p_table_name, p_record_id,
     p_details, p_reason, p_ip_address, p_request_id, 'backend')
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------
-- Attach the audit triggers
-- ---------------------------------------------------------------
do $$
declare
  t text;
begin
  -- Full old/new values, every change
  foreach t in array array[
    'user_roles', 'roles', 'role_permissions', 'permissions',
    'school_modules', 'school_settings',
    'grading_schemes', 'grading_boundaries', 'assessment_types',
    'student_enrollments', 'result_submissions', 'student_subject_results',
    'report_cards',
    'fee_structures', 'discount_rules', 'invoices', 'invoice_discounts',
    'payments', 'receipts',
    'guardian_student_links', 'media_consents'
  ] loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I
         for each row execute function public.audit_row_change(%L)',
      t || '_audit', t, 'full');
  end loop;

  -- Full values, but only for modifications and deletions
  foreach t in array array[
    'assessment_scores', 'attendance_sessions', 'attendance_records', 'staff_attendance'
  ] loop
    execute format(
      'create trigger %I after update or delete on public.%I
         for each row execute function public.audit_row_change(%L)',
      t || '_audit', t, 'full');
  end loop;

  -- Personal details: record which columns changed, never the values
  foreach t in array array[
    'students', 'guardians', 'staff_profiles', 'admission_applications'
  ] loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I
         for each row execute function public.audit_row_change(%L)',
      t || '_audit', t, 'columns_only');
  end loop;
end;
$$;

-- ---------------------------------------------------------------
-- Keep audit functions away from browser keys
-- ---------------------------------------------------------------
revoke execute on function public.audit_row_change()
  from public, anon, authenticated;
revoke execute on function public.write_audit_event(text, text, uuid, text, text, jsonb, text, inet, text)
  from public, anon, authenticated;

commit;