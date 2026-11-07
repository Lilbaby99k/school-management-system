-- Migration 0005: Assessment and results
-- Project: Bright Future Academy (BFA) school platform
-- Run once, after migrations 0001 to 0004.
-- Everything runs in one transaction: if any statement fails, nothing is applied.
--
-- Design notes
--  * Grade boundaries store only the MINIMUM score of each grade. A score
--    gets the grade with the highest minimum that is not above it, so there
--    are no gaps or overlaps (74.5 is safely B2 on the secondary scale).
--  * Published results live in student_subject_results (a stored snapshot).
--    Parents and students see only rows with published_at set.
--  * Decision D4: a published result can be corrected by an authorised user,
--    but a database trigger refuses the change unless a reason (at least 5
--    characters) and the editor's id are supplied, and it writes the history
--    row in result_corrections in the same transaction. The backend supplies
--    them with:
--      select set_config('app.correction_reason', '<reason>', true);
--      select set_config('app.actor_id', '<profile uuid>', true);
--    result_corrections is append-only.
--  * Editing raw scores after submission is blocked by the backend and by
--    access policies (Phase 6 and Step 8), not by this migration.

begin;

-- ---------------------------------------------------------------
-- Grading schemes and boundaries
-- ---------------------------------------------------------------
create table public.grading_schemes (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique check (length(trim(name)) > 0),
  description  text,
  pass_mark    numeric(5,2) not null default 40 check (pass_mark between 0 and 100),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.grading_boundaries (
  id          uuid primary key default gen_random_uuid(),
  scheme_id   uuid not null references public.grading_schemes (id) on delete restrict,
  grade       text not null check (length(trim(grade)) > 0),
  min_score   numeric(5,2) not null check (min_score between 0 and 100),
  remark      text,
  sort_order  smallint not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint grading_boundaries_grade_unique unique (scheme_id, grade),
  constraint grading_boundaries_min_unique unique (scheme_id, min_score)
);

-- Each school section uses one grading scheme
alter table public.school_sections
  add column grading_scheme_id uuid references public.grading_schemes (id) on delete restrict;

create index school_sections_grading_scheme_id_idx
  on public.school_sections (grading_scheme_id);

-- ---------------------------------------------------------------
-- Assessment types (configurable per section), e.g. CA 40 + Exam 60
-- The maximum scores of a section's active types should add up to 100;
-- the backend validates this when an admin changes them.
-- ---------------------------------------------------------------
create table public.assessment_types (
  id          uuid primary key default gen_random_uuid(),
  section_id  uuid not null references public.school_sections (id) on delete restrict,
  code        text not null check (code ~ '^[A-Z0-9_]+$'),
  name        text not null check (length(trim(name)) > 0),
  max_score   numeric(5,2) not null check (max_score > 0 and max_score <= 100),
  is_exam     boolean not null default false,
  sort_order  smallint not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint assessment_types_unique unique (section_id, code)
);

create index assessment_types_section_id_idx on public.assessment_types (section_id);

-- ---------------------------------------------------------------
-- Assessments: one assessment type for one subject, class arm and term.
-- max_score is copied from the type so later changes do not alter history.
-- ---------------------------------------------------------------
create table public.assessments (
  id                  uuid primary key default gen_random_uuid(),
  assessment_type_id  uuid not null references public.assessment_types (id) on delete restrict,
  term_id             uuid not null references public.terms (id) on delete restrict,
  class_arm_id        uuid not null references public.class_arms (id) on delete restrict,
  subject_id          uuid not null references public.subjects (id) on delete restrict,
  max_score           numeric(5,2) not null check (max_score > 0 and max_score <= 100),
  created_by          uuid references public.profiles (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint assessments_unique
    unique (assessment_type_id, term_id, class_arm_id, subject_id)
);

create index assessments_term_id_idx on public.assessments (term_id);
create index assessments_class_arm_id_idx on public.assessments (class_arm_id);
create index assessments_subject_id_idx on public.assessments (subject_id);

create table public.assessment_scores (
  id             uuid primary key default gen_random_uuid(),
  assessment_id  uuid not null references public.assessments (id) on delete restrict,
  enrollment_id  uuid not null references public.student_enrollments (id) on delete restrict,
  score          numeric(5,2) check (score is null or score >= 0),
  is_absent      boolean not null default false,
  remarks        text,
  entered_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint assessment_scores_unique unique (assessment_id, enrollment_id),
  constraint assessment_scores_absent_check check (not is_absent or score is null)
);

create index assessment_scores_enrollment_id_idx on public.assessment_scores (enrollment_id);

-- A score must be for a student of the same class arm and not above the maximum
create or replace function public.check_assessment_score()
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
    from public.assessments where id = new.assessment_id;
  select class_arm_id into e_arm
    from public.student_enrollments where id = new.enrollment_id;

  if a_arm is distinct from e_arm then
    raise exception 'Enrollment does not belong to the class arm of this assessment';
  end if;
  if new.score is not null and new.score > a_max then
    raise exception 'Score % is above the maximum of % for this assessment', new.score, a_max;
  end if;
  return new;
end;
$$;

create trigger assessment_scores_check
  before insert or update of assessment_id, enrollment_id, score
  on public.assessment_scores
  for each row execute function public.check_assessment_score();

-- ---------------------------------------------------------------
-- Result submissions and the approval workflow
-- Teacher submission > validation > academic review > approval > publication
-- ---------------------------------------------------------------
create table public.result_submissions (
  id             uuid primary key default gen_random_uuid(),
  class_arm_id   uuid not null references public.class_arms (id) on delete restrict,
  subject_id     uuid not null references public.subjects (id) on delete restrict,
  term_id        uuid not null references public.terms (id) on delete restrict,
  submitted_by   uuid not null references public.staff_profiles (id) on delete restrict,
  status         text not null default 'draft'
                 check (status in ('draft', 'submitted', 'validated', 'reviewed', 'approved', 'published', 'returned')),
  submitted_at   timestamptz,
  published_at   timestamptz,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint result_submissions_unique unique (class_arm_id, subject_id, term_id),
  constraint result_submissions_submitted_check
    check (status in ('draft', 'returned') or submitted_at is not null),
  constraint result_submissions_published_check
    check (status <> 'published' or published_at is not null)
);

create index result_submissions_term_id_idx on public.result_submissions (term_id);
create index result_submissions_subject_id_idx on public.result_submissions (subject_id);
create index result_submissions_submitted_by_idx on public.result_submissions (submitted_by);
create index result_submissions_status_idx on public.result_submissions (status);

-- Append-only log of every workflow decision
create table public.result_approvals (
  id             uuid primary key default gen_random_uuid(),
  submission_id  uuid not null references public.result_submissions (id) on delete restrict,
  stage          text not null
                 check (stage in ('submission', 'validation', 'review', 'approval', 'publication')),
  decision       text not null check (decision in ('approved', 'returned')),
  acted_by       uuid not null references public.profiles (id) on delete restrict,
  comment        text,
  acted_at       timestamptz not null default now(),
  constraint result_approvals_return_comment_check
    check (decision <> 'returned' or length(trim(coalesce(comment, ''))) > 0)
);

create index result_approvals_submission_id_idx on public.result_approvals (submission_id);
create index result_approvals_acted_by_idx on public.result_approvals (acted_by);

create trigger result_approvals_append_only
  before update or delete on public.result_approvals
  for each row execute function public.prevent_row_modification();

-- ---------------------------------------------------------------
-- student_subject_results: stored snapshot written by the backend.
-- Parents and students see only rows where published_at is set.
-- ---------------------------------------------------------------
create table public.student_subject_results (
  id                    uuid primary key default gen_random_uuid(),
  result_submission_id  uuid not null references public.result_submissions (id) on delete restrict,
  enrollment_id         uuid not null references public.student_enrollments (id) on delete restrict,
  total_score           numeric(5,2) not null check (total_score between 0 and 100),
  grade                 text not null,
  remark                text,
  position_in_class     integer check (position_in_class is null or position_in_class > 0),
  version               integer not null default 1 check (version > 0),
  published_at          timestamptz,
  published_by          uuid references public.profiles (id) on delete restrict,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint student_subject_results_unique unique (result_submission_id, enrollment_id),
  constraint student_subject_results_published_check
    check (published_at is null or published_by is not null)
);

create index student_subject_results_enrollment_id_idx
  on public.student_subject_results (enrollment_id);
create index student_subject_results_published_idx
  on public.student_subject_results (published_at);

-- ---------------------------------------------------------------
-- report_cards: one per student per term; PDF kept in private storage
-- ---------------------------------------------------------------
create table public.report_cards (
  id                 uuid primary key default gen_random_uuid(),
  enrollment_id      uuid not null references public.student_enrollments (id) on delete restrict,
  term_id            uuid not null references public.terms (id) on delete restrict,
  version            integer not null default 1 check (version > 0),
  file_path          text,
  average_score      numeric(5,2) check (average_score is null or average_score between 0 and 100),
  overall_position   integer check (overall_position is null or overall_position > 0),
  class_size         integer check (class_size is null or class_size > 0),
  teacher_comment    text,
  principal_comment  text,
  generated_at       timestamptz,
  generated_by       uuid references public.profiles (id) on delete set null,
  is_stale           boolean not null default false,
  released_at        timestamptz,
  released_by        uuid references public.profiles (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint report_cards_unique unique (enrollment_id, term_id),
  constraint report_cards_released_check
    check (released_at is null or released_by is not null)
);

create index report_cards_term_id_idx on public.report_cards (term_id);

-- ---------------------------------------------------------------
-- result_corrections (decision D4): append-only history of corrections
-- ---------------------------------------------------------------
create table public.result_corrections (
  id                         uuid primary key default gen_random_uuid(),
  student_subject_result_id  uuid not null references public.student_subject_results (id) on delete restrict,
  previous_score             numeric(5,2) not null,
  new_score                  numeric(5,2) not null,
  previous_grade             text not null,
  new_grade                  text not null,
  reason                     text not null check (length(trim(reason)) >= 5),
  corrected_by               uuid not null references public.profiles (id) on delete restrict,
  corrected_at               timestamptz not null default now()
);

create index result_corrections_result_id_idx
  on public.result_corrections (student_subject_result_id);
create index result_corrections_corrected_by_idx
  on public.result_corrections (corrected_by);

create trigger result_corrections_append_only
  before update or delete on public.result_corrections
  for each row execute function public.prevent_row_modification();

-- A published result cannot change without a reason, an editor and a history row
create or replace function public.log_published_result_correction()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reason text := nullif(trim(current_setting('app.correction_reason', true)), '');
  v_actor  text := nullif(trim(current_setting('app.actor_id', true)), '');
begin
  if v_reason is null or length(v_reason) < 5 then
    raise exception 'A reason of at least 5 characters is required to correct a published result';
  end if;
  if v_actor is null then
    raise exception 'The editor must be identified to correct a published result';
  end if;

  insert into public.result_corrections
    (student_subject_result_id, previous_score, new_score, previous_grade, new_grade, reason, corrected_by)
  values
    (old.id, old.total_score, new.total_score, old.grade, new.grade, v_reason, v_actor::uuid);

  new.version := old.version + 1;

  -- Any report card already generated for this student and term is now out of date
  update public.report_cards rc
     set is_stale = true
   where rc.enrollment_id = new.enrollment_id
     and rc.term_id = (select term_id from public.result_submissions
                        where id = new.result_submission_id);

  return new;
end;
$$;

create trigger student_subject_results_log_correction
  before update on public.student_subject_results
  for each row
  when (old.published_at is not null
        and (old.total_score is distinct from new.total_score
             or old.grade is distinct from new.grade))
  execute function public.log_published_result_correction();

-- Published results cannot be deleted, unpublished or moved to another student
create or replace function public.protect_published_result()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'A published result cannot be deleted';
  end if;
  if new.published_at is distinct from old.published_at
     or new.enrollment_id is distinct from old.enrollment_id
     or new.result_submission_id is distinct from old.result_submission_id then
    raise exception 'A published result cannot be unpublished or moved';
  end if;
  return new;
end;
$$;

create trigger student_subject_results_protect
  before update or delete on public.student_subject_results
  for each row
  when (old.published_at is not null)
  execute function public.protect_published_result();

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
create trigger grading_schemes_set_updated_at
  before update on public.grading_schemes
  for each row execute function public.set_updated_at();

create trigger grading_boundaries_set_updated_at
  before update on public.grading_boundaries
  for each row execute function public.set_updated_at();

create trigger assessment_types_set_updated_at
  before update on public.assessment_types
  for each row execute function public.set_updated_at();

create trigger assessments_set_updated_at
  before update on public.assessments
  for each row execute function public.set_updated_at();

create trigger assessment_scores_set_updated_at
  before update on public.assessment_scores
  for each row execute function public.set_updated_at();

create trigger result_submissions_set_updated_at
  before update on public.result_submissions
  for each row execute function public.set_updated_at();

create trigger student_subject_results_set_updated_at
  before update on public.student_subject_results
  for each row execute function public.set_updated_at();

create trigger report_cards_set_updated_at
  before update on public.report_cards
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------
-- Keep helper functions away from browser keys
-- ---------------------------------------------------------------
revoke execute on function public.check_assessment_score()
  from public, anon, authenticated;
revoke execute on function public.log_published_result_correction()
  from public, anon, authenticated;
revoke execute on function public.protect_published_result()
  from public, anon, authenticated;

-- ---------------------------------------------------------------
-- Row Level Security: ON for every table (policies come in Step 8)
-- ---------------------------------------------------------------
alter table public.grading_schemes         enable row level security;
alter table public.grading_boundaries      enable row level security;
alter table public.assessment_types        enable row level security;
alter table public.assessments             enable row level security;
alter table public.assessment_scores       enable row level security;
alter table public.result_submissions      enable row level security;
alter table public.result_approvals        enable row level security;
alter table public.student_subject_results enable row level security;
alter table public.report_cards            enable row level security;
alter table public.result_corrections      enable row level security;

-- ---------------------------------------------------------------
-- Seed: grading schemes, boundaries, and CA 40 + Exam 60
-- Secondary: A1 75+, B2 70+, B3 65+, C4 60+, C5 55+, C6 50+, D7 45+, E8 40+, F9 below 40
-- Primary:   A 70+, B 60+, C 50+, D 45+, E 40+, F below 40
-- ---------------------------------------------------------------
insert into public.grading_schemes (name, description, pass_mark) values
  ('Primary Scale',   'A to F scale for Primary 1 to 6',  40),
  ('Secondary Scale', 'A1 to F9 scale for JSS and SS',    40);

insert into public.grading_boundaries (scheme_id, grade, min_score, remark, sort_order)
select s.id, v.grade, v.min_score, v.remark, v.sort_order
from (values
  ('Secondary Scale', 'A1', 75, 'Excellent', 1),
  ('Secondary Scale', 'B2', 70, 'Very Good', 2),
  ('Secondary Scale', 'B3', 65, 'Good',      3),
  ('Secondary Scale', 'C4', 60, 'Credit',    4),
  ('Secondary Scale', 'C5', 55, 'Credit',    5),
  ('Secondary Scale', 'C6', 50, 'Credit',    6),
  ('Secondary Scale', 'D7', 45, 'Pass',      7),
  ('Secondary Scale', 'E8', 40, 'Pass',      8),
  ('Secondary Scale', 'F9',  0, 'Fail',      9),
  ('Primary Scale',   'A',  70, 'Excellent', 1),
  ('Primary Scale',   'B',  60, 'Very Good', 2),
  ('Primary Scale',   'C',  50, 'Good',      3),
  ('Primary Scale',   'D',  45, 'Fair',      4),
  ('Primary Scale',   'E',  40, 'Pass',      5),
  ('Primary Scale',   'F',   0, 'Fail',      6)
) as v (scheme_name, grade, min_score, remark, sort_order)
join public.grading_schemes s on s.name = v.scheme_name;

update public.school_sections
   set grading_scheme_id = (select id from public.grading_schemes where name = 'Primary Scale')
 where code = 'PRI';

update public.school_sections
   set grading_scheme_id = (select id from public.grading_schemes where name = 'Secondary Scale')
 where code in ('JSS', 'SSS');

insert into public.assessment_types (section_id, code, name, max_score, is_exam, sort_order)
select s.id, v.code, v.name, v.max_score, v.is_exam, v.sort_order
from public.school_sections s
cross join (values
  ('CA',   'Continuous Assessment', 40, false, 1),
  ('EXAM', 'Examination',           60, true,  2)
) as v (code, name, max_score, is_exam, sort_order);

commit;
