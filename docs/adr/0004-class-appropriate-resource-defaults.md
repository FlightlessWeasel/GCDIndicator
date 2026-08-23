# 0004. Class-appropriate resource bar defaults + profile-dirty indicator

Date: 2026-08-19
Status: Accepted

Full detail: [`docs/resource-class-defaults.md`](../resource-class-defaults.md)

## Context

`settings.resourceSettings[key]` defaulted every resource bar (mana, rage,
runes, holy power, ...) to enabled regardless of the player's class, because
class filtering only existed in the Options UI (which checkbox rows get
shown), never in the persisted enable/disable value itself. A fresh install,
a newly created profile, or an account-wide settings table shared across
alts could all end up showing every class's resource bars at once.
Separately, `GCDI.auto_save_to_profile()` (wired into ~20 settings-change
call sites) doesn't reliably persist changes, but there was no UI signal
telling the user their live settings had diverged from the saved profile.

## Decision

`Libs/LibGCDI-Profiles/LibGCDI-Profiles.lua` owns a single source of truth
(`RESOURCE_CLASS_TOKENS` + `GetClassResourceDefaults`/`EnforceClassResources`/
`ResourceAppliesToClass`, all pure functions taking `classToken` as a
parameter rather than calling `UnitClass` themselves, so they stay unit-
testable). Every settings-default, profile-load, profile-save, and new-
profile-create call site routes through these instead of defaulting/copying
`resourceSettings` verbatim. On load, if enforcement had to disable
anything, the user gets a chat message to resave — the in-memory fix isn't
persisted until they do.

Separately, `GCDI.set_profile_dirty(isDirty)` adds an explicit "you have
unsaved changes" `*` indicator on the Profiles tab, set on every
`auto_save_to_profile()` call and cleared on every save/load/delete path —
manually maintained, not derived from diffing settings, because auto-save
firing doesn't reliably mean the save succeeded.

## Consequences

- Duplicates `RESOURCE_NAMES.classTokens` in `LibGCDI-Options.lua` (which
  drives which checkbox rows the Resources tab renders) — the two serve
  different concerns (UI rows vs. persisted enable state) and Options
  already duplicated `GCDIndicator.lua`'s resource metadata before this
  change. Must be kept in sync by hand if a class/resource mapping changes.
- `EnforceClassResources` runs on every profile load, not just once at
  creation, so a profile that somehow accumulated a wrong class's resource
  (e.g. from a shared/exported settings string) self-corrects on next load
  rather than staying wrong indefinitely.
- The dirty indicator is a coarse signal (any settings change sets it,
  regardless of whether it's resource-related) — any future "save"/"load"
  path must remember to clear it itself; nothing derives it automatically.
- Test-covered: `tests/spec/profiles_spec.lua` exercises the pure functions
  directly (no WoW API/class-detection mocking needed, per ADR 0007's
  "pure logic only" scope).

## Alternatives considered

- **Fix only the Options UI checkbox filtering, leave the persisted value
  unconstrained.** Rejected: doesn't fix the actual bug (wrong bars showing)
  — only hides the wrongness from the settings *editor*, not the runtime
  state that actually drives rendering.
- **Derive the dirty indicator from diffing live settings against the saved
  profile** instead of manual set/clear. More "correct" in principle, but a
  full settings-tree diff on every change is unnecessary overhead for a
  binary indicator, and every mutation path already runs through
  `auto_save_to_profile()` as a natural hook point.
