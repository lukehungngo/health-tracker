# ADR 0009: AI/manual protein target as an atomic range

Status: implemented.

The displayed protein recommendation is an editable daily range, distinct from protein already eaten. The app stores manual entries locally and syncs them to `public.protein_targets`; Codex or ChatGPT can author or correct a row in the same table with `source = 'ChatGPT'`. The newest `recorded_at` wins on Today, with a Manual or AI badge and timestamp. The prior body-composition formula remains visible only when no explicit entry exists.

One row contains both `min_g` and `max_g`, so AI cannot leave the app with half of a range. A stable UUID `id` is the retry/correction key; an upsert of the same ID changes the existing entry rather than creating a duplicate. The app merges cloud corrections by ID while preserving pending offline manual entries. The table uses the existing tracker read/write RLS helpers and grants no anonymous access. Values are constrained to a 20–400 g/day range with `min_g <= max_g`.

The target is a personal reference, not a medical prescription or a computed fact about actual meal intake.
