# Mistakes

## Copilot review merge gate (2026-08-15)
Draft-state merge gate failed: GitHub Free plan has no branch protection, and
Actions `GITHUB_TOKEN` can't call the draft-state GraphQL mutation ("Resource
not accessible by integration"). **Fix:** verify plan tier + token perms
before building merge gates; use required status checks or a scoped
credential instead.

## Dispel indicator silently disabled on every client (found 2026-08-16)
`player_has_dispellable_debuff_on_self` (deleted, see `docs/dispel-indicator.md`)
gated on a build-number check (`>= 120100`) meant to proxy "auras might be
secret," but that's true on every current client — so it always returned
false/no-dispel with no error, silently broken for unknown sessions.
**Root cause:** version-number gate used as a proxy for a runtime condition
that never re-evaluates once the version threshold passes. **Fix:** gate on
live capability/state checks (`pcall` the real call, or an explicit secrecy
API) instead of version gates, unless the failure mode is a hard API
removal. Now moot: detection moved to native `AuraContainer`/`AddAuraSlot`
overlay, which doesn't gate on secrecy at all.
