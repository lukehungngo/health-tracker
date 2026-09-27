# ADR 0006: Owner-only updates for cloud meals

Status: applied to P Health on 2026-09-27.

Cloud meal corrections must converge on the iPhone without creating a second meal or estimate. `public.meals` and `public.meal_estimates` already had owner-aware SELECT and INSERT policies, but `authenticated` had no UPDATE grant or policy, so an owner-scoped upsert could not correct an existing row. This was a schema authorization gap, not a reason to disable RLS or grant access to `anon`.

Grant UPDATE on these two tables to `authenticated` and add one UPDATE policy per table. Both `USING` (existing row) and `WITH CHECK` (resulting row) require `private.tracker_can_write(user_id)`. Keep RLS enabled, the existing SELECT/INSERT policies, and the absence of UPDATE permission for `anon`. The exact applied SQL is in `supabase/sql/20260927_owner_only_meal_update.sql`; it is an audit copy rather than a pending migration. The existing private CSV backups of both tables were checked before applying it. No meal or estimate rows were intentionally changed.

Verification: the live catalog showed both new policies, RLS enabled, UPDATE granted to `authenticated` and denied to `anon`. A role/JWT simulation updated at least one owner meal and estimate inside a transaction that was rolled back; a different simulated user updated zero owner rows. The refreshed Supabase Security Advisor showed zero errors and one unrelated Auth warning about disabled leaked-password protection. This verifies database authorization, not yet a full ChatGPT-written correction followed by an iPhone pull.
