# 0003. Native AuraContainer/AddAuraSlot dispel overlay

Date: 2026-08-16
Status: Accepted

Full detail: [`docs/dispel-indicator.md`](../dispel-indicator.md)

## Context

The dispel indicator (`main_frame.dispelbar`, purple = "you have a
dispellable debuff on yourself") originally worked by polling
`C_UnitAuras.GetDebuffDataByIndex`/`AuraUtil.ForEachAura` and painting the
bar from Lua. That path was gated behind a build-number check meant to proxy
"auras might be secret," which unconditionally evaluated false on every
current client — so the scan silently always reported "no dispel needed"
with no error (see `MISTAKES.md`'s postmortem). Reading a dispellable-or-not
boolean back into Lua at all is fundamentally the wrong shape post-12.1
(ADR 0001) — the fix needed to sidestep the read, not patch the gate.

## Decision

Bind a single native `AddAuraSlot("gcdi_dispel_overlay",
"HARMFUL|RAID_PLAYER_DISPELLABLE", ...)` directly over `main_frame.dispelbar`
via one `CreateFrame("AuraContainer", ...)`. The engine performs the
N-auras -> 1-bit reduction itself by showing/hiding the bound button;
GCDI never reads dispel state back into Lua at all. Verified via a
throwaway in-game probe (7 `AddAuraSlot` filter variants tested side by
side, `docs/dispel-indicator.md`'s "Phase 0 probe" section) before shipping
— the full grammar string `"HARMFUL|RAID_PLAYER_DISPELLABLE"` was the only
one that correctly discriminated dispellable-vs-not and survived a secret
combat period; several guessed `candidateFilters` keys were silently
ignored rather than erroring.

## Consequences

- No Secret Value handling needed for this indicator at all — the hardest
  part of ADR 0001's constraint doesn't apply here, because the addon never
  asks Lua whether the aura is dispellable.
- Trades a well-understood Lua polling loop for a newer, less-documented
  12.1 API surface (`AddAuraSlot`/`AuraContainer`), whose behavior needed
  in-game verification rather than being derivable from docs.
- Container creation is combat-lockdown gated (native frame creation must
  happen from a clean context) — binds from `PLAYER_ENTERING_WORLD` and
  retries from `PLAYER_REGEN_ENABLED`.
- This became the permanent, unconditional implementation (classic scan
  deleted outright), not a toggleable option — see "What changed when this
  became permanent" in the linked doc.

## Alternatives considered

- **Classic Lua-side scan** (original implementation). Rejected: dead on
  every current client per the postmortem above.
- **Gate on a live capability/state check instead of a build number.**
  Would have fixed the specific silent-false bug but still required reading
  a secret-capable value back into Lua every tick — same fragility class
  ADR 0001 warns against. Superseded by not reading the value at all.
