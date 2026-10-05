# Personal Health Tracker

## Neon migration (2026-10-02)

The app uses Neon Auth, Neon Data API, and a private Neon meal-image bucket. It has no Supabase runtime connection or Swift package dependency. The 12-month Supabase backup and Neon import are recorded in [ADR 0011](docs/adr/0011-neon-cutover.md); the historical SQL and optional archival export script remain for audit/recovery, outside the app build. The existing bundle ID is retained so an installed app can be updated in place. Sign in with the Neon account after installing a Neon build.

Native SwiftUI iPhone app source for the minimal PRD. It has Today, Add Meal, Calendar, History, and Settings; HealthKit reads; app-entered weight and fat-free (lean) mass; and a protected meal log with optional photo. Today and History show estimated kcal and protein per meal and day, with partial totals labeled. Add Meal accepts text, photo, or both. Tapping a meal opens its full detail and permits editing the note and optional kcal/protein/carbs/fat; edits save locally before an independent Neon meal refresh.

Email sign-in, HealthKit anchored-query uploads, meal-image uploads, and Neon-to-iPhone meal/estimate downloads are implemented. Cloud-authored text-only meals are supported. Weight, fat-free mass, AI/manual basal and maintenance estimates, and an AI/manual protein target pull their latest values from Neon; AI-authored values carry an AI badge. Maintenance intake uses Cunningham from valid fat-free mass, falling back to Mifflin-St Jeor from weight, height, age, and the profile's gender-for-formula coefficient; both use a mostly seated-day 1.2 factor. The protein formula for regular resistance training is only a fallback until a manual or AI target is recorded. These are estimates, not measured burn or medical targets. The Today screen has compact sync controls; Settings retains separate Health, meal, and body-value status.

`Maintenance intake` is an effective-dated daily target: a value entered on the 10th carries through the 14th if there is no change, while a new value on the 15th applies from the 15th onward. History shows the value and source effective on its selected date. Create a new `app_maintenance_energy` row and new `external_id` for a new effective date; reuse that ID only for retry or correction. Calendar's `Intake` is instead the sum of food logs for that day, never this target.

Today and Calendar show hourly total burned: synced basal plus active energy where present, otherwise a separately labeled estimate using the app-entered weight. The assumed sleep window is 00:00–07:00 local time at 1.0 MET; uncovered waking hours use 1.3 MET for seated work. Today stops at the present time. A new HealthKit sample replaces its hour's estimate on refresh; no synthetic samples are uploaded. Calendar marks days without meal logs as unknown intake (`—`), green/`−` when complete logged intake is below burned, and red/`+` when above; incomplete days stay neutral. Tapping a date opens that day in History. The hourly database RPC is bounded to 32 days, uses invoker rights, and is unavailable to anonymous callers. Background delivery remains iOS best-effort, not a guaranteed hourly schedule.

Today also shows rolling 7- and 30-day net kcal (logged intake minus burned). Each card states how many days have enough meal-kcal and burned-energy data; unlogged or incomplete days are excluded, not treated as zero intake. See `docs/adr/0012-rolling-net-calories.md`.

The files under `supabase/` are historical audit copies, not pending Neon migrations; do not replay them over live data. Current Neon schema changes live under `neon/migrations/`. The private migration backup lives outside this repository.

For a Codex/ChatGPT recommendation, upsert Neon `public.protein_targets` with a stable `id` (reuse it on retries or corrections), the account `user_id`, `recorded_at`, `min_g`, `max_g`, and `source = 'ChatGPT'`. The range must be 20–400 g/day with `min_g <= max_g`; the app syncs the latest record and displays the AI badge. Do not put credentials or an admin key in the app or repository.

## Open in Xcode

This checkout uses `project.yml` for XcodeGen. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`; it contains public Neon endpoints, never an admin or database credential. Local config and the generated Xcode project are gitignored. Run `xcodegen generate`, open `PersonalHealthTracker.xcodeproj`, and run on a physical iPhone. The project uses the owner's Personal Team, retains its existing bundle ID, targets iOS 17+, and calls Neon Data API directly via `URLSession`.

The checked-in entitlement requests HealthKit read access and background delivery. Foreground catch-up runs on app open and manual sync; hourly background delivery and app refresh are best-effort and still need observation on the real device. The iOS Simulator build skips HealthKit. Neon uses password sign-in; old Supabase magic links and sessions do not transfer. Sign in once after installing the new build. For authenticated cloud QA, use Xcode's default ad-hoc signing so the Keychain session persists.

## Current checks

- Run `swiftc HealthTracker/MaintenanceEnergy.swift Tests/FormulaChecks.swift -o /tmp/healthtracker-formula-checks && /tmp/healthtracker-formula-checks` to check both formula paths and fallback behavior.
- Ask for Health access in Settings, then refresh Today. Missing or denied data appears as a dash.
- Log a real weight in Today. It should remain after relaunch and sync as `app_weight`; HealthKit `bodyMass` must not appear as the app's weight.
- Log fat-free mass in Today. It should sync as `app_lean_mass` and drive the Cunningham maintenance estimate and protein reference. Height and demographic overrides remain in Settings.
- Log a protein target range or have Codex write one to `protein_targets`; refresh Today and verify the latest range, source badge, and timestamp survive relaunch and repeated sync.
- Compare a Calendar day with recorded energy, a day with no watch data, and a partial current day. Tap a date and verify History opens the same date with recorded and estimated burn separated.
- Create the single app account in Settings, confirm its email, then sign in.
- Add a text-only meal, a photo-only meal, and a combined meal; each should appear under Today and survive relaunch. The note keyboard has a Done action. Tap each log in Today and History to see its full contents; edit the note and nutrition values, then confirm the stable record appears after refresh without duplicates.
- A meal and estimate created in Neon should appear in Today and History after Refresh Meals, without waiting for HealthKit upload. Check estimated kcal/protein totals, partial-protein labeling, text-only meals, and that rapid History date changes do not show `CancellationError`.
- Repeat Sync Now and check that `health_samples`, `workouts`, and `meals` do not gain duplicates. Interrupt connectivity and retry to check recovery.
- Confirm private meal images and rows cannot be read without that user's session.

As of 2026-09-27, an earlier build launched on the owner's iOS 26.6.1 iPhone using the Personal Team. A workout duration constraint error was observed; after deterministic normalization, the live database contained workout and sleep history. A complete HealthKit backfill and repeat-device-sync idempotency are **not** yet verified. Current source builds and launches on iOS 18.6 Simulator; unit tests cover cloud merge idempotency and hourly burn gaps. The owner's authenticated Simulator pulled existing meals, estimates, manual weight, and hourly energy; Calendar rendered September totals. Email-link sign-in remains unverified; password sign-in worked. This Mac remains on macOS 15.3.2. A scoped Codex meal writer remains pending.

On 2026-09-28, the text/photo meal, full-detail editor, and pending-edit retry changes passed 20 Simulator tests. A real-device keyboard check has not yet been exercised for this change.
