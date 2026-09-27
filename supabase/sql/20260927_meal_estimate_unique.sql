-- Applied to P Health on 2026-09-27 after exporting meals and meal_estimates.
-- Enforces one current nutrition estimate per owner-owned meal.
-- Existing composite foreign key already enforces owner/meal consistency.
-- This is an audit copy, not a pending CLI migration.

begin;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.meal_estimates'::regclass
      and conname = 'meal_estimates_user_meal_key'
  ) then
    alter table public.meal_estimates
      add constraint meal_estimates_user_meal_key unique (user_id, meal_id);
  end if;
end
$migration$;

commit;
