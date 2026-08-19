# Mistakes

## Copilot review merge gate (2026-08-15)

**What happened:** A draft-state merge gate was added after branch protection
was found unavailable, but the workflow's `GITHUB_TOKEN` could not execute the
required GraphQL mutation and returned "Resource not accessible by
integration."

**Root cause:** The repository's GitHub Free plan does not expose branch
protection for this private repository, and the Actions integration token is
not permitted to change pull request draft state.

**Prevention:** Verify both product-plan availability and token permissions
before implementing a merge gate. Use required status checks with branch
protection when available, or explicitly configure an appropriately scoped
credential before relying on draft-state automation.

## Dispel indicator silently disabled on every current client (found 2026-08-16)

**What happened:** The classic Lua-side dispel scan
(`player_has_dispellable_debuff_on_self`, now deleted — see
`docs/dispel-indicator.md`) gated itself on
`GCDI_AURAS_INSTANCE_API_UNSAFE`, a build-number check
(`(tonumber((select(4, GetBuildInfo()))) or 0) >= 120100`) that unconditionally
returned `false` (idle/no-dispel-needed) on every client at or past interface
120100 (patch 12.1) — which is every current retail client. The indicator
rendered identically to "nothing to dispel" whether or not that was true, with
no error, no debug message gated behind normal debug mode reaching the user,
and no other visible signal that detection had stopped working. This went
unnoticed for an unknown number of sessions until the native engine-owned
overlay replacement surfaced it.

**Root cause:** The gate was written against *when the API might start
throwing under secrecy* (a client-version proxy) rather than against the
actual runtime condition that determines whether the scan is safe to run
right now (whether auras are currently secret, e.g. via
`C_Secrets.ShouldAurasBeSecret()` if that call had been used). A version-number
gate never re-evaluates — once the client passed build 120100, the condition
was permanently `true` and the function permanently returned `false`, for
every player, in and out of combat, regardless of whether the aura API would
have actually thrown at that moment.

**Prevention:** Prefer runtime capability/state checks over version-number
gates for anything that can be tested live (e.g. `pcall`-wrapping the actual
API call and checking whether it errors, or querying an explicit
secrecy-status API if one exists) — a version gate is only appropriate when
the failure mode is a hard API removal, not a conditional/contextual
restriction. This is also now moot for the dispel indicator specifically:
detection moved to the native `AuraContainer`/`AddAuraSlot` overlay path,
which doesn't gate on aura secrecy at all — the engine owns visibility
directly and GCDI never reads a boolean back into Lua.
