# ADR 0005: Existing-account email-link sign-in

Status: implemented in app; email round-trip verification pending.

The owner prefers signing in by clicking an email link rather than entering a password in Simulator. Keep the existing email/password path, and add Supabase `signInWithOTP` using the already allowlisted `healthtracker://auth-callback` redirect with `shouldCreateUser = false`. This cannot silently create another account. The callback exchanges the code through the same Supabase client that requested the link, retaining its PKCE verifier. The link must therefore be opened on the same Simulator or physical iPhone that requested it, not merely on the Mac browser. Never log or commit the link, code, session token, or password.
