-- Apply after enabling Neon Data API. No anonymous table privileges.
begin;

grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.health_samples, public.workouts, public.meals,
  public.meal_estimates, public.protein_targets, public.daily_summaries
  to authenticated;
revoke all on
  public.health_samples, public.workouts, public.meals,
  public.meal_estimates, public.protein_targets, public.daily_summaries
  from anonymous;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'health_samples','workouts','meals','meal_estimates',
    'protein_targets','daily_summaries'
  ] loop
    execute format('drop policy if exists tracker_owner on public.%I', table_name);
    execute format(
      'create policy tracker_owner on public.%I for all to authenticated ' ||
      'using ((select auth.user_id())::uuid = user_id) ' ||
      'with check ((select auth.user_id())::uuid = user_id)',
      table_name
    );
  end loop;
end;
$$;

revoke all on schema private from authenticated;
revoke all on function private.tracker_hourly_energy(uuid,timestamptz,timestamptz)
  from authenticated;
create or replace function public.tracker_hourly_energy(
  p_from timestamptz, p_to timestamptz
)
returns table (
  hour_at timestamptz,
  basal_kcal double precision,
  active_kcal double precision,
  basal_samples bigint,
  active_samples bigint
)
-- Neon owns the auth schema, so authenticated cannot call auth.user_id()
-- directly from a SQL wrapper. This narrowly scoped definer wrapper derives
-- the owner exclusively from the verified request JWT and returns read-only
-- aggregates for that owner; it takes no caller-supplied user_id.
language sql stable security definer
set search_path = ''
as $$
  select * from private.tracker_hourly_energy(
    auth.user_id()::uuid, p_from, p_to
  );
$$;
revoke all on function public.tracker_hourly_energy(timestamptz,timestamptz) from public, anonymous;
grant execute on function public.tracker_hourly_energy(timestamptz,timestamptz) to authenticated;

commit;
