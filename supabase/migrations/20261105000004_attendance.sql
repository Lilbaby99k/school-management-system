-- Migration 0004: Attendance
-- Project: Bright Future Academy (BFA) school platform
-- Run once, after migrations 0001 to 0003.
-- Everything runs in one transaction: if any statement fails, nothing is applied.
-- Note: the rule that corrections must come with a reason, and the audit
-- trail for them, are completed in later steps (backend function in Phase 6,
-- audit triggers in migration 0010).

begin;

-- ---------------------------------------------------------------
-- Reusable guard: makes a table append-only (no updates, no deletes).
-- Used here for attendance_corrections; reused for audit and result history.
-- ---------------------------------------------------------------
create or replace function public.prevent_row_modification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Table % is append-only: rows cannot be changed or deleted', tg_table_name;
end;
$$;

-- ---------------------------------------------------------------
-- attendance_sessions: one register per class arm per day
-- ---------------------------------------------------------------
create table public.attendance_sessions (
  id               uuid primary key default gen_random_uuid(),
  class_arm_id     uuid not null references public.class_arms (id) on delete restrict,
  term_id          uuid not null references public.terms (id) on delete restrict,
  attendance_date  date not null,
  marked_by        uuid references public.staff_profiles (id) on delete restrict,
  status           text not null default 'open'
                   check (status in ('open', 'submitted')),
  submitted_at     timestamptz,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Prevents a second register for the same class on the same day
  constraint attendance_sessions_unique unique (class_arm_id, attendance_date),
  constraint attendance_sessions_submitted_check
    check (status <> 'submitted' or submitted_at is not null)
);

create index attendance_sessions_term_id_idx on public.attendance_sessions (term_id);
create index attendance_sessions_marked_by_idx on public.attendance_sessions (marked_by);
create index attendance_sessions_date_idx on public.attendance_sessions (attendance_date);

-- ---------------------------------------------------------------
-- attendance_records: one row per student per register
-- ---------------------------------------------------------------
create table public.attendance_records (
  id                     uuid primary key default gen_random_uuid(),
  attendance_session_id  uuid not null references public.attendance_sessions (id) on delete restrict,
  enrollment_id          uuid not null references public.student_enrollments (id) on delete restrict,
  status                 text not null
                         check (status in ('present', 'absent', 'late', 'excused')),
  late_minutes           integer check (late_minutes is null or late_minutes > 0),
  remarks                text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  -- Prevents duplicate records for one student in one register
  constraint attendance_records_unique unique (attendance_session_id, enrollment_id),
  constraint attendance_records_late_check
    check (late_minutes is null or status = 'late')
);

create index attendance_records_enrollment_id_idx on public.attendance_records (enrollment_id);
create index attendance_records_status_idx on public.attendance_records (status);

-- A student can only be marked in the register of their own class arm
create or replace function public.check_attendance_record_enrollment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_arm    uuid;
  enrollment_arm uuid;
begin
  select class_arm_id into session_arm
    from public.attendance_sessions where id = new.attendance_session_id;
  select class_arm_id into enrollment_arm
    from public.student_enrollments where id = new.enrollment_id;

  if session_arm is distinct from enrollment_arm then
    raise exception 'Enrollment does not belong to the class arm of this attendance register';
  end if;
  return new;
end;
$$;

create trigger attendance_records_check_enrollment
  before insert or update of attendance_session_id, enrollment_id
  on public.attendance_records
  for each row execute function public.check_attendance_record_enrollment();

-- ---------------------------------------------------------------
-- attendance_corrections: append-only history of changed records
-- ---------------------------------------------------------------
create table public.attendance_corrections (
  id                    uuid primary key default gen_random_uuid(),
  attendance_record_id  uuid not null references public.attendance_records (id) on delete restrict,
  previous_status       text not null
                        check (previous_status in ('present', 'absent', 'late', 'excused')),
  new_status            text not null
                        check (new_status in ('present', 'absent', 'late', 'excused')),
  reason                text not null check (length(trim(reason)) >= 5),
  corrected_by          uuid not null references public.profiles (id) on delete restrict,
  corrected_at          timestamptz not null default now(),
  constraint attendance_corrections_changed_check check (previous_status <> new_status)
);

create index attendance_corrections_record_id_idx
  on public.attendance_corrections (attendance_record_id);
create index attendance_corrections_corrected_by_idx
  on public.attendance_corrections (corrected_by);

create trigger attendance_corrections_append_only
  before update or delete on public.attendance_corrections
  for each row execute function public.prevent_row_modification();

-- ---------------------------------------------------------------
-- staff_attendance: one row per staff member per day
-- ---------------------------------------------------------------
create table public.staff_attendance (
  id               uuid primary key default gen_random_uuid(),
  staff_id         uuid not null references public.staff_profiles (id) on delete restrict,
  attendance_date  date not null,
  status           text not null
                   check (status in ('present', 'absent', 'late', 'excused', 'on_leave')),
  check_in_at      timestamptz,
  check_out_at     timestamptz,
  remarks          text,
  recorded_by      uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint staff_attendance_unique unique (staff_id, attendance_date),
  constraint staff_attendance_times_check
    check (check_out_at is null or check_in_at is null or check_out_at >= check_in_at)
);

create index staff_attendance_date_idx on public.staff_attendance (attendance_date);

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
create trigger attendance_sessions_set_updated_at
  before update on public.attendance_sessions
  for each row execute function public.set_updated_at();

create trigger attendance_records_set_updated_at
  before update on public.attendance_records
  for each row execute function public.set_updated_at();

create trigger staff_attendance_set_updated_at
  before update on public.staff_attendance
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------
-- Keep helper functions away from browser keys
-- ---------------------------------------------------------------
revoke execute on function public.prevent_row_modification()
  from public, anon, authenticated;
revoke execute on function public.check_attendance_record_enrollment()
  from public, anon, authenticated;

-- ---------------------------------------------------------------
-- Row Level Security: ON for every table (policies come in Step 8)
-- ---------------------------------------------------------------
alter table public.attendance_sessions     enable row level security;
alter table public.attendance_records      enable row level security;
alter table public.attendance_corrections  enable row level security;
alter table public.staff_attendance        enable row level security;

commit;