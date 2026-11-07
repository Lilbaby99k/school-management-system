-- Migration 0007: Finance
-- Project: Bright Future Academy (BFA) school platform
-- Run once, after migrations 0001 to 0006.
-- Everything runs in one transaction: if any statement fails, nothing is applied.
--
-- Design notes
--  * All money is stored in kobo as whole numbers (NGN 1 = 100 kobo). No decimals.
--  * An invoice's subtotal, discount and amount paid are never typed in by hand:
--    triggers recompute them from invoice_items, APPROVED invoice_discounts and
--    VERIFIED payments. Invoice status moves issued > partially_paid > paid the same way.
--  * A Paystack payment can only be marked verified when a confirmed, successful
--    provider transaction for the same amount exists. Cash, POS and bank transfer
--    payments need a named verifier.
--  * payment_transactions (the raw provider records) is append-only, and its
--    provider event id is unique, so a repeated webhook cannot be counted twice.
--  * Payments cannot be deleted. A mistake is handled by marking the payment
--    'reversed' with a reason.
--  * Browser access is blocked until the policies migration (Step 8); money-changing
--    work is done by the backend only.
--  * Not seeded: discount rules and fee amounts, because the percentages and amounts
--    are the school's decisions. Fee categories are seeded from your list.

begin;

-- ---------------------------------------------------------------
-- Number sequences for invoices and receipts
-- ---------------------------------------------------------------
create sequence public.invoice_number_seq start 1;
create sequence public.receipt_number_seq start 1;

-- ---------------------------------------------------------------
-- fee_categories and fee_structures
-- ---------------------------------------------------------------
create table public.fee_categories (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique check (length(trim(name)) > 0),
  code         text not null unique check (code ~ '^[A-Z0-9_]+$'),
  description  text,
  is_optional  boolean not null default false,
  is_active    boolean not null default true,
  sort_order   smallint not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.fee_structures (
  id               uuid primary key default gen_random_uuid(),
  session_id       uuid not null references public.academic_sessions (id) on delete restrict,
  class_id         uuid not null references public.classes (id) on delete restrict,
  fee_category_id  uuid not null references public.fee_categories (id) on delete restrict,
  amount_kobo      bigint not null check (amount_kobo >= 0),
  frequency        text not null default 'per_term'
                   check (frequency in ('per_term', 'once_per_session')),
  is_active        boolean not null default true,
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint fee_structures_unique unique (session_id, class_id, fee_category_id)
);

create index fee_structures_class_id_idx on public.fee_structures (class_id);
create index fee_structures_fee_category_id_idx on public.fee_structures (fee_category_id);

-- ---------------------------------------------------------------
-- discount_rules (sibling, staff-child and other configurable discounts)
-- ---------------------------------------------------------------
create table public.discount_rules (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null unique check (length(trim(name)) > 0),
  rule_type          text not null
                     check (rule_type in ('sibling', 'staff_child', 'scholarship', 'other')),
  calculation        text not null check (calculation in ('percentage', 'fixed')),
  percentage         numeric(5,2) check (percentage is null or (percentage > 0 and percentage <= 100)),
  fixed_amount_kobo  bigint check (fixed_amount_kobo is null or fixed_amount_kobo > 0),
  fee_category_id    uuid references public.fee_categories (id) on delete restrict,
  min_siblings       smallint check (min_siblings is null or min_siblings >= 2),
  is_active          boolean not null default true,
  created_by         uuid references public.profiles (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint discount_rules_calc_columns_check(
    (calculation = 'percentage' and percentage is not null and fixed_amount_kobo is null)
    or (calculation = 'fixed' and fixed_amount_kobo is not null and percentage is null)
  )
);

create index discount_rules_fee_category_id_idx on public.discount_rules (fee_category_id);

-- ---------------------------------------------------------------
-- invoices (totals are maintained by triggers, not typed in)
-- ---------------------------------------------------------------
create table public.invoices (
  id                uuid primary key default gen_random_uuid(),
  invoice_number    text not null unique
                    default ('INV/' || to_char(now(), 'YY') || '/'
                             || lpad(nextval('public.invoice_number_seq')::text, 6, '0')),
  student_id        uuid not null references public.students (id) on delete restrict,
  enrollment_id     uuid not null references public.student_enrollments (id) on delete restrict,
  term_id           uuid not null references public.terms (id) on delete restrict,
  currency          text not null default 'NGN' check (currency = 'NGN'),
  subtotal_kobo     bigint not null default 0 check (subtotal_kobo >= 0),
  discount_kobo     bigint not null default 0 check (discount_kobo >= 0),
  total_kobo        bigint generated always as (subtotal_kobo - discount_kobo) stored,
  amount_paid_kobo  bigint not null default 0 check (amount_paid_kobo >= 0),
  balance_kobo      bigint generated always as (subtotal_kobo - discount_kobo - amount_paid_kobo) stored,
  status            text not null default 'draft'
                    check (status in ('draft', 'issued', 'partially_paid', 'paid', 'cancelled')),
  due_date          date,
  issued_at         timestamptz,
  cancelled_at      timestamptz,
  cancelled_reason  text,
  notes             text,
  created_by        uuid references public.profiles (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint invoices_discount_check check (discount_kobo <= subtotal_kobo),
  constraint invoices_paid_check check (amount_paid_kobo <= subtotal_kobo - discount_kobo),
  constraint invoices_issued_check
    check (status in ('draft', 'cancelled') or issued_at is not null),
  constraint invoices_cancelled_check
    check (status <> 'cancelled'
           or (cancelled_at is not null and length(trim(coalesce(cancelled_reason, ''))) >= 5))
);

create index invoices_student_id_idx on public.invoices (student_id);
create index invoices_enrollment_id_idx on public.invoices (enrollment_id);
create index invoices_term_id_idx on public.invoices (term_id);
create index invoices_status_idx on public.invoices (status);
create index invoices_due_date_idx on public.invoices (due_date);

-- The enrollment must belong to the same student as the invoice
create or replace function public.check_invoice_enrollment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  e_student uuid;
begin
  select student_id into e_student
    from public.student_enrollments where id = new.enrollment_id;
  if e_student is distinct from new.student_id then
    raise exception 'The enrollment does not belong to the invoiced student';
  end if;
  return new;
end;
$$;

create trigger invoices_check_enrollment
  before insert or update of student_id, enrollment_id
  on public.invoices
  for each row execute function public.check_invoice_enrollment();

-- ---------------------------------------------------------------
-- invoice_items (price copied at billing time; editable only on drafts)
-- ---------------------------------------------------------------
create table public.invoice_items (
  id                uuid primary key default gen_random_uuid(),
  invoice_id        uuid not null references public.invoices (id) on delete restrict,
  fee_category_id   uuid not null references public.fee_categories (id) on delete restrict,
  description       text not null check (length(trim(description)) > 0),
  quantity          integer not null default 1 check (quantity > 0),
  unit_amount_kobo  bigint not null check (unit_amount_kobo >= 0),
  amount_kobo       bigint generated always as (quantity * unit_amount_kobo) stored,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index invoice_items_invoice_id_idx on public.invoice_items (invoice_id);
create index invoice_items_fee_category_id_idx on public.invoice_items (fee_category_id);

create or replace function public.check_invoice_items_editable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id     uuid;
  v_status text;
begin
  if tg_op = 'DELETE' then
    v_id := old.invoice_id;
  else
    v_id := new.invoice_id;
  end if;

  select status into v_status from public.invoices where id = v_id;
  if v_status is distinct from 'draft' then
    raise exception 'Invoice items can only be changed while the invoice is a draft';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger invoice_items_editable
  before insert or update or delete on public.invoice_items
  for each row execute function public.check_invoice_items_editable();

-- ---------------------------------------------------------------
-- invoice_installments (part-payment schedule with deadlines)
-- ---------------------------------------------------------------
create table public.invoice_installments (
  id                  uuid primary key default gen_random_uuid(),
  invoice_id          uuid not null references public.invoices (id) on delete restrict,
  installment_number  smallint not null check (installment_number > 0),
  amount_kobo         bigint not null check (amount_kobo > 0),
  due_date            date not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint invoice_installments_unique unique (invoice_id, installment_number)
);

-- ---------------------------------------------------------------
-- invoice_discounts (rule-based or manual with reason and approval)
-- Only APPROVED discounts reduce an invoice.
-- ---------------------------------------------------------------
create table public.invoice_discounts (
  id                uuid primary key default gen_random_uuid(),
  invoice_id        uuid not null references public.invoices (id) on delete restrict,
  discount_type     text not null check (discount_type in ('rule', 'manual')),
  discount_rule_id  uuid references public.discount_rules (id) on delete restrict,
  description       text not null check (length(trim(description)) > 0),
  amount_kobo       bigint not null check (amount_kobo > 0),
  reason            text,
  status            text not null default 'pending'
                    check (status in ('pending', 'approved', 'rejected')),
  requested_by      uuid references public.profiles (id) on delete restrict,
  approved_by       uuid references public.profiles (id) on delete restrict,
  approved_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint invoice_discounts_rule_check
    check (discount_type <> 'rule' or discount_rule_id is not null),
  constraint invoice_discounts_manual_reason_check
    check (discount_type <> 'manual' or length(trim(coalesce(reason, ''))) >= 5),
  constraint invoice_discounts_approved_check
    check (status <> 'approved' or (approved_by is not null and approved_at is not null)),
  constraint invoice_discounts_manual_requester_check
    check (discount_type <> 'manual' or requested_by is not null),
  -- A manual discount cannot be approved by the person who requested it
  constraint invoice_discounts_separation_check
    check (discount_type <> 'manual' or approved_by is distinct from requested_by)
);

create index invoice_discounts_invoice_id_idx on public.invoice_discounts (invoice_id);
create index invoice_discounts_rule_id_idx on public.invoice_discounts (discount_rule_id);

-- ---------------------------------------------------------------
-- payments
-- ---------------------------------------------------------------
create table public.payments (
  id                    uuid primary key default gen_random_uuid(),
  invoice_id            uuid not null references public.invoices (id) on delete restrict,
  reference             text not null unique check (length(trim(reference)) > 0),
  amount_kobo           bigint not null check (amount_kobo > 0),
  method                text not null check (method in ('paystack', 'bank_transfer', 'cash', 'pos')),
  status                text not null default 'pending'
                        check (status in ('pending', 'verified', 'failed', 'reversed')),
  paid_by_guardian_id   uuid references public.guardians (id) on delete restrict,
  recorded_by           uuid references public.profiles (id) on delete set null,
  verified_by           uuid references public.profiles (id) on delete restrict,
  verified_at           timestamptz,
  reversal_reason       text,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint payments_verified_check
    check (status <> 'verified' or verified_at is not null),
  -- Cash, POS and bank transfers need a named person who verified them
  constraint payments_manual_verified_check
    check (status <> 'verified' or method = 'paystack' or verified_by is not null),
  constraint payments_reversal_check
    check (status <> 'reversed' or length(trim(coalesce(reversal_reason, ''))) >= 5)
);

create index payments_invoice_id_idx on public.payments (invoice_id);
create index payments_status_idx on public.payments (status);
create index payments_guardian_id_idx on public.payments (paid_by_guardian_id);

-- ---------------------------------------------------------------
-- payment_transactions: append-only record of everything the provider sent
-- ---------------------------------------------------------------
create table public.payment_transactions (
  id                  uuid primary key default gen_random_uuid(),
  payment_id          uuid not null references public.payments (id) on delete restrict,
  provider            text not null default 'paystack' check (provider = 'paystack'),
  provider_reference  text not null check (length(trim(provider_reference)) > 0),
  event_id            text,
  source              text not null check (source in ('initialize', 'verify', 'webhook')),
  event_type          text,
  provider_status     text,
  amount_kobo         bigint check (amount_kobo is null or amount_kobo >= 0),
  currency            text,
  is_confirmed        boolean not null default false,
  raw_payload         jsonb,
  received_at         timestamptz not null default now()
);

-- The same provider event can never be recorded twice
create unique index payment_transactions_event_unique
  on public.payment_transactions (provider, event_id) where event_id is not null;

create index payment_transactions_payment_id_idx on public.payment_transactions (payment_id);
create index payment_transactions_reference_idx on public.payment_transactions (provider_reference);

create trigger payment_transactions_append_only
  before update or delete on public.payment_transactions
  for each row execute function public.prevent_row_modification();

-- Payments are never deleted; mistakes are handled by reversal
create trigger payments_no_delete
  before delete on public.payments
  for each row execute function public.prevent_row_modification();

-- A Paystack payment can be verified only with a confirmed successful transaction
create or replace function public.check_payment_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'verified' and new.method = 'paystack' then
    if not exists (
      select 1
        from public.payment_transactions t
       where t.payment_id = new.id
         and t.provider = 'paystack'
         and t.provider_status = 'success'
         and t.is_confirmed
         and t.amount_kobo = new.amount_kobo
    ) then
      raise exception 'A Paystack payment cannot be verified without a confirmed successful transaction for the same amount';
    end if;
  end if;
  return new;
end;
$$;

create trigger payments_check_verification
  before insert or update of status, amount_kobo
  on public.payments
  for each row execute function public.check_payment_verification();

-- ---------------------------------------------------------------
-- receipts: one per verified payment
-- ---------------------------------------------------------------
create table public.receipts (
  id              uuid primary key default gen_random_uuid(),
  receipt_number  text not null unique
                  default ('RCT/' || to_char(now(), 'YY') || '/'
                           || lpad(nextval('public.receipt_number_seq')::text, 6, '0')),
  payment_id      uuid not null unique references public.payments (id) on delete restrict,
  invoice_id      uuid not null references public.invoices (id) on delete restrict,
  amount_kobo     bigint not null check (amount_kobo > 0),
  file_path       text,
  issued_by       uuid references public.profiles (id) on delete set null,
  issued_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index receipts_invoice_id_idx on public.receipts (invoice_id);

-- A receipt must match a verified payment (same invoice, same amount)
create or replace function public.check_receipt_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  p_status  text;
  p_invoice uuid;
  p_amount  bigint;
begin
  select status, invoice_id, amount_kobo into p_status, p_invoice, p_amount
    from public.payments where id = new.payment_id;

  if p_status is distinct from 'verified' then
    raise exception 'A receipt can only be issued for a verified payment';
  end if;
  if p_invoice is distinct from new.invoice_id or p_amount is distinct from new.amount_kobo then
    raise exception 'The receipt does not match the payment invoice or amount';
  end if;
  return new;
end;
$$;

create trigger receipts_check_payment
  before insert on public.receipts
  for each row execute function public.check_receipt_payment();

-- ---------------------------------------------------------------
-- Recompute invoice totals and status from items, approved discounts
-- and verified payments
-- ---------------------------------------------------------------
create or replace function public.recalculate_invoice(p_invoice_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.invoices i
     set subtotal_kobo = coalesce((select sum(amount_kobo) from public.invoice_items
                                    where invoice_id = p_invoice_id), 0),
         discount_kobo = coalesce((select sum(amount_kobo) from public.invoice_discounts
                                    where invoice_id = p_invoice_id and status = 'approved'), 0),
         amount_paid_kobo = coalesce((select sum(amount_kobo) from public.payments
                                       where invoice_id = p_invoice_id and status = 'verified'), 0)
   where i.id = p_invoice_id;

  update public.invoices i
     set status = case
           when i.total_kobo > 0 and i.amount_paid_kobo >= i.total_kobo then 'paid'
           when i.amount_paid_kobo > 0 then 'partially_paid'
           else 'issued'
         end
   where i.id = p_invoice_id
     and i.status in ('issued', 'partially_paid', 'paid');
end;
$$;

create or replace function public.recalculate_invoice_after_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recalculate_invoice(old.invoice_id);
  else
    perform public.recalculate_invoice(new.invoice_id);
  end if;
  return null;
end;
$$;

create trigger invoice_items_recalculate
  after insert or update or delete on public.invoice_items
  for each row execute function public.recalculate_invoice_after_change();

create trigger invoice_discounts_recalculate
  after insert or update or delete on public.invoice_discounts
  for each row execute function public.recalculate_invoice_after_change();

create trigger payments_recalculate
  after insert or update of status, amount_kobo, invoice_id on public.payments
  for each row execute function public.recalculate_invoice_after_change();

-- ---------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------
create trigger fee_categories_set_updated_at
  before update on public.fee_categories
  for each row execute function public.set_updated_at();

create trigger fee_structures_set_updated_at
  before update on public.fee_structures
  for each row execute function public.set_updated_at();

create trigger discount_rules_set_updated_at
  before update on public.discount_rules
  for each row execute function public.set_updated_at();

create trigger invoices_set_updated_at
  before update on public.invoices
  for each row execute function public.set_updated_at();

create trigger invoice_items_set_updated_at
  before update on public.invoice_items
  for each row execute function public.set_updated_at();

create trigger invoice_installments_set_updated_at
  before update on public.invoice_installments
  for each row execute function public.set_updated_at();

create trigger invoice_discounts_set_updated_at
  before update on public.invoice_discounts
  for each row execute function public.set_updated_at();

create trigger payments_set_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

create trigger receipts_set_updated_at
  before update on public.receipts
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------
-- Keep helper functions away from browser keys
-- ---------------------------------------------------------------
revoke execute on function public.check_invoice_enrollment()
  from public, anon, authenticated;
revoke execute on function public.check_invoice_items_editable()
  from public, anon, authenticated;
revoke execute on function public.check_payment_verification()
  from public, anon, authenticated;
revoke execute on function public.check_receipt_payment()
  from public, anon, authenticated;
revoke execute on function public.recalculate_invoice(uuid)
  from public, anon, authenticated;
revoke execute on function public.recalculate_invoice_after_change()
  from public, anon, authenticated;

-- ---------------------------------------------------------------
-- Row Level Security: ON for every table (policies come in Step 8)
-- ---------------------------------------------------------------
alter table public.fee_categories         enable row level security;
alter table public.fee_structures         enable row level security;
alter table public.discount_rules         enable row level security;
alter table public.invoices               enable row level security;
alter table public.invoice_items          enable row level security;
alter table public.invoice_installments   enable row level security;
alter table public.invoice_discounts      enable row level security;
alter table public.payments               enable row level security;
alter table public.payment_transactions   enable row level security;
alter table public.receipts               enable row level security;

-- ---------------------------------------------------------------
-- Seed: fee categories from the school's list (transport is off until used)
-- ---------------------------------------------------------------
insert into public.fee_categories (name, code, description, is_optional, is_active, sort_order) values
  ('Tuition Fees',               'TUITION',      'Main academic fees paid per term.',                   false, true,  1),
  ('Registration Fees',          'REGISTRATION', 'New student registration charges.',                   false, true,  2),
  ('Examination Fees',           'EXAM',         'Examination and assessment charges.',                 false, true,  3),
  ('Uniform Fees',               'UNIFORM',      'School uniforms and other approved clothing.',        true,  true,  4),
  ('Books & Learning Materials', 'BOOKS',        'Textbooks, notebooks and learning materials.',        true,  true,  5),
  ('Development Levy',           'DEV_LEVY',     'School development and maintenance charges.',         false, true,  6),
  ('Other Fees',                 'OTHER',        'Any additional charges created by the School Admin.', true,  true,  7),
  ('Transport Fees',             'TRANSPORT',    'Optional; activate when transport services start.',   true,  false, 8);

commit;