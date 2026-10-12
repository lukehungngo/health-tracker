-- Optional ChatGPT estimates for UTC hours without complete HealthKit energy.
-- One owner/hour is the idempotency key; never rewrite measured health_samples.
begin;

create table if not exists public.energy_backfills (
  user_id uuid not null references neon_auth."user"(id) on delete cascade,
  hour_at timestamptz not null,
  active_kcal double precision,
  total_burn_kcal double precision,
  source text not null default 'AI' check (source = 'AI'),
  updated_at timestamptz not null default now(),
  primary key (user_id, hour_at),
  constraint energy_backfill_utc_hour check (
    isfinite(hour_at) and mod(extract(epoch from hour_at), 3600) = 0
  ),
  constraint energy_backfill_present check (
    active_kcal is not null or total_burn_kcal is not null
  ),
  constraint energy_backfill_active_range check (
    active_kcal is null or (active_kcal >= 0 and active_kcal < 'Infinity'::double precision)
  ),
  constraint energy_backfill_total_range check (
    total_burn_kcal is null or (total_burn_kcal >= 0 and total_burn_kcal < 'Infinity'::double precision)
  ),
  constraint energy_backfill_consistency check (
    active_kcal is null or total_burn_kcal is null or total_burn_kcal >= active_kcal
  )
);

alter table public.energy_backfills enable row level security;
drop policy if exists tracker_owner on public.energy_backfills;
create policy tracker_owner on public.energy_backfills for select to authenticated
  using ((select auth.user_id())::uuid = user_id);

revoke insert, update, delete on public.energy_backfills from authenticated;
grant select on public.energy_backfills to authenticated;
revoke all on public.energy_backfills from anonymous;

commit;
