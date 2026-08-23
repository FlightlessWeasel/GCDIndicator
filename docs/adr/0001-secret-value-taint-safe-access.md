# 0001. Secret Value / taint-safe API access pattern

Date: 2026-08-11
Status: Accepted

## Context

WoW 12.1 introduced the Secret Value system: some aura/API fields
(`applications`, `auraInstanceID`, some spell IDs) can be opaque `<SECRET>`
values while an addon's execution is "tainted" (e.g. inside combat, or
handling `UNIT_AURA` in the same call chain as Blizzard's own
`CooldownViewer`/CDM handlers). Reading, comparing, `tostring()`-ing, or
table-keying a secret value errors or silently redacts. Separately, calling
into certain Blizzard frame/widget internals (or even just reading some of
their fields) from a tainted context can itself taint further Blizzard code
that runs afterward in the same chain — confirmed in-game 2026-08-21 when a
synchronous `PLAYER_ENTERING_WORLD` read of CDM's `itemFramePool` produced
`"attempt to perform boolean test on ... secret boolean value, while
execution tainted by 'GCDIndicator'"` errors inside Blizzard's own
`CooldownViewerItemData.lua` (see `MISTAKES.md`).

This isn't a one-off API quirk to work around locally — it's a standing
constraint on *every* aura/CDM-adjacent read in the addon, so it needed a
consistent, repo-wide pattern rather than ad hoc fixes per call site.

## Decision

- **Never call a secret-capable API unprotected.** Wrap in `pcall`; treat a
  failed `pcall` as "unreadable this tick," not an error to surface.
- **Never `tostring()`/concatenate a possibly-secret value** into debug
  output or a table key. Debug strings report what the addon *told* the
  engine to do, or values already extracted via a successful `pcall`, never
  a raw read of a secret-capable field.
- **Defer aura-driven buff-bar work out of the `UNIT_AURA` call chain.**
  Register with `RegisterUnitEvent("UNIT_AURA", "player")` and hand off via
  `C_Timer.After(0, ...)` before touching CDM frame state — running in the
  same chain as Blizzard's own `BuffIconCooldownViewer` aura handlers taints
  execution, which then makes *Blizzard's* code fail on secret values it
  would otherwise handle fine.
- **Never call `GetAuraDataByAuraInstanceID`/read state back off an
  engine-bound `AuraContainer`/`AuraButton` after binding it** (`GetSize`,
  `IsShown`, `GetMinMaxValues`, etc.) — those reads can come back
  secret/opaque with no error, poisoning any string built from them. Where a
  native binding is used (ADR 0003), the engine owns the visual state
  entirely and GCDI never reads it back.
- **Any new code that reads deep into `C_CooldownViewer`/CDM frame-pool
  internals must be audited for which event/call-chain it runs in, not just
  wrapped in a `pcall`** — taint isn't caught by `pcall`. Prefer call sites
  already known to be clean (a deferred `C_Timer.After(0, ...)` callback, a
  user-triggered slash command) over registering new synchronous work on
  Blizzard-adjacent events.

## Consequences

- Every buff/stack/dispel read degrades gracefully (keeps last known-good
  value, or shows nothing) instead of erroring, at the cost of occasionally
  stale display during combat when direct reads get redacted — this is what
  the fallback chains in ADR 0002 exist to minimize.
- New contributors (or future sessions) can't apply "just wrap it in
  `pcall` and it's safe" — taint propagation through Blizzard's own code is
  a separate failure mode `pcall` doesn't catch, and has to be reasoned
  about per call site (see the incident this ADR is partly written from,
  `MISTAKES.md`'s "PLAYER_ENTERING_WORLD CDM rescan tainted Blizzard's
  CooldownViewer").
- No unit test coverage for this — `tests/` only covers pure-logic `Libs/*`
  modules with no frame/WoW-event dependency (ADR 0007). Verification is
  `pcall`/taint discipline reviewed by eye, plus in-game confirmation.

## Alternatives considered

- **Read `auraInstanceID`/`.applications` directly, unprotected** (the pre-
  12.1 / V1 approach). Simpler, but throws outright once a value is secret —
  confirmed dead on this build for direct reads in combat (see ADR 0002).
- **Gate on a build-number check** instead of a live capability/state check
  (e.g. `if buildNumber >= 120100 then assume secret`). Tried once for the
  dispel indicator and found to silently disable the feature on every
  current client with no error — see `MISTAKES.md`'s "Dispel indicator
  silently disabled on every client" postmortem. Rejected as a pattern:
  version gates don't re-evaluate once the threshold passes, so they can't
  track a runtime condition that's actually "is this specific value secret
  right now."
