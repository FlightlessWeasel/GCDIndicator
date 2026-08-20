# Class-appropriate resource bar defaults + profile-dirty indicator

## Problem

`settings.resourceSettings[key]` defaulted every resource bar (mana, rage,
runes, holy power, ...) to `true` regardless of the player's class, because
class filtering only existed in the Options UI (which resources get a
checkbox row), never in the actual enable/disable value. A fresh install, a
newly created profile, or an account-wide settings table shared across alts
could all end up showing every class's resource bars at once.

Separately, `GCDI.auto_save_to_profile()` (wired into ~20 settings-change
call sites) is not reliably persisting changes to the active profile, but
there was no UI signal telling the user their live settings had diverged
from the saved profile.

## Class-resource source of truth

`Libs/LibGCDI-Profiles/LibGCDI-Profiles.lua` owns `RESOURCE_CLASS_TOKENS`
(key -> classFileName tokens) plus three pure functions that take
`classToken` as a parameter (never call `UnitClass` themselves, so they stay
unit-testable under plain Lua):

- `lib:GetClassResourceDefaults(classToken)` — fresh `resourceSettings` table
  with only health + that class's resources enabled, stagger always off.
- `lib:EnforceClassResources(settings, classToken)` — disables any
  currently-enabled entry the class can't use; returns `true` if it changed
  anything.
- `lib.ResourceAppliesToClass(key, classToken)` — the underlying predicate.

This duplicates `RESOURCE_NAMES.classTokens` in
`Libs/LibGCDI-Options/LibGCDI-Options.lua` (which drives which checkbox rows
the Resources tab renders). Keep both in sync by hand if a class/resource
mapping changes — they serve different concerns (UI rows vs. persisted
enable state) and Options already duplicated GCDIndicator.lua's resource
metadata before this change.

## Call sites (GCDIndicator.lua)

- `init()`'s settings-default block: brand-new `resourceSettings` uses
  `GetClassResourceDefaults` instead of all-`true`.
- Login auto-load of `settings.currentProfile` and `GCDI.load_profile()`:
  both call `EnforceClassResources` after `LoadProfile` and, if it changed
  anything, print a chat message telling the user to resave the profile
  (the in-memory fix isn't persisted until they do).
- `LibGCDI-Options.lua`'s `do_save_profile` (new-profile "Create" button):
  resets `resourceSettings` via `GetClassResourceDefaults` before snapshotting,
  so a new profile never inherits another class's enabled resources.
- `LibGCDI-Options.lua`'s `GCDI_SAVE_PROFILE_CONFIRM` popup (overwrite
  "Save"): calls `EnforceClassResources` on the live settings right before
  snapshotting, so a save can't persist a wrongly-enabled bar.

## Profile-dirty indicator

`GCDI.set_profile_dirty(isDirty)` (defined in `LibGCDI-Options.lua`, guarded
everywhere else with `if GCDI.set_profile_dirty then`) sets `GCDI.profileDirty`
and shows/hides an orange `*` (`btn.dirtyDot`) on the Profiles tab button
created in `create_tab_button`.

- Set dirty: `GCDI.auto_save_to_profile()`, whenever a profile is active —
  auto-save runs regardless, but the indicator is the real "you have unsaved
  changes" signal since auto-save isn't reliable.
- Cleared: `do_save_profile`, the Save-overwrite popup, `GCDI.load_profile`,
  the login auto-load path, and profile deletion when the deleted profile was
  the active one.

Any new "save" or "load" path added later must clear the flag itself — it is
not derived from diffing settings, just a manual set/clear.
