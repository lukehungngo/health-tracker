# ADR 0001: Private Supabase sync for the personal tracker

Status: schema applied to P Health on 2026-09-27; iPhone runtime verification pending.

The tracker stores health samples and meal photos in a named Supabase project so one user can later ask a Codex skill for daily analysis. The iPhone app uses only the publishable key and a user session. Its tables carry `user_id`, enforce owner-only Row Level Security, and have unique HealthKit IDs for retry-safe upserts. Meal images use a private bucket with paths under the authenticated user ID. The app persists each HealthKit anchor only after the corresponding cloud writes succeed; app-open and manual sync provide catch-up.

This keeps a custom backend out of the MVP. The project currently permits email signup because it has no app user yet; after the intended user confirms an account, signup can be disabled for the single-user deployment. A separately revocable read-only identity for the future Codex skill remains a later security decision. Background observer delivery and real-device behavior remain unverified. The schema was executed in the Supabase dashboard, so no Supabase CLI migration ledger entry was created; its local SQL file is an audit copy.

Email confirmation uses the exact `healthtracker://auth-callback` deep link. The app accepts only that scheme and host for the auth callback; the exact URL was added to the Supabase Auth redirect allowlist on 2026-09-27. App sign-up explicitly requests it, overriding the project's unchanged `http://localhost:3000` default Site URL without a broad wildcard redirect.
