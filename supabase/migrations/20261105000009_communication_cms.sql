-- Migration 0009: Communication and website content (CMS)
-- Project: Bright Future Academy (BFA) school platform
-- Run once, after migrations 0001 to 0008.
-- Everything runs in one transaction: if any statement fails, nothing is applied.
--
-- Design notes
--  * Public website content (pages, news, events, gallery, banners, testimonials)
--    has the states draft, published and archived. Policies in Step 8 will let the
--    public read PUBLISHED rows only.
--  * Student photographs: a gallery item that shows students must tag them, and it
--    can be published only when every tagged student has a granted website media
--    consent. Withdrawing consent automatically archives (unpublishes) the items.
--  * email_logs keeps who, what template and the outcome, but NOT the email body,
--    so private student information is not copied into logs.
--  * WhatsApp opt-in is recorded in notification_preferences. WhatsApp delivery logs
--    are added later with the WhatsApp integration (Phase 10).
--  * Messages are append-only. Only conversation participants can post.
--  * Text content is stored as plain text or Markdown; the backend sanitises it
--    before it is displayed (protection against XSS).

begin;

-- ---------------------------------------------------------------
-- announcements and their targets
-- ---------------------------------------------------------------
create table public.announcements (
  id             uuid primary key default gen_random_uuid(),
  title          text not null check (length(trim(title)) > 0),
  body           text not null check (length(trim(body)) > 0),
  audience       text not null default 'selected'
                 check (audience in ('everyone', 'all_parents', 'all_staff', 'all_students', 'selected')),
  status         text not null default 'draft'
                 check (status in ('draft', 'scheduled', 'published', 'archived')),
  publish_at     timestamptz,
  published_at   timestamptz,
  expires_at     timestamptz,
  send_in_app    boolean not null default true,
  send_email     boolean not null default false,
  send_whatsapp  boolean not null default false,
  created_by     uuid not null references public.profiles (id) on delete restrict,
  published_by   uuid references public.profiles (id) on delete restrict,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint announcements_published_check
    check (status <> 'published' or (published_at is not null and published_by is not null)),
  constraint announcements_scheduled_check
    check (status <> 'scheduled' or publish_at is not null),
  constraint announcements_expiry_check
    check (expires_at is null or published_at is null or expires_at > published_at)
);

create index announcements_status_idx on public.announcements (status);
create index announcements_created_by_idx on public.announcements (created_by);
create index announcements_published_by_idx on public.announcements (published_by);

create table public.announcement_targets (
  id               uuid primary key default gen_random_uuid(),
  announcement_id  uuid not null references public.announcements (id) on delete cascade,
  target_type      text not null check (target_type in ('class_arm', 'class', 'section', 'role')),
  class_arm_id     uuid references public.class_arms (id) on delete restrict,
  class_id         uuid references public.classes (id) on delete restrict,
  section_id       uuid references public.school_sections (id) on delete restrict,
  role_id          uuid references public.roles (id) on delete restrict,
  created_at       timestamptz not null default now(),
  -- Exactly the one column that matches the target type is filled in
  constraint announcement_targets_shape_check check (
    (target_type = 'class_arm' and class_arm_id is not null and class_id is null and section_id is null and role_id is null)
    or (target_type = 'class' and class_id is not null and class_arm_id is null and section_id is null and role_id is null)
    or (target_type = 'section' and section_id is not null and class_arm_id is null and class_id is null and role_id is null)
    or (target_type = 'role' and role_id is not null and class_arm_id is null and class_id is null and section_id is null)
  )
);

create index announcement_targets_announcement_id_idx on public.announcement_targets (announcement_id);
create index announcement_targets_class_arm_id_idx on public.announcement_targets (class_arm_id);
create index announcement_targets_class_id_idx on public.announcement_targets (class_id);
create index announcement_targets_section_id_idx on public.announcement_targets (section_id);
create index announcement_targets_role_id_idx on public.announcement_targets (role_id);

-- ---------------------------------------------------------------
-- notifications (in-app) and notification_preferences
-- Notification text must never contain private student information;
-- the backend keeps it generic and links to the secure page.
-- ---------------------------------------------------------------
create table public.notifications (
  id               uuid primary key default gen_random_uuid(),
  recipient_id     uuid not null references public.profiles (id) on delete restrict,
  category         text not null
                   check (category in ('announcement', 'attendance', 'result', 'fee', 'payment',
                                       'admission', 'message', 'system')),
  title            text not null check (length(trim(title)) > 0),
  body             text,
  announcement_id  uuid references public.announcements (id) on delete set null,
  entity_type      text,
  entity_id        uuid,
  is_read          boolean not null default false,
  read_at          timestamptz,
  created_at       timestamptz not null default now(),
  constraint notifications_read_check check (not is_read or read_at is not null)
);

create index notifications_recipient_idx
  on public.notifications (recipient_id, is_read, created_at desc);
create index notifications_announcement_id_idx on public.notifications (announcement_id);

create table public.notification_preferences (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references public.profiles (id) on delete restrict,
  category      text not null
                check (category in ('announcement', 'attendance', 'result', 'fee', 'payment',
                                    'admission', 'message')),
  channel       text not null check (channel in ('in_app', 'email', 'whatsapp')),
  is_enabled    boolean not null default true,
  consented_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint notification_preferences_unique unique (profile_id, category, channel),
  -- WhatsApp can only be switched on with a recorded opt-in
  constraint notification_preferences_whatsapp_check
    check (channel <> 'whatsapp' or not is_enabled or consented_at is not null)
);

-- ---------------------------------------------------------------
-- email_logs: outcome of every email attempt (no email body stored)
-- ---------------------------------------------------------------
create table public.email_logs (
  id                   uuid primary key default gen_random_uuid(),
  template             text not null check (length(trim(template)) > 0),
  subject              text,
  recipient_email      text not null check (length(trim(recipient_email)) > 0),
  recipient_id         uuid references public.profiles (id) on delete set null,
  provider             text not null default 'apps_script'
                       check (provider in ('apps_script', 'brevo', 'resend', 'sendgrid', 'supabase_auth')),
  status               text not null default 'queued'
                       check (status in ('queued', 'sent', 'failed', 'bounced')),
  provider_message_id  text,
  error_message        text,
  attempts             integer not null default 0 check (attempts >= 0),
  entity_type          text,
  entity_id            uuid,
  queued_at            timestamptz not null default now(),
  sent_at              timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint email_logs_sent_check check (status <> 'sent' or sent_at is not null),
  constraint email_logs_failed_check
    check (status <> 'failed' or length(trim(coalesce(error_message, ''))) > 0)
);

create index email_logs_status_idx on public.email_logs (status, queued_at);
create index email_logs_recipient_id_idx on public.email_logs (recipient_id);
create index email_logs_sent_at_idx on public.email_logs (sent_at);

create trigger email_logs_no_delete
  before delete on public.email_logs
  for each row execute function public.prevent_row_modification();

-- ---------------------------------------------------------------
-- conversations, participants and messages (parent-teacher messaging)
-- ---------------------------------------------------------------
create table public.conversations (
  id          uuid primary key default gen_random_uuid(),
  subject     text not null check (length(trim(subject)) > 0),
  student_id  uuid references public.students (id) on delete restrict,
  status      text not null default 'open' check (status in ('open', 'closed')),
  created_by  uuid not null references public.profiles (id) on delete restrict,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index conversations_student_id_idx on public.conversations (student_id);
create index conversations_created_by_idx on public.conversations (created_by);

create table public.conversation_participants (
  conversation_id  uuid not null references public.conversations (id) on delete restrict,
  profile_id       uuid not null references public.profiles (id) on delete restrict,
  joined_at        timestamptz not null default now(),
  last_read_at     timestamptz,
  primary key (conversation_id, profile_id)
);

create index conversation_participants_profile_id_idx
  on public.conversation_participants (profile_id);

create table public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations (id) on delete restrict,
  sender_id        uuid not null references public.profiles (id) on delete restrict,
  body             text not null check (length(trim(body)) > 0 and length(body) <= 5000),
  created_at       timestamptz not null default now()
);

create index messages_conversation_idx on public.messages (conversation_id, created_at);
create index messages_sender_id_idx on public.messages (sender_id);

create trigger messages_append_only
  before update or delete on public.messages
  for each row execute function public.prevent_row_modification();

-- Only participants can post, and only in open conversations
create or replace function public.check_message_sender()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  select status into v_status from public.conversations where id = new.conversation_id;
  if v_status is distinct from 'open' then
    raise exception 'This conversation is closed';
  end if;
  if not exists (
    select 1 from public.conversation_participants
     where conversation_id = new.conversation_id and profile_id = new.sender_id
  ) then
    raise exception 'The sender is not a participant of this conversation';
  end if;
  return new;
end;
$$;

create trigger messages_check_sender
  before insert on public.messages
  for each row execute function public.check_message_sender();

-- ---------------------------------------------------------------
-- events (school calendar; also shown on the public website when public)
-- ---------------------------------------------------------------
create table public.events (
  id                uuid primary key default gen_random_uuid(),
  title             text not null check (length(trim(title)) > 0),
  description       text,
  event_type        text not null default 'other'
                    check (event_type in ('academic', 'holiday', 'exam', 'meeting', 'sports', 'cultural', 'other')),
  starts_at         timestamptz not null,
  ends_at           timestamptz,
  is_all_day        boolean not null default false,
  location          text,
  audience          text not null default 'everyone'
                    check (audience in ('public', 'everyone', 'parents', 'staff', 'students')),
  cover_image_path  text,
  status            text not null default 'draft'
                    check (status in ('draft', 'published', 'archived')),
  published_at      timestamptz,
  created_by        uuid references public.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint events_dates_check check (ends_at is null or ends_at >= starts_at),
  constraint events_published_check check (status <> 'published' or published_at is not null)
);

create index events_starts_at_idx on public.events (starts_at);
create index events_status_idx on public.events (status);

-- ---------------------------------------------------------------
-- website_pages, news, homepage_banners, testimonials, contact_messages
-- ---------------------------------------------------------------
create table public.website_pages (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title             text not null check (length(trim(title)) > 0),
  summary           text,
  content           text not null default '',
  seo_title         text,
  seo_description   text,
  display_order     smallint not null default 0,
  status            text not null default 'draft'
                    check (status in ('draft', 'published', 'archived')),
  published_at      timestamptz,
  updated_by        uuid references public.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint website_pages_published_check check (status <> 'published' or published_at is not null)
);

create index website_pages_status_idx on public.website_pages (status);

create table public.news (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title             text not null check (length(trim(title)) > 0),
  summary           text,
  body              text not null default '',
  cover_image_path  text,
  is_featured       boolean not null default false,
  status            text not null default 'draft'
                    check (status in ('draft', 'published', 'archived')),
  published_at      timestamptz,
  author_id         uuid references public.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint news_published_check check (status <> 'published' or published_at is not null)
);

create index news_status_idx on public.news (status, published_at desc);
create index news_author_id_idx on public.news (author_id);

create table public.homepage_banners (
  id             uuid primary key default gen_random_uuid(),
  title          text not null check (length(trim(title)) > 0),
  subtitle       text,
  image_path     text,
  button_text    text,
  link_url       text check (link_url is null or link_url ~ '^(https://|/)'),
  display_order  smallint not null default 0,
  starts_at      timestamptz,
  ends_at        timestamptz,
  status         text not null default 'draft'
                 check (status in ('draft', 'published', 'archived')),
  published_at   timestamptz,
  updated_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint homepage_banners_dates_check check (ends_at is null or starts_at is null or ends_at > starts_at),
  constraint homepage_banners_published_check check (status <> 'published' or published_at is not null)
);

create table public.testimonials (
  id             uuid primary key default gen_random_uuid(),
  author_name    text not null check (length(trim(author_name)) > 0),
  author_role    text,
  quote          text not null check (length(trim(quote)) > 0),
  consent_given  boolean not null default false,
  display_order  smallint not null default 0,
  status         text not null default 'draft'
                 check (status in ('draft', 'published', 'archived')),
  published_at   timestamptz,
  created_by     uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- A testimonial can be shown only with the author's permission
  constraint testimonials_published_check
    check (status <> 'published' or (consent_given and published_at is not null))
);

create table public.contact_messages (
  id             uuid primary key default gen_random_uuid(),
  full_name      text not null check (length(trim(full_name)) > 0),
  email          text not null
                 check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  phone          text,
  subject        text,
  message        text not null check (length(trim(message)) > 0 and length(message) <= 5000),
  consent_given  boolean not null check (consent_given),
  ip_hash        text,
  status         text not null default 'new'
                 check (status in ('new', 'read', 'replied', 'spam')),
  handled_by     uuid references public.profiles (id) on delete set null,
  handled_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index contact_messages_status_idx on public.contact_messages (status, created_at);
create index contact_messages_handled_by_idx on public.contact_messages (handled_by);

-- ---------------------------------------------------------------
-- media_consents and gallery (student photograph safeguards)
-- ---------------------------------------------------------------
create table public.media_consents (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references public.students (id) on delete restrict,
  guardian_id   uuid not null references public.guardians (id) on delete restrict,
  consent_type  text not null check (consent_type in ('website', 'social_media', 'print', 'all')),
  status        text not null default 'granted' check (status in ('granted', 'withdrawn')),
  granted_at    timestamptz not null default now(),
  withdrawn_at  timestamptz,
  expires_on    date,
  notes         text,
  recorded_by   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint media_consents_withdrawn_check
    check (status <> 'withdrawn' or withdrawn_at is not null)
);

-- One active consent of each type per student
create unique index media_consents_one_active
  on public.media_consents (student_id, consent_type) where status = 'granted';

create index media_consents_guardian_id_idx on public.media_consents (guardian_id);

create table public.gallery_items (
  id                 uuid primary key default gen_random_uuid(),
  title              text not null check (length(trim(title)) > 0),
  caption            text,
  album              text,
  image_path         text not null check (length(trim(image_path)) > 0),
  taken_on           date,
  display_order      smallint not null default 0,
  contains_students  boolean not null default false,
  status             text not null default 'draft'
                     check (status in ('draft', 'published', 'archived')),
  published_at       timestamptz,
  uploaded_by        uuid references public.profiles (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint gallery_items_published_check check (status <> 'published' or published_at is not null)
);

create index gallery_items_status_idx on public.gallery_items (status);
create index gallery_items_album_idx on public.gallery_items (album);

create table public.gallery_item_students (
  gallery_item_id  uuid not null references public.gallery_items (id) on delete cascade,
  student_id       uuid not null references public.students (id) on delete restrict,
  created_at       timestamptz not null default now(),
  primary key (gallery_item_id, student_id)
);

create index gallery_item_students_student_id_idx on public.gallery_item_students (student_id);

-- True when the student has a granted consent that covers website use
create or replace function public.student_has_website_consent(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.media_consents mc
     where mc.student_id = p_student_id
       and mc.status = 'granted'
       and mc.consent_type in ('website', 'all')
       and (mc.expires_on is null or mc.expires_on >= current_date)
  );
$$;

-- A gallery item can be published only if students are tagged and all have consent
create or replace function public.check_gallery_publish()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'published' then
    if new.contains_students
       and not exists (select 1 from public.gallery_item_students
                        where gallery_item_id = new.id) then
      raise exception 'Tag the students shown in this item before publishing it';
    end if;
    if exists (
      select 1 from public.gallery_item_students gs
       where gs.gallery_item_id = new.id
         and not public.student_has_website_consent(gs.student_id)
    ) then
      raise exception 'A tagged student has no media consent for website use';
    end if;
  end if;
  return new;
end;
$$;

create trigger gallery_items_check_publish
  before insert or update of status, contains_students
  on public.gallery_items
  for each row execute function public.check_gallery_publish();

-- Tagging a student on an already published item also needs consent
create or replace function public.check_gallery_tag()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  select status into v_status from public.gallery_items where id = new.gallery_item_id;
  if v_status = 'published' and not public.student_has_website_consent(new.student_id) then
    raise exception 'This student has no media consent for website use';
  end if;
  return new;
end;
$$;

create trigger gallery_item_students_check_tag
  before insert on public.gallery_item_students
  for each row execute function public.check_gallery_tag();

-- Withdrawing website consent takes the student's photographs off the website
create or replace function public.unpublish_on_consent_withdrawn()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.gallery_items gi
     set status = 'archived'
   where gi.status = 'published'
     and exists (select 1 from public.gallery_item_students gs
                  where gs.gallery_item_id = gi.id and gs.student_id = new.student_id);
  return null;
end;
$$;

create trigger media_consents_withdrawn
  after update of status on public.media_consents
  for each row
  when (new.status = 'withdrawn' and old.status is distinct from 'withdrawn'
        and new.consent_type in ('website', 'all'))
  execute function public.unpublish_on_consent_withdrawn();

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
create trigger announcements_set_updated_at
  before update on public.announcements
  for each row execute function public.set_updated_at();

create trigger notification_preferences_set_updated_at
  before update on public.notification_preferences
  for each row execute function public.set_updated_at();

create trigger email_logs_set_updated_at
  before update on public.email_logs
  for each row execute function public.set_updated_at();

create trigger conversations_set_updated_at
  before update on public.conversations
  for each row execute function public.set_updated_at();

create trigger events_set_updated_at
  before update on public.events
  for each row execute function public.set_updated_at();

create trigger website_pages_set_updated_at
  before update on public.website_pages
  for each row execute function public.set_updated_at();

create trigger news_set_updated_at
  before update on public.news
  for each row execute function public.set_updated_at();

create trigger homepage_banners_set_updated_at
  before update on public.homepage_banners
  for each row execute function public.set_updated_at();

create trigger testimonials_set_updated_at
  before update on public.testimonials
  for each row execute function public.set_updated_at();

create trigger contact_messages_set_updated_at
  before update on public.contact_messages
  for each row execute function public.set_updated_at();

create trigger media_consents_set_updated_at
  before update on public.media_consents
  for each row execute function public.set_updated_at();

create trigger gallery_items_set_updated_at
  before update on public.gallery_items
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------
-- Keep helper functions away from browser keys
-- ---------------------------------------------------------------
revoke execute on function public.check_message_sender()
  from public, anon, authenticated;
revoke execute on function public.student_has_website_consent(uuid)
  from public, anon, authenticated;
revoke execute on function public.check_gallery_publish()
  from public, anon, authenticated;
revoke execute on function public.check_gallery_tag()
  from public, anon, authenticated;
revoke execute on function public.unpublish_on_consent_withdrawn()
  from public, anon, authenticated;

-- ---------------------------------------------------------------
-- Row Level Security: ON for every table (policies come in Step 8)
-- ---------------------------------------------------------------
alter table public.announcements             enable row level security;
alter table public.announcement_targets      enable row level security;
alter table public.notifications             enable row level security;
alter table public.notification_preferences  enable row level security;
alter table public.email_logs                enable row level security;
alter table public.conversations             enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages                  enable row level security;
alter table public.events                    enable row level security;
alter table public.website_pages             enable row level security;
alter table public.news                      enable row level security;
alter table public.homepage_banners          enable row level security;
alter table public.testimonials              enable row level security;
alter table public.contact_messages          enable row level security;
alter table public.media_consents            enable row level security;
alter table public.gallery_items             enable row level security;
alter table public.gallery_item_students     enable row level security;

-- ---------------------------------------------------------------
-- Seed: draft placeholders for the website pages in the plan.
-- Titles only; the School Admin writes and publishes the content.
-- ---------------------------------------------------------------
insert into public.website_pages (slug, title, display_order) values
  ('about',               'About Us',                  1),
  ('vision-mission',      'Vision and Mission',        2),
  ('history',             'School History',            3),
  ('leadership',          'Leadership',                4),
  ('primary-education',   'Primary Education',         5),
  ('junior-secondary',    'Junior Secondary Education', 6),
  ('senior-secondary',    'Senior Secondary Education', 7),
  ('admissions',          'Admissions',                8),
  ('contact',             'Contact Us',                9),
  ('privacy-policy',      'Privacy Policy',           10),
  ('terms-and-conditions','Terms and Conditions',     11);

commit;