-- Komunitas: post pengalaman tentang nomor +62, vote, dan untaian komentar.
--
-- Sengaja tabel TERPISAH dari phone_reports. Laporan = "nomor ini mencurigakan" (satu baris per
-- akun per nomor, dan hanya inilah yang menaikkan risiko di checker). Post = cerita pengalamannya.
-- Karena itu skor vote tidak pernah dipakai untuk menghitung risiko: Tab Terpopuler dan Tab
-- Nomor Berbahaya menjawab pertanyaan yang berbeda.
--
-- Semua tabel ditutup RLS tanpa policy: tidak ada peran anon/authenticated yang boleh membaca
-- langsung. Satu-satunya pemakai adalah Go API dengan service role, dan di sanalah identitas
-- (author_user_id) dipotong sebelum keluar ke browser.

create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  number_e164 text not null,
  category text not null,
  title text not null,
  body text not null,
  evidence_url text not null,
  evidence_public_id text not null,
  author_user_id uuid not null,
  author_alias text not null,
  status text not null default 'active',
  up_count integer not null default 0,
  down_count integer not null default 0,
  comment_count integer not null default 0,
  -- Skor ditulis sebagai kolom jadi (generated) supaya PostgREST bisa memakainya di order=…:
  -- REST hanya mau nama kolom, bukan ekspresi aritmetika, dan Tab Terpopuler harus diurutkan di
  -- database — kalau tidak, urutan berubah-ubah tergantung halaman yang sudah diambil.
  score integer generated always as (up_count - down_count) stored,
  created_at timestamptz not null default now(),
  constraint community_posts_category_check
    check (category in ('phishing', 'penipuan', 'pharming', 'spam', 'peniruan_identitas')),
  constraint community_posts_number_shape check (number_e164 ~ '^\+62[0-9]{8,20}$'),
  constraint community_posts_title_length check (char_length(title) between 4 and 120),
  constraint community_posts_body_length check (char_length(body) between 10 and 4000),
  constraint community_posts_evidence_url_shape
    check (evidence_url ~ '^https://res\.cloudinary\.com/' and char_length(evidence_url) <= 2048),
  constraint community_posts_evidence_public_id_shape
    check (evidence_public_id like 'threatlens/phone-reports/%' and char_length(evidence_public_id) <= 512),
  constraint community_posts_status_check check (status in ('active', 'removed')),
  constraint community_posts_alias_shape check (author_alias ~ '^Warga-[0-9a-f]{6}$')
);

create table if not exists public.community_votes (
  post_id uuid not null references public.community_posts (id) on delete cascade,
  user_id uuid not null,
  value smallint not null check (value in (1, -1)),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts (id) on delete cascade,
  parent_id uuid references public.community_comments (id) on delete cascade,
  body text not null,
  author_user_id uuid not null,
  author_alias text not null,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  constraint community_comments_body_length check (char_length(body) between 1 and 1000),
  constraint community_comments_alias_shape check (author_alias ~ '^Warga-[0-9a-f]{6}$'),
  constraint community_comments_status_check check (status in ('active', 'removed'))
  -- "Tidak boleh membalas balasan" ada di trigger community_comments_depth di bawah, bukan di sini:
  -- PostgreSQL melarang subquery di dalam CHECK, jadi aturan yang butuh membaca baris lain
  -- (parent-nya punya parent apa tidak) tidak bisa dinyatakan sebagai constraint.
);

create index if not exists community_posts_new_idx
  on public.community_posts (created_at desc) where status = 'active';
create index if not exists community_posts_top_idx
  on public.community_posts (score desc, created_at desc) where status = 'active';
create index if not exists community_posts_number_idx on public.community_posts (number_e164, created_at desc);
create index if not exists community_votes_user_idx on public.community_votes (user_id);
create index if not exists community_comments_post_idx on public.community_comments (post_id, created_at);

-- Satu tingkat balasan saja, dipaksa di database karena API-nya bisa dipanggil dari mana saja.
-- BEFORE supaya baris yang menyalahi tidak pernah masuk; tanpa ini, untaian bisa memanjang lewat
-- INSERT langsung dan halaman detail tidak lagi muat di layar ponsel.
create or replace function public.community_comments_depth() returns trigger
language plpgsql as $$
begin
  if new.parent_id is not null and exists (
    select 1 from public.community_comments p
     where p.id = new.parent_id and p.parent_id is not null
  ) then
    raise exception 'reply_too_deep';
  end if;
  return new;
end $$;

drop trigger if exists community_comments_depth on public.community_comments;
create trigger community_comments_depth before insert or update of parent_id on public.community_comments
  for each row execute function public.community_comments_depth();

-- Penghitung ditulis ulang dari barisnya sendiri, bukan dinaikkan/turunkan. Selisih satu kolom
-- karena dua request bersamaan jauh lebih murah diperbaiki daripada satu komentar hilang.
create or replace function public.community_votes_sync_count() returns trigger
language plpgsql as $$
begin
  update public.community_posts
     set up_count = (select count(*) from public.community_votes where post_id = new.post_id and value = 1),
         down_count = (select count(*) from public.community_votes where post_id = new.post_id and value = -1)
   where id = new.post_id;
  return new;
end $$;

create or replace function public.community_votes_sync_count_delete() returns trigger
language plpgsql as $$
begin
  update public.community_posts
     set up_count = (select count(*) from public.community_votes where post_id = old.post_id and value = 1),
         down_count = (select count(*) from public.community_votes where post_id = old.post_id and value = -1)
   where id = old.post_id;
  return old;
end $$;

create or replace function public.community_comments_sync_count() returns trigger
language plpgsql as $$
begin
  update public.community_posts
     set comment_count = (select count(*) from public.community_comments
                          where post_id = new.post_id and status = 'active')
   where id = new.post_id;
  return new;
end $$;

-- Fungsi terpisah untuk DELETE, bukan coalesce(new.post_id, old.post_id): di trigger DELETE
-- variabel NEW belum ter-assign, dan PL/pgSQL menolak membaca field-nya — termasuk ketika ia
-- cuma argumen kedua yang tidak dipakai. Ini jalur yang benar-benar dipakai: ON DELETE CASCADE dari
-- community_posts ikut menghapus komentar, dan error di sini akan menggagalkan penghapusan post.
create or replace function public.community_comments_sync_count_delete() returns trigger
language plpgsql as $$
begin
  update public.community_posts
     set comment_count = (select count(*) from public.community_comments
                          where post_id = old.post_id and status = 'active')
   where id = old.post_id;
  return old;
end $$;

drop trigger if exists community_votes_count_insert on public.community_votes;
create trigger community_votes_count_insert after insert on public.community_votes
  for each row execute function public.community_votes_sync_count();

drop trigger if exists community_votes_count_update on public.community_votes;
create trigger community_votes_count_update after update on public.community_votes
  for each row execute function public.community_votes_sync_count();

drop trigger if exists community_votes_count_delete on public.community_votes;
create trigger community_votes_count_delete after delete on public.community_votes
  for each row execute function public.community_votes_sync_count_delete();

drop trigger if exists community_comments_count_insert on public.community_comments;
create trigger community_comments_count_insert after insert on public.community_comments
  for each row execute function public.community_comments_sync_count();

drop trigger if exists community_comments_count_update on public.community_comments;
create trigger community_comments_count_update after update on public.community_comments
  for each row execute function public.community_comments_sync_count();

drop trigger if exists community_comments_count_delete on public.community_comments;
create trigger community_comments_count_delete after delete on public.community_comments
  for each row execute function public.community_comments_sync_count_delete();

-- Satu statement untuk memilih/mengganti/mencabut vote, supaya dua klik dari akun yang sama tidak
-- pernah menghasilkan dua baris. Dipanggil sebagai security definer karena yang menjalankan
-- tetap layanan (bukan pemegang policy), dan hasilnya dibutuhkan langsung untuk UI.
create or replace function public.cast_vote(p_post_id uuid, p_user_id uuid, p_value integer)
returns table (up_count integer, down_count integer, my_vote integer)
language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  if p_value not in (-1, 0, 1) then
    raise exception 'invalid_vote_value';
  end if;
  if not exists (select 1 from public.community_posts where id = p_post_id and status = 'active') then
    raise exception 'post_not_found';
  end if;
  if p_value = 0 then
    delete from public.community_votes where post_id = p_post_id and user_id = p_user_id;
  else
    insert into public.community_votes (post_id, user_id, value)
      values (p_post_id, p_user_id, p_value::smallint)
      on conflict (post_id, user_id) do update set value = excluded.value, updated_at = now();
  end if;
  return query
    select cp.up_count, cp.down_count,
           coalesce((select cv.value from public.community_votes cv
                      where cv.post_id = cp.id and cv.user_id = p_user_id), 0)::integer
      from public.community_posts cp where cp.id = p_post_id;
end $$;

-- Tab "Nomor berbahaya". Ambangnya SAMA dengan aturan "high" di
-- analysis-service/app/phone_scanner.py::summarize_reports: dua laporan terverifikasi dari dua
-- akun berbeda. Post dan vote hanya ikut ditampilkan sebagai konteks, tidak menaikkan status —
-- kalau bagian ini diubah, ubah yang di Python juga.
create or replace view public.dangerous_numbers as
with verified as (
  select number_e164,
         count(*) filter (where status = 'verified') as verified_reports,
         count(distinct reported_by) filter (where status = 'verified') as verified_reporters,
         count(*) as total_reports,
         max(created_at) as last_report_at
    from public.phone_reports
   group by number_e164
), stories as (
  select number_e164,
         count(*) as community_posts,
         coalesce(sum(score), 0) as community_score
    from public.community_posts
   where status = 'active'
   group by number_e164
)
select v.number_e164, v.verified_reports, v.verified_reporters, v.total_reports, v.last_report_at,
       coalesce(s.community_posts, 0) as community_posts,
       coalesce(s.community_score, 0) as community_score
  from verified v
  left join stories s using (number_e164)
 where v.verified_reports >= 2 and v.verified_reporters >= 2;

comment on table public.community_posts is
  'Cerita pengalaman warga tentang satu nomor +62; bukan sinyal risiko (itu phone_reports).';
comment on column public.community_posts.author_user_id is
  'Rahasia. Tidak pernah dikirim ke browser; yang tampil hanya author_alias.';
comment on column public.community_posts.author_alias is
  'Alias determinatif Warga-<6 hex> dari HMAC(user_id) di Go; berubah jika PRE_COOKIE_SECRET berubah.';
comment on column public.community_posts.evidence_public_id is
  'Pegangan Cloudinary untuk menghapus gambarnya lagi; folder sama dengan laporan telepon.';
comment on column public.community_posts.up_count is 'Dihitung trigger dari community_votes, bukan sumber kebenaran tersendiri.';
comment on column public.community_posts.score is 'up_count - down_count; generated, jadi tidak pernah ditulis langsung oleh API. Hanya untuk urutan Tab Terpopuler, tidak pernah untuk risiko.';
comment on function public.cast_vote(uuid, uuid, integer) is
  'Ubah/cabut vote satu akun dalam satu statement; mengembalikan skor terbaru + pilihan pemanggil.';
comment on function public.community_comments_depth() is
  'Menolak balasan dari balasan: untaian komentar maksimal dua tingkat.';
comment on view public.dangerous_numbers is
  'Nomor dengan >=2 laporan terverifikasi dari >=2 pelapor berbeda; ambang yang sama dengan summarize_reports.';

alter table public.community_posts enable row level security;
alter table public.community_votes enable row level security;
alter table public.community_comments enable row level security;

-- Sengaja TANPA "force row level security". View dangerous_numbers membaca phone_reports dan
-- community_posts sebagai pemiliknya (postgres), dan FORCE menegakkan policy terhadap pemilik
-- tabel juga — tanpa satu policy pun view-nya jadi kosong untuk semua orang, termasuk API-nya,
-- tanpa error apa pun. anon/authenticated sudah terkunci dua lapis: RLS aktif tanpa policy, dan
-- grant-nya dicabut di bawah. Satu-satunya pemakai adalah service_role, yang bypassrls.
revoke all on public.community_posts from anon, authenticated;
revoke all on public.community_votes from anon, authenticated;
revoke all on public.community_comments from anon, authenticated;
revoke all on public.dangerous_numbers from anon, authenticated;
grant select, insert, update, delete on public.community_posts to service_role;
grant select, insert, update, delete on public.community_votes to service_role;
grant select, insert, update, delete on public.community_comments to service_role;
grant select on public.dangerous_numbers to service_role;
grant execute on function public.cast_vote(uuid, uuid, integer) to service_role;
