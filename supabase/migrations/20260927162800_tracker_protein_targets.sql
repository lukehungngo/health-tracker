-- One atomic, idempotently upsertable daily protein range per entry.
create table public.protein_targets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  recorded_at timestamptz not null,
  min_g double precision not null,
  max_g double precision not null,
  source text not null,
  created_at timestamptz not null default now(),
  constraint protein_targets_range check (min_g >= 20 and max_g >= min_g and max_g <= 400)
);

create index protein_targets_user_recorded_idx on public.protein_targets (user_id, recorded_at desc);
alter table public.protein_targets enable row level security;
revoke all on public.protein_targets from public, anon;
grant select, insert, update on public.protein_targets to authenticated;

create policy tracker_read on public.protein_targets
  for select to authenticated using (private.tracker_can_read(user_id));
create policy tracker_insert on public.protein_targets
  for insert to authenticated with check (private.tracker_can_write(user_id));
create policy tracker_update on public.protein_targets
  for update to authenticated using (private.tracker_can_write(user_id))
  with check (private.tracker_can_write(user_id));
