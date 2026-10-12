# ChatGPT hourly energy backfill

Use the owner's authorized Neon connection. Do not put database credentials in
the app or this repository. Write to `public.energy_backfills`, not to
`health_samples` or `daily_summaries`.

- `user_id`: the owner's Neon Auth user UUID.
- `hour_at`: start of the UTC hour (`2026-10-10T10:00:00Z`); one row per hour.
- `active_kcal`: optional estimated *active* kcal for the full hour.
- `total_burn_kcal`: optional estimated *total* kcal for the full hour.
- `source`: always `AI` (default). At least one kcal field must be present,
  values must be finite and nonnegative, and total must be at least active
  when both are supplied.

Idempotent example (bind the owner UUID and values as parameters, rather than
copying credentials or hard-coding a user ID):

```sql
insert into public.energy_backfills
  (user_id, hour_at, active_kcal, total_burn_kcal)
values
  ($1::uuid, $2::timestamptz, $3::double precision, $4::double precision)
on conflict (user_id, hour_at) do update
set active_kcal = coalesce(excluded.active_kcal, public.energy_backfills.active_kcal),
    total_burn_kcal = coalesce(excluded.total_burn_kcal, public.energy_backfills.total_burn_kcal),
    updated_at = now();
```

Pass `NULL` for an unavailable estimate. Supplying one field preserves the
other field on an existing row. If changing the active estimate above an older
total estimate, update both together to satisfy the consistency check. Avoid
writing an AI estimate for an hour already fully measured by HealthKit; if one
arrives later, the app automatically prefers HealthKit. In the app, choose
**More sync options → Refresh burned energy** (or refresh History/Calendar) to
read new backfills. Automatic refresh happens on app foreground entry.
