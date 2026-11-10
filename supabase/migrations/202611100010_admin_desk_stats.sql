-- Dasbor meja moderasi: satu fungsi yang menjawab seluruh halaman dengan satu panggilan.
--
-- Dua alasan fungsi ini ada di Postgres, bukan di Go:
--   1. PostgREST tidak bisa mengelompokkan waktu lewat query string — tidak ada date_trunc di
--      sisi REST, jadi deret berturunya harus dihitung di database.
--   2. Menarik baris mentah lalu menjumlahnya di Go bukan pilihan: helper supabase() memotong
--      jawaban pada 1 MiB, jadi angkanya bisa diam-diam kurang tanpa siapa pun tahu.
-- Karena itu seluruh perhitungan terjadi di sini dan keluar sebagai satu jsonb.
--
-- Empat rentang yang bisa dipilih, masing-masing sejumlah bucket yang UTUH:
--   7 hari   -> 7 bucket harian        1 bulan -> 30 bucket harian
--   3 bulan  -> 13 bucket mingguan     1 tahun -> 12 bucket bulanan
-- Periode pembanding selalu rentang yang sama digeser satu langkah ke belakang, dan karena
-- panjangnya kelipatan bucket, tiap kejadian di periode lama jatuh tepat di slot yang sama.
--
-- Semua waktu dipotong dalam UTC supaya bucket tidak bergeser saat zona waktu server berubah.

create or replace function public.admin_desk_stats(p_range text)
returns jsonb
language sql
stable
set search_path = public
set timezone = 'utc'
as $$
with sel as (
  select case p_range
           when '7d' then '7d'
           when '90d' then '90d'
           when '12m' then '12m'
           else '30d'
         end as id
),
prm as (
  select id, unit, slots, step, step * slots as span
    from (
      select id,
             case id when '7d' then 'day' when '90d' then 'week' when '12m' then 'month' else 'day' end as unit,
             case id when '7d' then 7 when '90d' then 13 when '12m' then 12 else 30 end as slots,
             case id
               when '7d' then interval '1 day'
               when '90d' then interval '7 days'
               when '12m' then interval '1 month'
               else interval '1 day'
             end as step
        from sel
    ) shaped
),
box as (
  -- Bucket terakhir adalah bucket yang memuat sekarang, jadi jendela berjalan mundur dari situ:
  -- rentang "7 hari" berarti tujuh bucket hari yang terakhirnya hari ini, bukan tujuh hari ke depan.
  select id, unit, slots, step, span,
         here - step * (slots - 1) as cur_start,
         here + step as cur_end,
         here - step * (2 * slots - 1) as prev_start
    from prm
    cross join lateral (select date_trunc(unit, now() at time zone 'utc') as here) anchor
),
grid as (
  select g,
         box.cur_start + box.step * g as b_start,
         box.cur_start + box.step * (g + 1) as b_end
    from box
    cross join lateral generate_series(0, box.slots - 1) as g
),

-- Satu baris per bucket untuk tiap sumber, dihitung dengan group by (baca sekali, bukan
-- sekali per bucket), lalu digeser satu span ke depan agar periode lama jatuh di slot yang sama.
now_accounts as (
  select date_trunc(b.unit, p.created_at at time zone 'utc') as k, count(*) as n
    from profiles p cross join box b
   where p.created_at >= b.cur_start and p.created_at < b.cur_end
   group by 1
),
old_accounts as (
  select date_trunc(b.unit, (p.created_at at time zone 'utc') + b.span) as k, count(*) as n
    from profiles p cross join box b
   where p.created_at >= b.prev_start and p.created_at < b.cur_start
   group by 1
),
now_posts as (
  select date_trunc(b.unit, c.created_at at time zone 'utc') as k, count(*) as n
    from community_posts c cross join box b
   where c.status = 'active' and c.created_at >= b.cur_start and c.created_at < b.cur_end
   group by 1
),
old_posts as (
  select date_trunc(b.unit, (c.created_at at time zone 'utc') + b.span) as k, count(*) as n
    from community_posts c cross join box b
   where c.status = 'active' and c.created_at >= b.prev_start and c.created_at < b.cur_start
   group by 1
),
now_reports as (
  select date_trunc(b.unit, r.created_at at time zone 'utc') as k,
         count(*) as n, count(distinct r.number_e164) as numbers
    from phone_reports r cross join box b
   where r.created_at >= b.cur_start and r.created_at < b.cur_end
   group by 1
),
old_reports as (
  select date_trunc(b.unit, (r.created_at at time zone 'utc') + b.span) as k,
         count(*) as n, count(distinct r.number_e164) as numbers
    from phone_reports r cross join box b
   where r.created_at >= b.prev_start and r.created_at < b.cur_start
   group by 1
),
series_accounts as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', to_char(g.b_start, 'YYYY-MM-DD'),
           'current', coalesce(a.n, 0),
           'previous', coalesce(b.n, 0)) order by g.g), '[]'::jsonb) as arr
    from grid g
    left join now_accounts a on a.k = g.b_start
    left join old_accounts b on b.k = g.b_start
),
series_posts as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', to_char(g.b_start, 'YYYY-MM-DD'),
           'current', coalesce(a.n, 0),
           'previous', coalesce(b.n, 0)) order by g.g), '[]'::jsonb) as arr
    from grid g
    left join now_posts a on a.k = g.b_start
    left join old_posts b on b.k = g.b_start
),
series_reports as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', to_char(g.b_start, 'YYYY-MM-DD'),
           'current', coalesce(a.n, 0),
           'previous', coalesce(b.n, 0)) order by g.g), '[]'::jsonb) as arr
    from grid g
    left join now_reports a on a.k = g.b_start
    left join old_reports b on b.k = g.b_start
),
-- Nomor dihitung sekali per bucket. Totalnya bukan jumlah bucket: nomor yang sama yang dilaporkan
-- lagi di hari berbeda tetap satu nomor dalam satu rentang, jadi angkanya diambil sendiri.
series_numbers as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'bucket', to_char(g.b_start, 'YYYY-MM-DD'),
           'current', coalesce(a.numbers, 0),
           'previous', coalesce(b.numbers, 0)) order by g.g), '[]'::jsonb) as arr
    from grid g
    left join now_reports a on a.k = g.b_start
    left join old_reports b on b.k = g.b_start
),

totals as (
  select
    coalesce((select sum(n) from now_accounts), 0) as accounts_now,
    coalesce((select sum(n) from old_accounts), 0) as accounts_old,
    coalesce((select sum(n) from now_posts), 0) as posts_now,
    coalesce((select sum(n) from old_posts), 0) as posts_old,
    coalesce((select sum(n) from now_reports), 0) as reports_now,
    coalesce((select sum(n) from old_reports), 0) as reports_old,
    coalesce((select count(distinct r.number_e164) from phone_reports r cross join box b
               where r.created_at >= b.cur_start and r.created_at < b.cur_end), 0) as numbers_now,
    coalesce((select count(distinct r.number_e164) from phone_reports r cross join box b
               where r.created_at >= b.prev_start and r.created_at < b.cur_start), 0) as numbers_old
),
categories as (
  select coalesce(jsonb_agg(jsonb_build_object('label', c.label, 'value', c.n) order by c.n desc),
                  '[]'::jsonb) as arr
    from (
      select r.category as label, count(*) as n
        from phone_reports r cross join box b
       where r.created_at >= b.cur_start and r.created_at < b.cur_end
       group by r.category
    ) c
),
-- Antrean bukan hal yang bergantung rentang: baris yang menunggu keputusan hari ini menunggu
-- hari ini juga, entah laporan itu masuk minggu lalu atau bulan lalu.
statuses as (
  select count(*) filter (where status = 'pending') as pending,
         count(*) filter (where status = 'verified') as verified,
         count(*) filter (where status = 'rejected') as rejected,
         count(*) filter (where status = 'rejected_spam') as rejected_spam,
         count(*) as all_reports
    from phone_reports
),
dangerous as (
  select count(*) as n from dangerous_numbers
),
-- Pratinjau tabel: laporan terbaru dalam rentang, dibatasi 60 baris. Yang ditampilkan di layar
-- hanyalah pratinjau; jumlahnya yang sebenarnya diambil dari laporan_total.
recent as (
  select coalesce(jsonb_agg(row_to_json(t) order by t.created_at desc), '[]'::jsonb) as arr
    from (
      select r.id::text as id, r.number_e164, r.category, r.status,
             coalesce(r.reported_by::text, '') as reported_by,
             coalesce(r.evidence_url, '') as evidence_url,
             r.created_at
        from phone_reports r cross join box b
       where r.created_at >= b.cur_start and r.created_at < b.cur_end
       order by r.created_at desc
       limit 60
    ) t
)
select jsonb_build_object(
  'range', box.id,
  'bucket', box.unit,
  'totals', jsonb_build_object(
    'accounts', jsonb_build_object('current', totals.accounts_now, 'previous', totals.accounts_old),
    'reports',  jsonb_build_object('current', totals.reports_now,  'previous', totals.reports_old),
    'posts',    jsonb_build_object('current', totals.posts_now,    'previous', totals.posts_old),
    'numbers',  jsonb_build_object('current', totals.numbers_now,  'previous', totals.numbers_old)),
  'series', jsonb_build_object(
    'accounts', series_accounts.arr,
    'reports',  series_reports.arr,
    'posts',    series_posts.arr,
    'numbers',  series_numbers.arr),
  'categories', categories.arr,
  'statuses', jsonb_build_object(
    'pending', statuses.pending,
    'verified', statuses.verified,
    'rejected', statuses.rejected,
    'rejected_spam', statuses.rejected_spam),
  'queue_total', statuses.all_reports,
  'report_total', totals.reports_now,
  'dangerous', dangerous.n,
  'recent', recent.arr
)
from box
cross join totals
cross join categories
cross join statuses
cross join dangerous
cross join recent
cross join series_accounts
cross join series_posts
cross join series_reports
cross join series_numbers;
$$;

comment on function public.admin_desk_stats(text) is
  'Ringkasan dasbor moderasi untuk satu rentang (7d/30d/90d/12m): total + periode pembanding, deret per bucket, kategori, antrean, nomor berbahaya, dan 60 laporan terbaru.';

-- Hanya service_role yang boleh memanggil: anon dan authenticated tidak pernah melihat angka
-- internal antrean.
revoke execute on function public.admin_desk_stats(text) from public, anon, authenticated;
grant execute on function public.admin_desk_stats(text) to service_role;
