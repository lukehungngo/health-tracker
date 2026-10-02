-- Personal Health Tracker on Neon. Apply with a direct connection.
-- No client role receives direct table access; the authenticated Function API
-- scopes every request to the verified Neon Auth subject.
begin;

create schema if not exists private;

create table if not exists public.health_samples (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references neon_auth."user"(id) on delete cascade,
  external_id uuid not null,
  type text not null check (length(btrim(type)) > 0),
  start_at timestamptz not null,
  end_at timestamptz not null,
  value double precision not null check (value >= 0 and value < 'Infinity'::double precision),
  unit text not null check (length(btrim(unit)) > 0),
  source text,
  created_at timestamptz not null default now(),
  source_metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(source_metadata) = 'object'),
  constraint health_sample_interval check (end_at >= start_at and isfinite(start_at) and isfinite(end_at)),
  unique (user_id, external_id)
);
create index if not exists health_samples_user_start_idx on public.health_samples (user_id, start_at desc);
create index if not exists health_samples_user_end_idx on public.health_samples (user_id, end_at);
create index if not exists health_samples_user_type_start_idx on public.health_samples (user_id, type, start_at);

create table if not exists public.workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references neon_auth."user"(id) on delete cascade,
  healthkit_id uuid not null,
  type text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  duration_seconds double precision not null,
  active_energy_kcal double precision,
  avg_heart_rate double precision,
  max_heart_rate double precision,
  created_at timestamptz not null default now(),
  source_metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(source_metadata) = 'object'),
  constraint workout_interval check (end_at >= start_at and isfinite(start_at) and isfinite(end_at)),
  constraint workout_duration check (duration_seconds >= 0 and duration_seconds < 'Infinity'::double precision
    and duration_seconds <= extract(epoch from end_at - start_at)),
  unique (user_id, healthkit_id)
);
create index if not exists workouts_user_start_idx on public.workouts (user_id, start_at desc);

create table if not exists public.meals (
  id uuid primary key,
  user_id uuid not null references neon_auth."user"(id) on delete cascade,
  eaten_at timestamptz not null check (isfinite(eaten_at)),
  note text not null default '',
  image_path text,
  created_at timestamptz not null default now(),
  unique (user_id, id)
);
create index if not exists meals_user_eaten_idx on public.meals (user_id, eaten_at desc);

create table if not exists public.meal_estimates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references neon_auth."user"(id) on delete cascade,
  meal_id uuid not null,
  calories_kcal numeric check (calories_kcal >= 0),
  protein_g numeric check (protein_g >= 0),
  carbs_g numeric check (carbs_g >= 0),
  fat_g numeric check (fat_g >= 0),
  confidence numeric check (confidence between 0 and 1),
  estimation_metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(estimation_metadata) = 'object'),
  created_at timestamptz not null default now(),
  unique (user_id, meal_id),
  foreign key (user_id, meal_id) references public.meals(user_id, id) on delete restrict
);

create table if not exists public.protein_targets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references neon_auth."user"(id) on delete cascade,
  recorded_at timestamptz not null,
  min_g double precision not null,
  max_g double precision not null,
  source text not null,
  created_at timestamptz not null default now(),
  constraint protein_targets_range check (min_g >= 20 and max_g >= min_g and max_g <= 400)
);
create index if not exists protein_targets_user_recorded_idx on public.protein_targets (user_id, recorded_at desc);

create table if not exists public.daily_summaries (
  user_id uuid not null references neon_auth."user"(id) on delete cascade,
  date date not null,
  timezone text not null default 'Asia/Ho_Chi_Minh',
  weight_kg numeric,
  steps bigint,
  active_energy_kcal numeric,
  basal_energy_kcal numeric,
  sleep_minutes numeric,
  workout_minutes numeric,
  intake_kcal numeric,
  protein_g numeric,
  aggregation_metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, date, timezone)
);

create table if not exists private.tracker_access (
  singleton boolean primary key default true check (singleton),
  owner_id uuid not null references neon_auth."user"(id) on delete restrict,
  reader_id uuid references neon_auth."user"(id) on delete set null,
  check (reader_id is null or reader_id <> owner_id)
);

create table if not exists private.pending_food_logs (
  id uuid primary key default gen_random_uuid(),
  source_url text not null unique,
  log_date date not null,
  timezone text not null default 'Asia/Ho_Chi_Minh',
  meal_label text not null,
  food text not null,
  original_note text not null default '',
  original_estimate jsonb not null default '{}'::jsonb check (jsonb_typeof(original_estimate) = 'object'),
  imported_at timestamptz not null default now(),
  linked_meal_id uuid references public.meals(id) on delete restrict
);

alter table public.health_samples enable row level security;
alter table public.workouts enable row level security;
alter table public.meals enable row level security;
alter table public.meal_estimates enable row level security;
alter table public.protein_targets enable row level security;
alter table public.daily_summaries enable row level security;
alter table private.tracker_access enable row level security;
alter table private.pending_food_logs enable row level security;
revoke all on schema private from public;
revoke all on all tables in schema public from public;
revoke all on all tables in schema private from public;

-- Mirrors the iPhone's UTC-hour aggregation while taking the owner from
-- the Function's verified JWT, never from a client-controlled query parameter.
create or replace function private.tracker_hourly_energy(
  p_user_id uuid, p_from timestamptz, p_to timestamptz
)
returns table (
  hour_at timestamptz,
  basal_kcal double precision,
  active_kcal double precision,
  basal_samples bigint,
  active_samples bigint
)
language plpgsql stable security invoker
set search_path = ''
as $$
begin
  if p_from is null or p_to is null or p_to <= p_from
     or p_to > p_from + interval '32 days' then
    raise exception 'Hourly energy range must be 1 to 32 days';
  end if;
  return query
  with samples as (
    select s.type, s.start_at, s.end_at, s.value
    from public.health_samples s
    where s.user_id = p_user_id
      and s.type in ('HKQuantityTypeIdentifierBasalEnergyBurned',
                     'HKQuantityTypeIdentifierActiveEnergyBurned')
      and s.unit = 'kcal'
      and s.start_at < p_to and s.end_at > p_from and s.end_at > s.start_at
  ), split as (
    select s.type, s.value, extract(epoch from s.end_at - s.start_at) as sample_seconds,
           hours.hour_at,
           greatest(s.start_at, p_from, hours.hour_at) as overlap_from,
           least(s.end_at, p_to, hours.hour_at + interval '1 hour') as overlap_to
    from samples s
    cross join lateral generate_series(
      to_timestamp(floor(extract(epoch from greatest(s.start_at, p_from)) / 3600) * 3600),
      to_timestamp(floor(extract(epoch from least(s.end_at, p_to) - interval '1 microsecond') / 3600) * 3600),
      interval '1 hour'
    ) as hours(hour_at)
  )
  select split.hour_at,
         coalesce(sum(split.value * extract(epoch from split.overlap_to - split.overlap_from)
                      / split.sample_seconds) filter (where split.type = 'HKQuantityTypeIdentifierBasalEnergyBurned'), 0)::double precision,
         coalesce(sum(split.value * extract(epoch from split.overlap_to - split.overlap_from)
                      / split.sample_seconds) filter (where split.type = 'HKQuantityTypeIdentifierActiveEnergyBurned'), 0)::double precision,
         count(*) filter (where split.type = 'HKQuantityTypeIdentifierBasalEnergyBurned'),
         count(*) filter (where split.type = 'HKQuantityTypeIdentifierActiveEnergyBurned')
  from split where split.overlap_to > split.overlap_from
  group by split.hour_at order by split.hour_at;
end;
$$;
revoke all on function private.tracker_hourly_energy(uuid,timestamptz,timestamptz) from public;

commit;
