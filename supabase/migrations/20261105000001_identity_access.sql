-- Migration 0001: Identity and access
-- Project: Bright Future Academy (BFA) school platform
-- Run once on the empty bfa-school-dev project.
-- Everything runs in one transaction: if any statement fails, nothing is applied.

begin;

-- ---------------------------------------------------------------
-- Shared helper: keeps updated_at current on every update
-- ---------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------
-- schools (exactly one row allowed, decision D1)
-- ---------------------------------------------------------------
create table public.schools (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  short_name  text not null check (length(trim(short_name)) > 0),
  motto       text,
  logo_path   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index schools_single_row on public.schools ((true));

-- ---------------------------------------------------------------
-- campuses (one now, more can be added later)
-- ---------------------------------------------------------------
create table public.campuses (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools (id) on delete restrict,
  name        text not null check (length(trim(name)) > 0),
  code        text not null check (code ~ '^[A-Z0-9_]+$'),
  address     text,
  phone       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint campuses_school_code_unique unique (school_id, code)
);

create index campuses_school_id_idx on public.campuses (school_id);

-- ---------------------------------------------------------------
-- profiles (one row per login in auth.users; email stays in auth.users)
-- ---------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete restrict,
  first_name   text not null default '',
  last_name    text not null default '',
  phone        text,
  avatar_path  text,
  status       text not null default 'active'
               check (status in ('active', 'suspended', 'archived')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- roles, permissions and their links
-- ---------------------------------------------------------------
create table public.roles (
  id           uuid primary key default gen_random_uuid(),
  key          text not null unique check (key ~ '^[a-z][a-z0-9_]*$'),
  name         text not null,
  description  text,
  is_system    boolean not null default false,
  is_enabled   boolean not null default true,
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.permissions (
  id           uuid primary key default gen_random_uuid(),
  key          text not null unique check (key ~ '^[a-z0-9_]+(\.[a-z0-9_]+)+$'),
  module       text not null,
  description  text,
  created_at   timestamptz not null default now()
);

create table public.role_permissions (
  role_id        uuid not null references public.roles (id) on delete cascade,
  permission_id  uuid not null references public.permissions (id) on delete cascade,
  created_at     timestamptz not null default now(),
  primary key (role_id, permission_id)
);

create index role_permissions_permission_id_idx
  on public.role_permissions (permission_id);

create table public.user_roles (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles (id) on delete restrict,
  role_id     uuid not null references public.roles (id) on delete restrict,
  campus_id   uuid references public.campuses (id) on delete restrict,
  is_active   boolean not null default true,
  assigned_by uuid references public.profiles (id) on delete set null,
  assigned_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint user_roles_profile_role_unique unique (profile_id, role_id)
);

create index user_roles_role_id_idx on public.user_roles (role_id);
create index user_roles_campus_id_idx on public.user_roles (campus_id);

-- ---------------------------------------------------------------
-- module switches and settings
-- ---------------------------------------------------------------
create table public.school_modules (
  key          text primary key check (key ~ '^[a-z][a-z0-9_]*$'),
  name         text not null,
  description  text,
  is_core      boolean not null default false,
  is_enabled   boolean not null default false,
  updated_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.school_settings (
  key          text primary key check (key ~ '^[a-z][a-z0-9_.]*$'),
  value        jsonb not null default '{}'::jsonb,
  description  text,
  updated_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
create trigger schools_set_updated_at
  before update on public.schools
  for each row execute function public.set_updated_at();

create trigger campuses_set_updated_at
  before update on public.campuses
  for each row execute function public.set_updated_at();

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger roles_set_updated_at
  before update on public.roles
  for each row execute function public.set_updated_at();

create trigger user_roles_set_updated_at
  before update on public.user_roles
  for each row execute function public.set_updated_at();

create trigger school_modules_set_updated_at
  before update on public.school_modules
  for each row execute function public.set_updated_at();

create trigger school_settings_set_updated_at
  before update on public.school_settings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------
-- Create an empty profile whenever a login is created.
-- Only names are copied from sign-up data. Roles are NEVER taken
-- from user-supplied data; they are assigned by the backend.
-- ---------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, first_name, last_name)
  values (
    new.id,
    left(coalesce(new.raw_user_meta_data ->> 'first_name', ''), 100),
    left(coalesce(new.raw_user_meta_data ->> 'last_name', ''), 100)
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

revoke execute on function public.handle_new_user()
  from public, anon, authenticated;
revoke execute on function public.set_updated_at()
  from public, anon, authenticated;

-- ---------------------------------------------------------------
-- Row Level Security: ON for every table. With no policies yet,
-- the browser keys (anon, authenticated) can read and write nothing.
-- Access policies are added in the RLS migration (Step 8).
-- ---------------------------------------------------------------
alter table public.schools          enable row level security;
alter table public.campuses         enable row level security;
alter table public.profiles         enable row level security;
alter table public.roles            enable row level security;
alter table public.permissions      enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles       enable row level security;
alter table public.school_modules   enable row level security;
alter table public.school_settings  enable row level security;

-- ---------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------
insert into public.schools (name, short_name, motto)
values (
  'Bright Future Academy',
  'BFA',
  'Building a Foundation for a Brighter Future.'
);

insert into public.campuses (school_id, name, code)
select id, 'Main Campus', 'MAIN' from public.schools;

-- Core roles are enabled at launch; the last three are enabled later.
insert into public.roles (key, name, description, is_system, is_enabled, sort_order) values
  ('super_admin',       'Super Admin',       'Controls the entire system and manages school administrators.', true, true,  10),
  ('school_admin',      'School Admin',      'Manages daily school operations, users and settings.',          true, true,  20),
  ('principal',         'Principal',         'Oversees academic and administrative activities.',              true, true,  30),
  ('head_teacher',      'Head Teacher',      'Supervises teachers and class activities within assigned sections.', true, true, 40),
  ('teacher',           'Teacher',           'Manages assigned classes, subjects, attendance and results.',   true, true,  50),
  ('parent',            'Parent',            'Views children''s attendance, results, fees and academic progress.', true, true, 60),
  ('student',           'Student',           'Views personal results, timetable, assignments and announcements.', true, true, 70),
  ('admission_officer', 'Admission Officer', 'Handles student admissions and registration.',                  true, false, 80),
  ('bursar',            'Bursar',            'Manages school fees, payments, receipts and financial records.', true, false, 90),
  ('librarian',         'Librarian',         'Manages library books, borrowing and returns.',                 true, false, 100);

-- First-release modules are on; later modules are off until built.
insert into public.school_modules (key, name, description, is_core, is_enabled) values
  ('admissions',     'Admissions',            'Online applications, registration, approval and admission numbers.', true,  true),
  ('finance',        'Finance and Payments',  'Fees, invoices, payments, receipts and balances.',                   true,  true),
  ('attendance',     'Attendance',            'Student and teacher attendance and reports.',                        true,  true),
  ('results',        'Results and Assessment','Assessments, grading, result computation and report cards.',         true,  true),
  ('timetable',      'Timetable',             'Class timetables, teacher schedules and subject allocation.',        true,  true),
  ('assignments',    'Assignments',           'Assignment creation, submission, grading and feedback.',             true,  true),
  ('cms',            'Website CMS',           'Website pages, news, events, announcements and gallery.',            true,  true),
  ('communications', 'Communications',        'Email, WhatsApp, in-app notifications and messaging.',               true,  true),
  ('library',        'Library',               'Book registration, borrowing, returns and overdue tracking.',        false, false),
  ('transport',      'Transport',             'Buses, routes, drivers and student transportation.',                 false, false),
  ('boarding',       'Boarding',              'Hostel allocation, rooms and boarding records.',                     false, false),
  ('medical',        'Medical',               'Student health records, clinic visits and emergency contacts.',      false, false),
  ('payroll',        'Payroll',               'Staff salaries, allowances, deductions and payslips.',               false, false);

insert into public.school_settings (key, value, description) values
  ('branding.colors',
   jsonb_build_object('navy', '#0B1F3A', 'white', '#FFFFFF', 'gold', '#D4A017'),
   'School brand colours'),
  ('admission_number.format',
   jsonb_build_object('prefix', 'BFA', 'year_digits', 2, 'sequence_digits', 4, 'separator', '/'),
   'Admission number format, e.g. BFA/26/0001');

commit;