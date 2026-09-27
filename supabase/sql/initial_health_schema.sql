-- Personal Health Tracker: private, per-user source records.
-- Applied through the Skywalker Supabase SQL Editor on 2026-09-27.
-- This is an audit copy, not a pending CLI migration.

begin;

create table public.health_samples (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  external_id uuid not null,
  type text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  value double precision not null,
  unit text not null,
  source text,
  created_at timestamptz not null default now(),
  unique (user_id, external_id)
);

create index health_samples_user_start_idx on public.health_samples (user_id, start_at desc);

create table public.workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  healthkit_id uuid not null,
  type text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  duration_seconds double precision not null,
  active_energy_kcal double precision,
  avg_heart_rate double precision,
  max_heart_rate double precision,
  created_at timestamptz not null default now(),
  unique (user_id, healthkit_id)
);

create index workouts_user_start_idx on public.workouts (user_id, start_at desc);

create table public.meals (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  eaten_at timestamptz not null,
  note text not null default '',
  image_path text not null,
  created_at timestamptz not null default now()
);

create index meals_user_eaten_idx on public.meals (user_id, eaten_at desc);

alter table public.health_samples enable row level security;
alter table public.workouts enable row level security;
alter table public.meals enable row level security;

revoke all on public.health_samples, public.workouts, public.meals from public, anon;
grant select, insert, update, delete on public.health_samples, public.workouts, public.meals to authenticated;

create policy "owner reads health samples" on public.health_samples
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "owner inserts health samples" on public.health_samples
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "owner updates health samples" on public.health_samples
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "owner deletes health samples" on public.health_samples
  for delete to authenticated using ((select auth.uid()) = user_id);

create policy "owner reads workouts" on public.workouts
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "owner inserts workouts" on public.workouts
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "owner updates workouts" on public.workouts
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "owner deletes workouts" on public.workouts
  for delete to authenticated using ((select auth.uid()) = user_id);

create policy "owner reads meals" on public.meals
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "owner inserts meals" on public.meals
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "owner updates meals" on public.meals
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('meal-images', 'meal-images', false, 10485760, array['image/jpeg'])
on conflict (id) do nothing;

create policy "owner reads meal images" on storage.objects
  for select to authenticated
  using (bucket_id = 'meal-images' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "owner uploads meal images" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'meal-images' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "owner replaces meal images" on storage.objects
  for update to authenticated
  using (bucket_id = 'meal-images' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'meal-images' and (storage.foldername(name))[1] = (select auth.uid())::text);

commit;
