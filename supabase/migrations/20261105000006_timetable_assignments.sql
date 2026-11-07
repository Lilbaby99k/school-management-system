-- Migration 0006: Timetable, assignments and learning resources
-- Project: Bright Future Academy (BFA) school platform
-- Run once, after migrations 0001 to 0005.
-- Everything runs in one transaction: if any statement fails, nothing is applied.
-- No seed data: lesson times and rooms are entered by the School Admin.
--
-- Clash rules enforced here: in one term, a class arm, a teacher and a room
-- can each be used only once in the same day and lesson period.
-- Limit: periods belong to a school section, so a teacher teaching in two
-- sections at overlapping clock times is checked by the backend, not here.

begin;

-- ---------------------------------------------------------------
-- rooms
-- ---------------------------------------------------------------
create table public.rooms (
  id          uuid primary key default gen_random_uuid(),
  campus_id   uuid not null references public.campuses (id) on delete restrict,
  name        text not null check (length(trim(name)) > 0),
  room_type   text not null default 'classroom'
              check (room_type in ('classroom', 'laboratory', 'library', 'hall', 'other')),
  capacity    integer check (capacity is null or capacity > 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint rooms_campus_name_unique unique (campus_id, name)
);

create index rooms_campus_id_idx on public.rooms (campus_id);

-- ---------------------------------------------------------------
-- lesson_periods: the daily time slots for each school section
-- ---------------------------------------------------------------
create table public.lesson_periods (
  id          uuid primary key default gen_random_uuid(),
  section_id  uuid not null references public.school_sections (id) on delete restrict,
  name        text not null check (length(trim(name)) > 0),
  start_time  time not null,
  end_time    time not null,
  is_break    boolean not null default false,
  sort_order  smallint not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint lesson_periods_times_check check (end_time > start_time),
  constraint lesson_periods_name_unique unique (section_id, name),
  constraint lesson_periods_order_unique unique (section_id, sort_order)
);

-- ---------------------------------------------------------------
-- timetable_entries: one lesson in one slot of one class arm's week
-- ---------------------------------------------------------------
create table public.timetable_entries (
  id                uuid primary key default gen_random_uuid(),
  term_id           uuid not null references public.terms (id) on delete restrict,
  class_arm_id      uuid not null references public.class_arms (id) on delete restrict,
  lesson_period_id  uuid not null references public.lesson_periods (id) on delete restrict,
  day_of_week       smallint not null check (day_of_week between 1 and 7),
  subject_id        uuid not null references public.subjects (id) on delete restrict,
  staff_id          uuid not null references public.staff_profiles (id) on delete restrict,
  room_id           uuid references public.rooms (id) on delete restrict,
  created_by        uuid references public.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- A class arm has only one lesson per slot
  constraint timetable_class_slot_unique
    unique (term_id, class_arm_id, day_of_week, lesson_period_id)
);

-- A teacher cannot be in two places in the same slot
create unique index timetable_teacher_slot_unique
  on public.timetable_entries (term_id, staff_id, day_of_week, lesson_period_id);

-- A room cannot be booked twice in the same slot
create unique index timetable_room_slot_unique
  on public.timetable_entries (term_id, room_id, day_of_week, lesson_period_id)
  where room_id is not null;

create index timetable_entries_class_arm_id_idx on public.timetable_entries (class_arm_id);
create index timetable_entries_subject_id_idx on public.timetable_entries (subject_id);
create index timetable_entries_period_id_idx on public.timetable_entries (lesson_period_id);

-- No lessons in break periods, and the period must belong to the class arm's section
create or replace function public.check_timetable_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  p_section uuid;
  p_break   boolean;
  a_section uuid;
begin
  select section_id, is_break into p_section, p_break
    from public.lesson_periods where id = new.lesson_period_id;

  select c.section_id into a_section
    from public.class_arms a
    join public.classes c on c.id = a.class_id
   where a.id = new.class_arm_id;

  if p_break then
    raise exception 'Lessons cannot be scheduled in a break period';
  end if;
  if p_section is distinct from a_section then
    raise exception 'This lesson period belongs to a different school section than the class arm';
  end if;
  return new;
end;
$$;

create trigger timetable_entries_check
  before insert or update of lesson_period_id, class_arm_id
  on public.timetable_entries
  for each row execute function public.check_timetable_entry();

-- ---------------------------------------------------------------
-- assignments (homework and classwork set by teachers)
-- ---------------------------------------------------------------
create table public.assignments (
  id                 uuid primary key default gen_random_uuid(),
  class_arm_id       uuid not null references public.class_arms (id) on delete restrict,
  subject_id         uuid not null references public.subjects (id) on delete restrict,
  term_id            uuid not null references public.terms (id) on delete restrict,
  created_by         uuid not null references public.staff_profiles (id) on delete restrict,
  title              text not null check (length(trim(title)) > 0),
  instructions       text,
  due_at             timestamptz,
  max_score          numeric(5,2) check (max_score is null or (max_score > 0 and max_score <= 100)),
  allow_submissions  boolean not null default true,
  status             text not null default 'draft'
                     check (status in ('draft', 'published', 'closed')),
  published_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint assignments_published_check
    check (status = 'draft' or published_at is not null)
);

create index assignments_class_arm_id_idx on public.assignments (class_arm_id);
create index assignments_subject_id_idx on public.assignments (subject_id);
create index assignments_term_id_idx on public.assignments (term_id);
create index assignments_created_by_idx on public.assignments (created_by);

-- ---------------------------------------------------------------
-- assignment_submissions (files live in a private storage bucket)
-- ---------------------------------------------------------------
create table public.assignment_submissions (
  id             uuid primary key default gen_random_uuid(),
  assignment_id  uuid not null references public.assignments (id) on delete restrict,
  enrollment_id  uuid not null references public.student_enrollments (id) on delete restrict,
  answer_text    text,
  storage_path   text,
  file_name      text,
  mime_type      text,
  size_bytes     bigint check (size_bytes is null or (size_bytes > 0 and size_bytes <= 26214400)),
  submitted_at   timestamptz not null default now(),
  status         text not null default 'submitted'
                 check (status in ('submitted', 'late', 'graded', 'returned')),
  score          numeric(5,2) check (score is null or score >= 0),
  feedback       text,
  graded_by      uuid references public.staff_profiles (id) on delete restrict,
  graded_at      timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint assignment_submissions_unique unique (assignment_id, enrollment_id),
  constraint assignment_submissions_content_check
    check (answer_text is not null or storage_path is not null),
  constraint assignment_submissions_graded_check
    check (status <> 'graded' or (graded_by is not null and graded_at is not null))
);

create index assignment_submissions_enrollment_id_idx
  on public.assignment_submissions (enrollment_id);
create index assignment_submissions_graded_by_idx
  on public.assignment_submissions (graded_by);

-- A submission must be from a student of the assignment's class arm,
-- and the score cannot exceed the assignment's maximum
create or replace function public.check_assignment_submission()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  a_arm uuid;
  a_max numeric(5,2);
  e_arm uuid;
begin
  select class_arm_id, max_score into a_arm, a_max
    from public.assignments where id = new.assignment_id;
  select class_arm_id into e_arm
    from public.student_enrollments where id = new.enrollment_id;

  if a_arm is distinct from e_arm then
    raise exception 'Enrollment does not belong to the class arm of this assignment';
  end if;
  if new.score is not null and a_max is not null and new.score > a_max then
    raise exception 'Score % is above the maximum of % for this assignment', new.score, a_max;
  end if;
  return new;
end;
$$;

create trigger assignment_submissions_check
  before insert or update of assignment_id, enrollment_id, score
  on public.assignment_submissions
  for each row execute function public.check_assignment_submission();

-- ---------------------------------------------------------------
-- learning_resources (notes and materials in a private storage bucket)
-- ---------------------------------------------------------------
create table public.learning_resources (
  id             uuid primary key default gen_random_uuid(),
  subject_id     uuid not null references public.subjects (id) on delete restrict,
  class_id       uuid references public.classes (id) on delete restrict,
  class_arm_id   uuid references public.class_arms (id) on delete restrict,
  assignment_id  uuid references public.assignments (id) on delete restrict,
  title          text not null check (length(trim(title)) > 0),
  description    text,
  storage_path   text not null check (length(trim(storage_path)) > 0),
  file_name      text not null,
  mime_type      text not null,
  size_bytes     bigint not null check (size_bytes > 0 and size_bytes <= 26214400),
  is_published   boolean not null default false,
  uploaded_by    uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index learning_resources_subject_id_idx on public.learning_resources (subject_id);
create index learning_resources_class_id_idx on public.learning_resources (class_id);
create index learning_resources_class_arm_id_idx on public.learning_resources (class_arm_id);
create index learning_resources_assignment_id_idx on public.learning_resources (assignment_id);

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
create trigger rooms_set_updated_at
  before update on public.rooms
  for each row execute function public.set_updated_at();

create trigger lesson_periods_set_updated_at
  before update on public.lesson_periods
  for each row execute function public.set_updated_at();

create trigger timetable_entries_set_updated_at
  before update on public.timetable_entries
  for each row execute function public.set_updated_at();

create trigger assignments_set_updated_at
  before update on public.assignments
  for each row execute function public.set_updated_at();

create trigger assignment_submissions_set_updated_at
  before update on public.assignment_submissions
  for each row execute function public.set_updated_at();

create trigger learning_resources_set_updated_at
  before update on public.learning_resources
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------
-- Keep helper functions away from browser keys
-- ---------------------------------------------------------------
revoke execute on function public.check_timetable_entry()
  from public, anon, authenticated;
revoke execute on function public.check_assignment_submission()
  from public, anon, authenticated;

-- ---------------------------------------------------------------
-- Row Level Security: ON for every table (policies come in Step 8)
-- ---------------------------------------------------------------
alter table public.rooms                   enable row level security;
alter table public.lesson_periods          enable row level security;
alter table public.timetable_entries       enable row level security;
alter table public.assignments             enable row level security;
alter table public.assignment_submissions  enable row level security;
alter table public.learning_resources      enable row level security;

commit;