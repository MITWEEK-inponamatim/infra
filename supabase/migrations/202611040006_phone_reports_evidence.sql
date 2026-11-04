-- Community phone reports: the proof image becomes mandatory.
-- Additive only; safe to apply on a database that already ran 202610300001, 0004 and 0005.
--
-- evidence_url is what the community sees (a Cloudinary delivery link). evidence_public_id is
-- the handle the analysis service uses to delete that asset again, so cleanup never has to
-- guess it. Neither value is a secret; the reporter's own id is not part of either.
--
--   * Reports accepted before this rule keep NULL: they are still legitimate community data.
--   * Until this file has been run, POST /api/v1/phone-reports answers 503 and stores nothing,
--     because a report whose evidence column is missing cannot be saved at all.
--   * The URL shape check is not decoration: an attacker-controlled or hand-edited row must not
--     be able to point every reader of a number at an arbitrary host.

alter table public.phone_reports add column if not exists evidence_url text;
alter table public.phone_reports add column if not exists evidence_public_id text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'phone_reports_evidence_url_shape') then
    alter table public.phone_reports
      add constraint phone_reports_evidence_url_shape
      check (evidence_url is null
        or (evidence_url ~ '^https://res\.cloudinary\.com/' and char_length(evidence_url) <= 2048));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'phone_reports_evidence_public_id_shape') then
    alter table public.phone_reports
      add constraint phone_reports_evidence_public_id_shape
      check (evidence_public_id is null
        or (evidence_public_id like 'threatlens/phone-reports/%' and char_length(evidence_public_id) <= 512));
  end if;

  -- Both halves of the reference arrive together, or neither: a URL nobody can delete would make
  -- "admin removes a review" impossible, and a bare public id could not be shown.
  if not exists (select 1 from pg_constraint where conname = 'phone_reports_evidence_pair') then
    alter table public.phone_reports
      add constraint phone_reports_evidence_pair
      check ((evidence_url is null) = (evidence_public_id is null));
  end if;
end
$$;

comment on column public.phone_reports.evidence_url is
  'Cloudinary delivery link for the reporter''s proof image; NULL only on reports predating the mandatory rule.';
comment on column public.phone_reports.evidence_public_id is
  'Cloudinary public id, used to delete the proof image when its report is removed.';
