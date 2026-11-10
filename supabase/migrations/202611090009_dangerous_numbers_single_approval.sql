-- Satu persetujuan moderator sudah cukup untuk membuat nomor masuk daftar "Nomor berbahaya".
--
-- Sebelumnya view ini menuntut dua laporan terverifikasi dari dua akun berbeda. Konsekuensinya
-- tidak masuk akal bagi warga: moderator sudah menyatakan satu laporan itu benar, tapi nomornya
-- tetap tidak muncul di board sampai ada orang kedua yang lapor. Keputusan manusia itu sendiri
-- yang jadi sinyal, bukan jumlah orang yang sepakat dengannya.
--
-- Ambangnya harus SAMA dengan aturan "high" di analysis-service/app/phone_scanner.py::_report_finding.
-- Kalau bagian ini diubah, ubah yang di Python juga.

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
 where v.verified_reports >= 1;

comment on view public.dangerous_numbers is
  'Nomor dengan >=1 laporan terverifikasi: persetujuan moderator yang memasukkannya, bukan jumlah pelapor. Ambang yang sama dengan _report_finding di Python.';
