# 0002. CDM buff/debuff tracking via a self-healing frame-pool cache

Date: 2026-08-21
Status: Accepted

## Context

GCDIndicator tracks buff/debuff active state and stack counts by piggy-
backing on Blizzard's own Cooldown Manager (CDM) rather than scanning
`UnitAura` directly (see ADR 0001 for why direct secret-value reads are
unreliable in combat). CDM's `BuffIconCooldownViewer.itemFramePool` reuses a
fixed pool of frame objects, reassigning any given frame object to a
different `cooldownID` (a stable per-slot identifier, not a per-aura-
instance one) as buffs come and go — documented in `CLAUDE.md`'s "CDM frame
pool is stateful/reused" constraint.

`cdmBuffFrames[cooldownID] -> frame` is GCDIndicator's own cache of that
mapping, built by `scan_cdm_buff_frames()` and incrementally kept in sync by
a `hooksecurefunc` on `CooldownViewerItemDataMixin:RefreshData`. In practice
this cache went stale in a way the existing staleness guard (reject a frame
whose own `.cooldownID` no longer matches the slot it's cached under) could
detect but not fix: with the guard alone, a rejected frame just left that
buff undetected — confirmed in-game 2026-08-21 for Ironfur (`cooldownID`
2791), where the cached frame had been reassigned to `cooldownID` 3229, then
175987 moments later, drifting continuously as the pool churned. Both the
active-indicator and stack count depend on this lookup, so a stale entry
broke both at once, and looked identical to "detection is broken" until the
diagnostic probe below isolated it.

A first fix attempt — re-running `scan_cdm_buff_frames()` on every
`PLAYER_ENTERING_WORLD` (zone transitions) — didn't work (the scan only
captures frames that are *currently active*, so a buff not yet cast since
zoning in was never fixed) and caused a regression: reading CDM internals
synchronously in that handler tainted Blizzard's own CooldownViewer refresh
chain (ADR 0001, `MISTAKES.md`). It was removed.

## Decision

Diagnosed via a throwaway in-game A/B probe (`plans/buff-stack-probe-plan.md`,
modeled on the dispel overlay's own Phase 0 probe, ADR 0003) that ran 7
detection methods side by side and displayed live results, rather than
guessing from code reading alone. That confirmed: direct spellID-based reads
(`GetPlayerAuraBySpellID`/`GetUnitAuraBySpellID`) and the V1-era
`GetAuraDataByAuraInstanceID` approach both work fine out of combat but
return nothing in combat (Secret Value redaction, ADR 0001) — while the
shipped chain, which ultimately falls back to `cdmFrame.auraDataCached`
(populated by the `SetAuraInstanceInfo` hook), survives combat because it's
reading data CDM's own internals already extracted, not making a fresh
secret-gated call.

Given that, the fix for the stale-frame problem is an **on-demand self-heal
at read time**: when `update_buff_bar`'s cdmFrame lookup finds nothing or
finds a stale entry, it searches `BuffIconCooldownViewer.itemFramePool
:EnumerateActive()` for whichever frame currently holds that `cooldownID`
right now, adopts it, and updates the cache — instead of waiting on the
`RefreshData` hook (whose exact firing conditions for this case are
unverified) or a periodic bulk rescan (which only sees active frames anyway,
so has the same blind spot as the pool itself).

## Consequences

- Correctness no longer depends on the `RefreshData` hook winning a race
  against pool reassignment — every read of a buff self-corrects, which is
  strictly more robust than the pure-cache approach, at the cost of one
  small pool enumeration on a miss/staleness hit (bounded by the number of
  currently-active CDM frames, not the whole catalog).
- This only helps when the target buff is actually active — an inactive
  buff correctly finds nothing, same as before. That's fine: an inactive
  buff has no state to self-heal.
- Extends `update_buff_bar`'s existing lookup chain
  (`cdmBuffFrames[cooldownID]` -> reverse spellID map -> `catalogEntry.cdmFrame`
  -> staleness guard) with one more step; doesn't replace any of it.
- The active-indicator dot also had an unrelated, purely visual bug found
  during the same investigation: `create_bar_container` (shared with
  spell/item bars) always creates a cooldown-sweep `clipContainer` with an
  opaque white background, which buff bars don't use but never hid — it sat
  exactly on top of the active-indicator texture and masked its color
  regardless of state. Fixed by hiding it in `create_buff_bar`. Kept as part
  of this ADR rather than its own, since it was found and fixed in the same
  investigation and isn't a decision with alternatives — just a bug.

## Alternatives considered

- **Direct live reads only** (`GetPlayerAuraBySpellID`/`GetUnitAuraBySpellID`,
  no CDM frame involvement at all). Rejected: confirmed dead in combat via
  the probe (ADR 0001's Secret Value constraint).
- **V1's `GetAuraDataByAuraInstanceID` + unit auto-detect.** What the addon
  did pre-12.1. Confirmed dead in combat by the same probe — this is exactly
  the API class ADR 0001 says the engine now redacts.
- **Native engine-owned stack fill** (`AddAuraSlot` + `SetApplicationBar`,
  same idea as the dispel overlay in ADR 0003 but for a numeric fill instead
  of show/hide). Tested in-game 2026-08-11: wiring correct, no errors, but
  the bar never rendered a fill at any stack count — confirmed not
  functional on this build/API maturity level. Not re-attempted here.
- **Rescan on every `PLAYER_ENTERING_WORLD`.** Tried first; doesn't fix the
  bug (misses inactive buffs) and caused a taint regression (ADR 0001).
  Removed in favor of the self-heal.
