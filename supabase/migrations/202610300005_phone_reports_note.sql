-- Community phone reports: optional moderation note.
-- Additive only; safe to apply on a database that already ran 0001 (and 0004).
--
-- The note is moderation context, not public evidence:
--   * it is never returned to other users and never sent to an LLM;
--   * it is capped at 280 characters (the API enforces the same limit);
--   * the app works without this column; a report simply reports note_saved = false.

alter table public.phone_reports add column if not exists note text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'phone_reports_note_length'
  ) then
    alter table public.phone_reports
      add constraint phone_reports_note_length
      check (note is null or char_length(note) <= 280);
  end if;
end
$$;

-- Moderation queue: pending reports ordered by age.
create index if not exists phone_reports_pending_idx
  on public.phone_reports (status, created_at)
  where status = 'pending';
