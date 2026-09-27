# ADR 0004: Lean mass, maintenance calories, and protein reference

Status: implemented in the iOS app; source build and unsigned Simulator UI verified, owner-data verification pending.

The user logs body weight in this app rather than importing Apple Health `bodyMass`. They may also log lean body mass, meaning fat-free mass rather than skeletal muscle mass. A manual lean-mass record has a stable UUID and syncs as `health_samples.type = app_lean_mass`; Apple Health `leanBodyMass` is a fallback. Height remains in Settings; age and biological sex come from Apple Health unless manually overridden. No weight or lean-mass value is fabricated.

For a mostly seated day, estimated maintenance intake uses Cunningham resting energy `(500 + 22 × fat-free mass kg) × 1.2` when valid fat-free mass is available; otherwise it uses Mifflin-St Jeor × 1.2 when weight, height, age, and sex are all available. This is not measured expenditure or a weight-loss calorie target. The user's 3–4 resistance sessions per week during a calorie deficit justify showing a protein reference of 2.3–3.1 g/kg fat-free mass/day, falling back to 1.8–2.7 g/kg body weight/day. These are broad sports-nutrition references, not individual medical advice. Sources: Cunningham (1980), Mifflin et al. (1990), Helms et al. (2014).

Meal estimates remain separate from original meal logs. Today and History display estimated protein per meal and daily total, explicitly marking partial totals when a meal has no protein estimate. A live unique `(user_id,meal_id)` constraint ensures one current estimate per meal. These values are provisional estimates, not confirmed dietary intake.
