# ADR 0014: Waist circumference as an app-entered body value

## Decision

Show an editable waist-circumference card in centimeters immediately above
fat-free mass on Today. Save each entry locally with a stable UUID, measured
time, source, and pending-upload state. Sync it bidirectionally through Neon
`public.health_samples` using `type = 'app_waist_circumference'`, `unit = 'cm'`,
and the existing `(user_id, external_id)` idempotent upsert key.

The current Neon table accepts new nonempty type and unit values, so this
requires no schema migration. Keep this manual/app value distinct from Apple
Health samples and do not use it in the existing calorie or protein formulas.

## Verification

Check local save/relaunch, input validation, pending-upload recovery, repeated
cloud merge, and the iOS Simulator build/tests. Real-device installation and
an authenticated Neon round trip are separate checks.
