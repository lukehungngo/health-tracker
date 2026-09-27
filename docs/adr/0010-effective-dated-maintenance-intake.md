# ADR 0010: Effective-dated maintenance intake

Status: implemented.

AI/manual `app_maintenance_energy` rows are a daily target history, not a single mutable current setting and not calories eaten in meal logs. For a selected local date, the app uses the newest row recorded before the end of that date. If that date has no new row, the preceding value carries forward. A new row on 15 September therefore leaves 10–14 September at the prior value; it applies from 15 September onward. Before the first row, History shows no entered target rather than retroactively applying today's formula.

The app creates a new UUID for a newly effective recommendation. Codex/AI must insert a new row for a new effective date and reuse an existing `external_id` only when correcting that historical record or retrying the same write. This preserves both the historical timeline and idempotency. Today's formula remains a fallback only if no entered target is currently effective.

Calendar's `Intake` remains calories estimated from logged meals, not this target. History shows the effective maintenance target, its source, and the date it came from.
