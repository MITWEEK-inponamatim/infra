-- Tabel bukti per-scan yang selama ini cuma ditulis kodenya
-- (analysis-service/app/evidence_storage.py) dan dibersihkan app/retention.py, tanpa DDL di repo.
-- HANDOFF analysis-service menyebut file 202611020001_scan_evidence_items.sql, tapi file itu tidak
-- pernah ada di infra/supabase/migrations. Jadi ada dua keadaan yang mungkin di project live:
-- tabelnya belum ada, atau tabelnya sudah dibuat lewat query ad-hoc dengan kolom/kunci berbeda.
-- Migration ini dibuat idempotent dan memulihkan keduanya ke skema yang SAMA: create/add column/
-- unique index/constraint semuanya if-not-exists atau dibungkus exception handler.
--
-- Kedua tabel hanya untuk service_role. Isinya payload hasil skill (manifest, daftar class, cocok
-- YARA) yang sudah diredaksi app/investigation/evidence.py tapi tetap bukan konsumsi browser.

create table if not exists public.scan_evidence_items (
  id uuid primary key default gen_random_uuid(),
  scan_id uuid not null,
  user_id uuid not null,
  evidence_id text not null,
  kind text not null,
  skill text not null default '',
  observed boolean not null default true,
  fact text not null default '',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  constraint scan_evidence_items_scan_fkey foreign key (scan_id) references public.scans (id) on delete cascade,
  constraint scan_evidence_items_user_fkey foreign key (user_id) references auth.users (id) on delete cascade
);

-- Satu baris snapshot per scan: threat intel, rekonek, dan browser untuk laporan URL.
create table if not exists public.scan_evidence (
  id uuid primary key default gen_random_uuid(),
  scan_id uuid not null,
  user_id uuid not null,
  threat_intel jsonb not null default '{}'::jsonb,
  recon_data jsonb not null default '{}'::jsonb,
  browser_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  constraint scan_evidence_scan_fkey foreign key (scan_id) references public.scans (id) on delete cascade,
  constraint scan_evidence_user_fkey foreign key (user_id) references auth.users (id) on delete cascade
);

-- Kolom yang hilang kalau tabelnya sudah lebih dulu dibuat ad-hoc. Default pada kolom NOT NULL
-- sekaligus mengisi baris lama, jadi tidak ada insert yang tiba-tiba menabrak not-null.
alter table public.scan_evidence_items
  add column if not exists skill text not null default '',
  add column if not exists observed boolean not null default true,
  add column if not exists fact text not null default '',
  add column if not exists payload jsonb not null default '{}'::jsonb,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists expires_at timestamptz not null default (now() + interval '7 days');

alter table public.scan_evidence
  add column if not exists threat_intel jsonb not null default '{}'::jsonb,
  add column if not exists recon_data jsonb not null default '{}'::jsonb,
  add column if not exists browser_data jsonb not null default '{}'::jsonb,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists expires_at timestamptz not null default (now() + interval '7 days');

-- save_evidence_items() mengirim batch dengan ?on_conflict=scan_id,evidence_id dan
-- save_scan_evidence() dengan ?on_conflict=scan_id. PostgREST menerjemahkannya menjadi
-- ON CONFLICT (kolom) DO UPDATE, yang di PostgreSQL cukup dipenuhi unique index biasa — jadi
-- indeks inilah kuncinya, bukan constraint di CREATE TABLE, supaya tetap terbentuk pada tabel
-- yang sudah ada. Tanpa kunci ini setiap penulisan bukti gagal (error 42P10) dan report hanya
-- menampilkan unavailable: evidence_items_storage.
create unique index if not exists scan_evidence_items_scan_evidence_key
  on public.scan_evidence_items (scan_id, evidence_id);
create unique index if not exists scan_evidence_scan_key
  on public.scan_evidence (scan_id);

-- Retention menghapus dengan filter expires_at < now() tiap jam; tanpa indeks ini purge jadi
-- full scan yang membesar bersama setiap baris bukti yang pernah ditulis.
create index if not exists scan_evidence_items_expires_idx
  on public.scan_evidence_items (expires_at) where expires_at is not null;
create index if not exists scan_evidence_expires_idx
  on public.scan_evidence (expires_at) where expires_at is not null;
create index if not exists scan_evidence_items_scan_idx
  on public.scan_evidence_items (scan_id, kind);

-- Constraint di bawah memakai nama yang SAMA dengan yang di dalam CREATE TABLE, jadi pada project
-- fresh blok ini tidak melakukan apa-apa (duplicate_object ditangkap) dan pada project yang tabelnya
-- sudah dibuat ad-hoc blok inilah yang memasang FK + CHECK. Yang tidak dipulihkan oleh migration
-- ini adalah nullability kolom lama (mis. payload yang tadinya boleh NULL): tidak pernah bikin
-- insert gagal, karena kode selalu mengirim nilai. Yang lain sengaja dibiarkan gagal supaya
-- kelihatan — misalnya foreign_key_violation berarti tabel lama masih punya baris yatim dan
-- perlu dibersihkan sebelum FK bisa dipasang.
do $constraints$
declare
  v_stmt text;
  v_stmts text[] := array[
    -- Bentuk evidence_id dibangkitkan EvidenceStore.add(): "ev_<kind>_<sha256[:12]>", dengan kind
    -- mengikuti KIND_RE di berkas yang sama. Kalau salah satu diubah, ubah yang di Python juga —
    -- sama alasannya dengan community_posts_alias_shape pada 0007.
    format('alter table public.scan_evidence_items add constraint scan_evidence_items_evidence_id_shape check (evidence_id ~ %L)',
           '^ev_[a-z][a-z0-9_]{1,24}_[0-9a-f]{12}$'),
    format('alter table public.scan_evidence_items add constraint scan_evidence_items_kind_shape check (kind ~ %L)',
           '^[a-z][a-z0-9_]{1,24}$'),
    -- evidence.py memotong fact ke 300 karakter, save_evidence_items() ke 500. Batas database ini
    -- penjaga terakhir yang lebih longgar dari keduanya, bukan pemotong.
    'alter table public.scan_evidence_items add constraint scan_evidence_items_fact_length check (char_length(fact) <= 500)',
    'alter table public.scan_evidence_items add constraint scan_evidence_items_scan_fkey foreign key (scan_id) references public.scans (id) on delete cascade',
    'alter table public.scan_evidence_items add constraint scan_evidence_items_user_fkey foreign key (user_id) references auth.users (id) on delete cascade',
    'alter table public.scan_evidence add constraint scan_evidence_scan_fkey foreign key (scan_id) references public.scans (id) on delete cascade',
    'alter table public.scan_evidence add constraint scan_evidence_user_fkey foreign key (user_id) references auth.users (id) on delete cascade'
  ];
begin
  foreach v_stmt in array v_stmts loop
    begin
      execute v_stmt;
    exception when duplicate_object then null;
    end;
  end loop;
end $constraints$;

-- functions.set_updated_at() sudah ada dari 202610300001_initial_schema.sql.
drop trigger if exists scan_evidence_set_updated_at on public.scan_evidence;
create trigger scan_evidence_set_updated_at before update on public.scan_evidence
  for each row execute function public.set_updated_at();

alter table public.scan_evidence_items enable row level security;
alter table public.scan_evidence enable row level security;

-- Sengaja tanpa policy dan tanpa FORCE: sama alasannya dengan 0007 — service_role bypass RLS,
-- sementara anon/authenticated dikunci dua lapis (RLS aktif tanpa policy + grant dicabut).
revoke all on public.scan_evidence_items from anon, authenticated;
revoke all on public.scan_evidence from anon, authenticated;
grant select, insert, update, delete on public.scan_evidence_items to service_role;
grant select, insert, update, delete on public.scan_evidence to service_role;

comment on table public.scan_evidence_items is
  'Bukti ternormalisasi per scan (EvidenceStore); ditulis analysis-service, dibaca hanya oleh service_role.';
comment on column public.scan_evidence_items.evidence_id is
  'Content-addressed dalam satu scan: ev_<kind>_<sha256[:12]>. Findings menunjuk ke sini, bukan ke id uuid.';
comment on column public.scan_evidence_items.payload is
  'Sudah diredaksi evidence.py (authorization/token/secret/cookie dibuang, string <= 4000). Tidak pernah memuat bytes APK.';
comment on column public.scan_evidence_items.expires_at is
  'Dipakai retention.py untuk purge; default 7 hari mengikuti FILE_RETENTION_DAYS.';
comment on table public.scan_evidence is
  'Snapshot satu baris per scan (threat_intel, recon_data, browser_data); upsert lewat on_conflict=scan_id.';

-- Setelah Run, pastikan keduanya cocok dengan yang dibutuhkan kode (expect 11 dan 2):
--
--   select table_name, count(*) as columns
--     from information_schema.columns
--    where table_name in ('scan_evidence_items','scan_evidence')
--    group by table_name order by table_name;
--
--   select indexname from pg_indexes
--     where indexname in ('scan_evidence_items_scan_evidence_key','scan_evidence_scan_key');
