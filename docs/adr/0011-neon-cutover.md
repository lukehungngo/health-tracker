# ADR 0011: Move the single-user tracker to Neon

Status: implemented in source and Neon production; real-device install pending.
Date: 2026-10-02.

## Decision

Copy the last 12 calendar months of dated Supabase health, workout, meal,
protein-target, and summary data to the production branch of Neon project
`shiny-bird-57102187`. Preserve source record IDs and HealthKit external IDs,
but replace the Supabase Auth user ID with the corresponding Neon Auth user ID.
Keep a private, checksummed JSONL source backup outside the repository and
leave Supabase untouched for rollback. Use a fixed export cutoff of
`2025-10-02T13:54:25Z` for the migration; the app's continuing HealthKit
backfill uses a rolling 12-month cutoff.

Use Neon Auth email/password, Neon Data API with
owner-only RLS for tables, and a private Neon Object Storage bucket. The app
holds only a Neon Auth session cookie in this device's Keychain and mints
short-lived JWTs for Data API and image requests. A Neon Function verifies
each JWT and supplies short-lived signed object URLs constrained to that
user's image path. No Postgres, S3, or admin credential ships in the app.

The read-only hourly aggregate is a narrow SECURITY DEFINER wrapper because
Neon owns the `auth` schema. The wrapper derives the owner solely from the
verified JWT; it accepts no user ID argument. Authenticated users have no
direct access to the private schema.

## Alternatives and consequences

Keeping Supabase would require continued provider availability. Direct
Postgres or S3 credentials on the iPhone would be unsafe. A custom API for
every table would add unnecessary code, so PostgREST/Data API preserves the
existing query semantics. Existing Supabase app sessions cannot be migrated;
the user signs in once using the new Neon account. Old installed builds still
write Supabase until replaced and must not be treated as cut over.

The old Supabase Swift package remains pinned only for its `PostgREST`
product. It no longer supplies auth or storage. This keeps the app change
small; a later dependency replacement is separate work.

The app's build configuration no longer contains the legacy Supabase URL or
publishable key, and its former `healthtracker` auth callback is removed.
The source publishable key is retained only in an ignored local archive file
for the read-only migration export script; that file is not an Xcode input.
When the signed-in app returns to the foreground, it refreshes cloud meals
and estimates independently of the longer HealthKit upload so AI-authored
entries can appear without restarting the app. This is best-effort on resume,
not a push notification or an exact background polling guarantee.

## Verification and rollback

Verify backup hashes/counts, production row counts and old-user-ID absence,
password sign-in/session/JWT, owner and anonymous RLS behavior, aggregate RPC,
private image upload/download on a disposable branch, and iOS Simulator
build/tests. Keep the original Supabase schema/data and private local
configuration for rollback until a real-device install and sync pass.
