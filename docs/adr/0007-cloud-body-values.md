# 0007: Cloud-authored body values

Status: Accepted, 2026-09-27

The user may log weight, fat-free mass, basal-energy estimates, and maintenance-intake estimates manually or through AI. Each entry has a stable ID, timestamp, source, and value. The app pulls latest values from the existing private `health_samples` table; `app_weight`, `app_lean_mass`, `app_basal_energy`, and `app_maintenance_energy` distinguish the four kinds. AI source values are labeled AI. App-owned pending entries upload once and cloud corrections to the same ID win on refresh, preventing stale local data from overwriting an AI correction. Synced entries removed from the cloud are removed locally on refresh; pending local entries remain until uploaded. No schema change is required.

Apple Health basal energy remains a separate today-to-date measurement; a cloud basal entry is a daily estimate. Formula maintenance remains a fallback when no cloud estimate exists. The user-visible profile term is “gender for formula”; HealthKit's API name and legacy stored `sex` key remain supported for compatibility. The selection chooses a male/female coefficient, not identity.

Alternatives considered: putting these values only in local storage would prevent ChatGPT-to-Supabase updates from reaching the phone; re-uploading all cached rows would overwrite cloud corrections; replacing formula/HealthKit values would conceal their provenance.
