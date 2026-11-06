-- Migration 0003: Academic structure
-- Project: Bright Future Academy (BFA) school platform
-- Run once, after migrations 0001 and 0002.
-- Everything runs in one transaction: if any statement fails, nothing is applied.
-- Seeds the 3 school sections, 12 classes and 30 class arms (Main Campus).
-- Subjects, sessions and terms are NOT seeded; the School Admin creates them.

begin;

-- ---------------------------------------------------------------
-- academic_sessions and terms
-- ---------------------------------------------------------------
create table public.academic_sessions (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (name ~ '^[0-9]{4}/[0-9]{4}$'),
  start_date  date not null,
  end_date    date not null,
  is_current  boolean not null default false,
  status      text not null default 'upcoming'
              check (status in ('upcoming', 'current', 'closed')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint academic_sessions_dates_check check (end_date > start_date),
  constraint academic_sessions_current_check check (is_current = (status = 'current'))
);

-- Only one current session at a time
create unique index academic_sessions_one_current
  on public.academic_sessions ((true)) where is_current;

create table public.terms (
  id                uuid primary key default gen_random_uuid(),
  session_id        uuid not null references public.academic_sessions (id) on delete restrict,
  term_number       smallint not null check (term_number between 1 and 3),
  name              text not null check (length(trim(name)) > 0),
  start_date        date not null,
  end_date          date not null,
  next_term_begins  date,
  is_current        boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint terms_session_number_unique unique (session_id, term_number),
  constraint terms_dates_check check (end_date > start_date),
  constraint terms_next_term_check
    check (next_term_begins is null or next_term_begins > end_date)
);

create index terms_session_id_idx on public.terms (session_id);

-- Only one current term at a time
create unique index terms_one_current
  on public.terms ((true)) where is_current;

-- ---------------------------------------------------------------
-- school_sections, classes, class_arms
-- level_order gives the promotion order (1 = Primary 1 ... 12 = SS 3)
-- ---------------------------------------------------------------
create table public.school_sections (
  id             uuid primary key default gen_random_uuid(),
  name           text not null unique check (length(trim(name)) > 0),
  code           text not null unique check (code ~ '^[A-Z]+$'),
  display_order  smallint not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table public.classes (
  id           uuid primary key default gen_random_uuid(),
  section_id   uuid not null references public.school_sections (id) on delete restrict,
  name         text not null check (length(trim(name)) > 0),
  code         text not null unique check (code ~ '^[A-Z0-9]+$'),
  level_order  smallint not null unique check (level_order > 0),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint classes_section_name_unique unique (section_id, name)
);

create index classes_section_id_idx on public.classes (section_id);

create table public.class_arms (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references public.classes (id) on delete restrict,
  campus_id   uuid not null references public.campuses (id) on delete restrict,
  name        text not null check (length(trim(name)) > 0 and length(name) <= 20),
  capacity    integer check (capacity is null or capacity > 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint class_arms_unique unique (class_id, campus_id, name)
);

create index class_arms_class_id_idx on public.class_arms (class_id);
create index class_arms_campus_id_idx on public.class_arms (campus_id);

-- ---------------------------------------------------------------
-- subjects and class_subjects
-- ---------------------------------------------------------------
create table public.subjects (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) > 0),
  code        text not null unique check (code ~ '^[A-Z0-9_]+$'),
  category    text check (category in ('core', 'elective', 'vocational', 'other')),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.class_subjects (
  id             uuid primary key default gen_random_uuid(),
  class_id       uuid not null references public.classes (id) on delete restrict,
  subject_id     uuid not null references public.subjects (id) on delete restrict,
  is_compulsory  boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint class_subjects_unique unique (class_id, subject_id)
);

create index class_subjects_subject_id_idx on public.class_subjects (subject_id);

-- ---------------------------------------------------------------
-- student_enrollments (history is kept; promotion adds a new row)
-- ---------------------------------------------------------------
create table public.student_enrollments (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references public.students (id) on delete restrict,
  class_arm_id  uuid not null references public.class_arms (id) on delete restrict,
  session_id    uuid not null references public.academic_sessions (id) on delete restrict,
  status        text not null default 'active'
                check (status in ('active', 'promoted', 'repeated', 'transferred', 'withdrawn', 'graduated')),
  enrolled_on   date not null default current_date,
  ended_on      date,
  remarks       text,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint student_enrollments_dates_check
    check (ended_on is null or ended_on >= enrolled_on)
);

-- A student has at most one active enrollment per session
create unique index student_enrollments_one_active
  on public.student_enrollments (student_id, session_id) where status = 'active';

create index student_enrollments_student_id_idx on public.student_enrollments (student_id);
create index student_enrollments_class_arm_id_idx on public.student_enrollments (class_arm_id);
create index student_enrollments_session_id_idx on public.student_enrollments (session_id);

-- ---------------------------------------------------------------
-- teacher assignments (these decide which classes a teacher can see)
-- ---------------------------------------------------------------
create table public.teacher_class_assignments (
  id               uuid primary key default gen_random_uuid(),
  staff_id         uuid not null references public.staff_profiles (id) on delete restrict,
  class_arm_id     uuid not null references public.class_arms (id) on delete restrict,
  session_id       uuid not null references public.academic_sessions (id) on delete restrict,
  is_class_teacher boolean not null default false,
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint teacher_class_assignments_unique unique (staff_id, class_arm_id, session_id)
);

-- One class teacher per class arm per session
create unique index teacher_class_assignments_one_class_teacher
  on public.teacher_class_assignments (class_arm_id, session_id) where is_class_teacher;

create index teacher_class_assignments_class_arm_idx
  on public.teacher_class_assignments (class_arm_id);
create index teacher_class_assignments_session_idx
  on public.teacher_class_assignments (session_id);

create table public.teacher_subject_assignments (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid not null references public.staff_profiles (id) on delete restrict,
  subject_id    uuid not null references public.subjects (id) on delete restrict,
  class_arm_id  uuid not null references public.class_arms (id) on delete restrict,
  session_id    uuid not null references public.academic_sessions (id) on delete restrict,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint teacher_subject_assignments_unique
    unique (staff_id, subject_id, class_arm_id, session_id)
);

create index teacher_subject_assignments_subject_idx
  on public.teacher_subject_assignments (subject_id);
create index teacher_subject_assignments_class_arm_idx
  on public.teacher_subject_assignments (class_arm_id);
create index teacher_subject_assignments_session_idx
  on public.teacher_subject_assignments (session_id);

-- ---------------------------------------------------------------
-- staff_assignments (positions such as Head Teacher of a section)
-- ---------------------------------------------------------------
create table public.staff_assignments (
  id             uuid primary key default gen_random_uuid(),
  staff_id       uuid not null references public.staff_profiles (id) on delete restrict,
  campus_id      uuid not null references public.campuses (id) on delete restrict,
  section_id     uuid references public.school_sections (id) on delete restrict,
  department_id  uuid references public.departments (id) on delete restrict,
  assignment_type text not null
                 check (assignment_type in ('principal', 'vice_principal', 'head_teacher', 'section_head', 'department_head', 'other')),
  started_on     date not null default current_date,
  ended_on       date,
  created_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint staff_assignments_dates_check
    check (ended_on is null or ended_on >= started_on)
);

create index staff_assignments_staff_id_idx on public.staff_assignments (staff_id);
create index staff_assignments_campus_id_idx on public.staff_assignments (campus_id);
create index staff_assignments_section_id_idx on public.staff_assignments (section_id);
create index staff_assignments_department_id_idx on public.staff_assignments (department_id);

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
create trigger academic_sessions_set_updated_at
  before update on public.academic_sessions
  for each row execute function public.set_updated_at();

create trigger terms_set_updated_at
  before update on public.terms
  for each row execute function public.set_updated_at();

create trigger school_sections_set_updated_at
  before update on public.school_sections
  for each row execute function public.set_updated_at();

create trigger classes_set_updated_at
  before update on public.classes
  for each row execute function public.set_updated_at();

create trigger class_arms_set_updated_at
  before update on public.class_arms
  for each row execute function public.set_updated_at();

create trigger subjects_set_updated_at
  before update on public.subjects
  for each row execute function public.set_updated_at();

create trigger class_subjects_set_updated_at
  before update on public.class_subjects
  for each row execute function public.set_updated_at();

create trigger student_enrollments_set_updated_at
  before update on public.student_enrollments
  for each row execute function public.set_updated_at();

create trigger teacher_class_assignments_set_updated_at
  before update on public.teacher_class_assignments
  for each row execute function public.set_updated_at();

create trigger teacher_subject_assignments_set_updated_at
  before update on public.teacher_subject_assignments
  for each row execute function public.set_updated_at();

create trigger staff_assignments_set_updated_at
  before update on public.staff_assignments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------
-- Row Level Security: ON for every table (policies come in Step 8)
-- ---------------------------------------------------------------
alter table public.academic_sessions          enable row level security;
alter table public.terms                      enable row level security;
alter table public.school_sections            enable row level security;
alter table public.classes                    enable row level security;
alter table public.class_arms                 enable row level security;
alter table public.subjects                   enable row level security;
alter table public.class_subjects             enable row level security;
alter table public.student_enrollments        enable row level security;
alter table public.teacher_class_assignments  enable row level security;
alter table public.teacher_subject_assignments enable row level security;
alter table public.staff_assignments          enable row level security;

-- ---------------------------------------------------------------
-- Seed: 3 sections, 12 classes, 30 class arms on the Main Campus
-- Primary 1-6 have arms A, B, C; JSS 1-3 and SS 1-3 have arms A, B.
-- ---------------------------------------------------------------
insert into public.school_sections (name, code, display_order) values
  ('Primary',          'PRI', 1),
  ('Junior Secondary', 'JSS', 2),
  ('Senior Secondary', 'SSS', 3);

insert into public.classes (section_id, name, code, level_order)
select s.id, v.name, v.code, v.level_order
from (values
  ('PRI', 'Primary 1', 'P1',   1),
  ('PRI', 'Primary 2', 'P2',   2),
  ('PRI', 'Primary 3', 'P3',   3),
  ('PRI', 'Primary 4', 'P4',   4),
  ('PRI', 'Primary 5', 'P5',   5),
  ('PRI', 'Primary 6', 'P6',   6),
  ('JSS', 'JSS 1',     'JSS1', 7),
  ('JSS', 'JSS 2',     'JSS2', 8),
  ('JSS', 'JSS 3',     'JSS3', 9),
  ('SSS', 'SS 1',      'SS1',  10),
  ('SSS', 'SS 2',      'SS2',  11),
  ('SSS', 'SS 3',      'SS3',  12)
) as v (section_code, name, code, level_order)
join public.school_sections s on s.code = v.section_code;

insert into public.class_arms (class_id, campus_id, name)
select c.id, m.id, a.arm
from public.classes c
join public.school_sections s on s.id = c.section_id
join public.campuses m on m.code = 'MAIN'
cross join lateral unnest(
  case when s.code = 'PRI' then array['A', 'B', 'C'] else array['A', 'B'] end
) as a (arm);

commit;