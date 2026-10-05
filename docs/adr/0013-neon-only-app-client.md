# ADR 0013: Neon-only iPhone runtime

## Decision

Remove the Supabase Swift package from the Xcode project. The iPhone app uses
Neon Auth and private meal-image endpoints as before, and sends its existing
table, filter, RPC, and idempotent upsert operations directly to Neon Data API
through a small `URLSession` client. Keep JWT authorization, owner-scoped row
filters, `on_conflict` keys, and the existing bundle ID unchanged.

## Scope and rationale

The previous app connected only to Neon, but obtained its generic PostgREST
client from the Supabase Swift package. Removing that package makes the shipped
app independent of Supabase while preserving Neon's PostgREST-compatible HTTP
contract. Historical Supabase SQL and the optional archival export script stay
outside the app build for audit/recovery; this decision does not delete the old
cloud project, local backups, or migrated Neon data.

## Verification

Build and run Simulator tests, including request-shape tests for Neon reads,
stable-ID upserts, owner-filtered updates, and server error propagation. A
successful Simulator build is not proof that this specific build is installed
or signed on the owner's iPhone; verify live-device behavior separately.
