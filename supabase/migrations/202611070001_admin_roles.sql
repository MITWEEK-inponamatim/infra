-- Admin role system untuk moderasi community posts.
--
-- Role disimpan di profiles, bukan auth.users, karena app-level concern (bukan authn).
-- Default 'user'; admin ditunjuk manual via SQL atau admin panel terpisah.

alter table public.profiles add column if not exists role text not null default 'user'
  check (role in ('user', 'admin'));

create index if not exists profiles_role_idx on public.profiles (role) where role = 'admin';

comment on column public.profiles.role is
  'Role level: user (default) atau admin (moderasi). Admin bisa soft-delete community posts.';
