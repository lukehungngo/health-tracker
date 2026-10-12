# ADR 0015: Optional AI backfill for hourly energy

## Decision

ChatGPT may upsert one `public.energy_backfills` row per owner and UTC hour.
`active_kcal` and `total_burn_kcal` are optional independent estimates in kcal
for that full hour; at least one is required. The owner/hour primary key makes
retries idempotent. The iPhone receives owner-only SELECT under Neon Data API
RLS, with no write privileges to this table. It never uploads or overwrites AI
backfills. Apple Health samples remain separate. ChatGPT writes through an
authorized direct database connection.

For each hour, recorded HealthKit basal and active energy take precedence.
AI active energy fills only hours without recorded active samples. AI total burn
fills when HealthKit lacks a complete basal-plus-active reading; the app never
adds a whole-hour AI total to a whole-hour HealthKit total. If no AI total is
available, the existing weight/sleep/seated-day model remains the fallback.
An active-only AI entry can supplement recorded basal energy; if basal energy
is also absent, the app adds a weight-based basal estimate where available and
marks the hour partial otherwise. Current-hour AI values are prorated to elapsed
time. Today and History label AI contributions separately from measured and
modeled energy. Calendar and net-calorie views use the same daily total.

No manual entry UI or automated AI inference is added. ChatGPT writes via its
authorized Neon connection and the app refreshes read-only values from Neon.

## Verification

Unit tests cover AI replacing a modeled gap, complete HealthKit precedence,
active-only supplementation, and current-hour prorating. Validate the migration,
owner RLS, primary-key upsert, and constraints on a Neon branch before applying
to production. Simulator tests do not prove authenticated Data API or physical
device behavior; check both separately.
