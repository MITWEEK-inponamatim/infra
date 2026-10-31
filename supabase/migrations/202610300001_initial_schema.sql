create extension if not exists pgcrypto with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now()
);

create table public.scans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null check (type in ('url', 'message', 'phone', 'image', 'application')),
  input_ref text,
  status text not null default 'queued' check (status in ('queued', 'running', 'completed', 'failed')),
  outcome text check (outcome in ('confirmed_threat', 'suspicious', 'insufficient_evidence', 'scan_failed')),
  risk_level text check (risk_level in ('low', 'medium', 'high', 'unknown')),
  report jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);

create index scans_user_created_idx on public.scans (user_id, created_at desc);

create table public.files (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  scan_id uuid not null references public.scans(id) on delete cascade,
  bucket text not null check (bucket in ('uploads', 'scan-artifacts')),
  storage_path text not null,
  sha256 text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  mime text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz
);

create index files_scan_idx on public.files (scan_id);

create table public.analysis_jobs (
  job_id uuid primary key default gen_random_uuid(),
  scan_id uuid not null unique references public.scans(id) on delete cascade,
  type text not null check (type in ('url', 'message', 'phone', 'image', 'application')),
  status text not null default 'queued' check (status in ('queued', 'running', 'completed', 'failed')),
  progress integer not null default 0 check (progress between 0 and 100),
  report jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.app_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  supabase_session_id text not null unique,
  created_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_reason text,
  ip text,
  user_agent text
);

create index app_sessions_user_idx on public.app_sessions (user_id, created_at desc);

create table public.auth_preflight (
  nonce text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  ip text
);

create table public.auth_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  event text not null,
  ip text,
  user_agent text,
  created_at timestamptz not null default now()
);

create table public.llm_usage (
  id uuid primary key default gen_random_uuid(),
  scan_id uuid not null references public.scans(id) on delete cascade,
  model text not null,
  prompt_tokens integer not null default 0,
  completion_tokens integer not null default 0,
  latency_ms integer not null default 0,
  status text not null,
  created_at timestamptz not null default now()
);

create table public.phone_reports (
  id uuid primary key default gen_random_uuid(),
  number_e164 text not null,
  category text not null,
  source text not null,
  reported_by uuid references auth.users(id) on delete set null,
  status text not null default 'pending',
  created_at timestamptz not null default now()
);

create index phone_reports_number_idx on public.phone_reports (number_e164, created_at desc);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger scans_set_updated_at before update on public.scans
for each row execute function public.set_updated_at();
create trigger analysis_jobs_set_updated_at before update on public.analysis_jobs
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, display_name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do update set
    email = excluded.email,
    display_name = excluded.display_name,
    avatar_url = excluded.avatar_url;
  return new;
end;
$$;

create trigger on_auth_user_created after insert or update of email, raw_user_meta_data on auth.users
for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.scans enable row level security;
alter table public.files enable row level security;
alter table public.analysis_jobs enable row level security;
alter table public.app_sessions enable row level security;
alter table public.auth_preflight enable row level security;
alter table public.auth_events enable row level security;
alter table public.llm_usage enable row level security;
alter table public.phone_reports enable row level security;

create policy profiles_select_own on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy scans_select_own on public.scans for select to authenticated using (user_id = (select auth.uid()));
create policy files_select_own on public.files for select to authenticated using (user_id = (select auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit)
values ('uploads', 'uploads', false, 52428800), ('scan-artifacts', 'scan-artifacts', false, 10485760)
on conflict (id) do update set public = false;

create policy uploads_read_own on storage.objects for select to authenticated
using (bucket_id = 'uploads' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy artifacts_read_own on storage.objects for select to authenticated
using (bucket_id = 'scan-artifacts' and (storage.foldername(name))[1] = (select auth.uid())::text);
