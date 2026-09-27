-- Aggregate owner-visible HealthKit energy into UTC hours. The iPhone applies
-- local sleep/office assumptions only where neither energy type has a sample.
create or replace function public.tracker_hourly_energy(p_from timestamptz, p_to timestamptz)
returns table (
  hour_at timestamptz,
  basal_kcal double precision,
  active_kcal double precision,
  basal_samples bigint,
  active_samples bigint
)
language plpgsql
stable
security invoker
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
    from public.health_samples as s
    where s.user_id = (select auth.uid())
      and s.type in ('HKQuantityTypeIdentifierBasalEnergyBurned',
                     'HKQuantityTypeIdentifierActiveEnergyBurned')
      and s.unit = 'kcal'
      and s.start_at < p_to and s.end_at > p_from
      and s.end_at > s.start_at
  ), split as (
    select s.type, s.value,
           extract(epoch from s.end_at - s.start_at) as sample_seconds,
           hours.hour_at,
           greatest(s.start_at, p_from, hours.hour_at) as overlap_from,
           least(s.end_at, p_to, hours.hour_at + interval '1 hour') as overlap_to
    from samples as s
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
  from split
  where split.overlap_to > split.overlap_from
  group by split.hour_at
  order by split.hour_at;
end;
$$;

revoke all on function public.tracker_hourly_energy(timestamptz, timestamptz) from public, anon;
grant execute on function public.tracker_hourly_energy(timestamptz, timestamptz) to authenticated;
