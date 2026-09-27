# ADR 0008: Hourly burn and daily intake/burn calendar

Status: implemented, Simulator and live-RPC verification in progress.

The app reads owner-scoped hourly basal and active energy aggregates from a bounded Supabase `security invoker` RPC. The function splits HealthKit sample values across clock-hour boundaries in proportion to overlap, without changing the source records. RLS and an explicit `auth.uid()` filter remain in force; anonymous callers cannot execute the function. A calendar month requires at most one aggregate request rather than downloading tens of thousands of raw samples.

For each local hour with any energy sample, the app uses recorded basal plus active energy. For a completely uncovered hour, it estimates `weight kg × elapsed hours × MET`: 1.0 for the assumed 00:00–07:00 sleep window (or a recorded asleep interval) and 1.3 otherwise for seated office work. These are assumptions, not inferred sleep or measured activity. If no app-entered weight exists, the gap remains unknown. Today stops at the current time. Every cloud refresh recomputes the total, so late samples replace estimates without duplicate or synthetic HealthKit rows. The app displays recorded and estimated components separately.

The Calendar tab presents each day's estimated meal intake and daily burned total. Intake is explicitly partial if a meal lacks an estimate. Tapping a date selects that date in History. The app continues to rely on iOS best-effort background delivery; it does not promise an exact hourly background upload.

Calendar marks a complete logged intake below burned as green/`−` deficit and above burned as red/`+` surplus. Equal totals and incomplete or absent meal/energy data stay neutral, so missing food logs are never shown as a confirmed deficit. The labels accompany color for accessibility.

Consequences: an active-only recorded hour does not invent basal energy, so a day can be low if HealthKit provided only partial channels. A historical day before the first app weight uses that earliest weight as an approximation. Server aggregation is bounded to 32 days per request and returns no data for an unauthenticated or non-owner caller.
