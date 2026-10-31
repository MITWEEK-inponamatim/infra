-- Community phone reports: one report per user per number, and faster status lookups.
-- Additive only; safe to apply on a database that already ran 202610300001.
-- If the unique index fails, there are existing duplicates for (number_e164, reported_by):
--   delete them first, then re-run this file.

create unique index if not exists phone_reports_reporter_number_key
  on public.phone_reports (number_e164, reported_by)
  where reported_by is not null;

create index if not exists phone_reports_status_created_idx
  on public.phone_reports (number_e164, status, created_at desc);
