# Personal Health Tracker

Native SwiftUI iPhone app source for the minimal PRD. It has Today, Add Meal, History, and Settings; HealthKit reads; app-entered weight and fat-free (lean) mass; and a protected meal-photo log. Today and History show estimated kcal and protein per meal and day, with partial totals labeled.

Email sign-in, HealthKit anchored-query uploads, meal-image uploads, and Supabase-to-iPhone meal/estimate downloads are implemented. Cloud-authored text-only meals are supported. Maintenance intake uses Cunningham from valid fat-free mass, falling back to Mifflin-St Jeor from weight, height, age, and sex; both use a mostly seated-day 1.2 factor. The protein reference is for regular resistance training during a calorie deficit. These are estimates, not measured burn or medical targets. The app shows separate Health refresh, upload, and meal-pull status.

The schema in `supabase/sql/initial_health_schema.sql` is an audit copy of the initial 2026-09-27 migration, not a pending migration; do not replay it over live data. The live schema subsequently gained `meal_estimates` and nullable `meals.image_path`. After a private row backup, `supabase/sql/20260927_meal_estimate_unique.sql` was applied and verified: one estimate per `(user_id,meal_id)`, with 3 meals, 3 estimates, and zero duplicate keys. The backup lives outside this repository.

## Open in Xcode

This checkout uses `project.yml` for XcodeGen. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and set the Supabase URL and **publishable** key, never a service-role key. Local config and the generated Xcode project are gitignored. Run `xcodegen generate`, open `PersonalHealthTracker.xcodeproj`, and run on a physical iPhone. The project uses the owner's Personal Team and bundle ID `com.personal.healthtracker.ursehfspdrzpuytymbrn`, targets iOS 17+, and pins Supabase Swift 2.55.2.

The checked-in entitlement requests HealthKit read access and background delivery. Foreground catch-up runs on app open and manual sync; hourly background delivery and app refresh are best-effort and still need observation on the real device. An unsigned iOS Simulator build skips HealthKit but can test the UI and authenticated cloud meals/History. Email confirmation and the optional existing-account sign-in link request the allowlisted `healthtracker://auth-callback` redirect. A sign-in link must be opened on the same Simulator/iPhone that requested it, and can only be used once.

## Current checks

- Run `swiftc HealthTracker/MaintenanceEnergy.swift Tests/FormulaChecks.swift -o /tmp/healthtracker-formula-checks && /tmp/healthtracker-formula-checks` to check both formula paths and fallback behavior.
- Ask for Health access in Settings, then refresh Today. Missing or denied data appears as a dash.
- Log a real weight in Today. It should remain after relaunch and sync as `app_weight`; HealthKit `bodyMass` must not appear as the app's weight.
- Log fat-free mass in Today. It should sync as `app_lean_mass` and drive the Cunningham maintenance estimate and protein reference. Height and demographic overrides remain in Settings.
- Create the single app account in Settings, confirm its email, then sign in.
- Add a meal with the camera or photo library; it should appear under today's meals after saving and after relaunching the app.
- A meal and estimate created in Supabase should appear in Today and History after Refresh Meals, without waiting for HealthKit upload. Check estimated kcal/protein totals, partial-protein labeling, text-only meals, and that rapid History date changes do not show `CancellationError`.
- Repeat Sync Now and check that `health_samples`, `workouts`, and `meals` do not gain duplicates. Interrupt connectivity and retry to check recovery.
- Confirm private meal images and rows cannot be read without that user's session.

As of 2026-09-27, an earlier build launched on the owner's iOS 26.6.1 iPhone using the Personal Team and cached 3 cloud-authored meals and 3 matched provisional estimates (2,026 kcal). A workout duration constraint error was observed; after deterministic normalization, the live database showed 222 workouts and 3,248 sleep samples. A complete HealthKit backfill and repeat-sync idempotency are **not** yet verified. Current source builds and launches on iOS 18.6 Simulator; owner-account cloud UI verification still requires signing in there. Two one-time email links returned invalid/expired after opening, and further sends hit the project's email rate limit; no owner session was taken from another device. This Mac remains on macOS 15.3.2. A scoped Codex meal writer and energy-gap estimator remain pending.
