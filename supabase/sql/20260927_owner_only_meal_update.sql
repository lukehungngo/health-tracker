-- Applied to P Health on 2026-09-27 after confirming the private meal backups.
-- Authenticated users may update only rows they own. RLS remains enabled.
-- This is an audit copy, not a pending CLI migration.

begin;

grant update on public.meals, public.meal_estimates to authenticated;

create policy tracker_update on public.meals
  for update to authenticated
  using (private.tracker_can_write(user_id))
  with check (private.tracker_can_write(user_id));

create policy tracker_update on public.meal_estimates
  for update to authenticated
  using (private.tracker_can_write(user_id))
  with check (private.tracker_can_write(user_id));

commit;
