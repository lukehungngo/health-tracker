# ADR 0007: Editable text-or-photo meals

Status: implemented in app source; live authenticated upload/edit retry still requires verification.

An app meal may contain a note, a photo, or both. An empty meal is rejected. Supabase already permits a null `meals.image_path`, and `meal_estimates` already permits null calories and macros, so this change needs no database migration or new grants. A tap on a meal in Today or History opens one shared full-detail sheet; its Edit mode changes the note and optional kcal/protein/carbs/fat values. A blank nutrition value means unknown, not zero. Clearing the entire existing nutrition estimate is not supported by this edit flow.

The app persists every new meal and local edit before network I/O. Its stable meal ID is reused on upload and retry. A local pending edit wins over a cloud pull until upload succeeds; afterward a later cloud correction wins. The same rule applies to nutrition estimates, keyed by meal ID. App edits clear an estimate's AI confidence and mark its metadata `source=manual`, while note-only edits leave the estimate untouched. New meal estimates keep a stable ID on retries; if an AI estimate was inserted while the app was offline, the app updates that remote estimate by its existing ID rather than creating a second estimate. Existing owner-only RLS SELECT/INSERT/UPDATE policies remain in force.

Meal refresh runs independently of the HealthKit backfill. If a meal is saved while a refresh is in flight, one more refresh is queued. Photo uploads use the lowercase owner UUID path required by the live database constraint. This does not provide automatic conflict merging of simultaneous edits to the same field: the last successful upload wins. The UI must label failed uploads and retain local pending changes for retry.

Verification: unit tests for text-only, photo-only, combined, empty validation, pending local edits, cloud corrections, and retry without duplicate local rows; Simulator interaction for text-only save, keyboard Done, full detail, and edited values. Authenticated Supabase write/retry and real-device keyboard behavior remain separate gates.
