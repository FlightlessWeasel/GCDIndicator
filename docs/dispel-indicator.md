# Dispel Indicator: Native Engine-Owned Overlay

Covers `main_frame.dispelbar` (the GCD row's 7th indicator, purple = "you have
a debuff you can dispel on yourself", grey = idle) and its sole detection
mechanism: a native `AuraContainer`/`AddAuraSlot` overlay in
`GCDIndicator.lua`. This graduated from a toggleable A/B experiment
(`configs.useNativeDispelBinding`) to the permanent, unconditional
implementation on 2026-08-16, after the user confirmed in-game that it works
and asked for the classic Lua-side scan to be removed entirely. Read this
before touching `main_frame.dispelbar`, its overlay, or the `showDispel`
GCD-tab checkbox.

## Why

The classic approach — poll `C_UnitAuras.GetDebuffDataByIndex`/
`AuraUtil.ForEachAura` on `UNIT_AURA` plus a low-rate safety timer, look for
a `"RAID_PLAYER_DISPELLABLE"` (or `canActivePlayerDispel`) hit, and paint
`main_frame.dispelbar` purple/grey — is dead on every current retail client.
It was gated behind a build-number check
(`GCDI_AURAS_INSTANCE_API_UNSAFE >= 120100`, "Interface 120100+ (12.1):
instance-ID aura data APIs throw under secrecy for addons") that unconditionally
returned `false` (i.e. "idle, no dispel needed") on any 12.1+ build — see
`MISTAKES.md` for the postmortem on why this went unnoticed. The classic scan
being dead-but-silent (it just always painted idle grey, indistinguishable
from "genuinely nothing to dispel") is exactly what made this a real defect,
not just a missed optimization.

The native path sidesteps the problem instead of working around it: rather
than reading a dispellable-or-not boolean back into Lua (closed off by the
12.1 Secret Value system — see `CLAUDE.md`'s "Secret Value system" section),
bind a single `AddAuraSlot` filtered to dispellable harmful auras directly
over the indicator's own StatusBar, and let the engine perform the
N-auras -> 1-bit reduction by showing/hiding the bound button. GCDI never
reads state back off it.

## What: the Phase 0 probe result this is built on

Before shipping, a throwaway diagnostic (`CHANGE-TRACKER.md`'s "Dispel
Detection Probe (Phase 0)" entry, now historical) registered 7 `AddAuraSlot`
variants side by side and tested them in-game. Verified, in-game-confirmed
results (not guessed, not recalled from training data):

- **`"HARMFUL|RAID_PLAYER_DISPELLABLE"` (the full aura-filter grammar
  string) works** — correctly discriminates a dispellable debuff from a
  non-dispellable one on the player, survives a secret combat period
  (repeated the discriminator test in combat with identical results to
  out-of-combat), and clears within ~1s of the debuff being dispelled or
  expiring (no stuck-purple latch observed).
- **Bare `"RAID_PLAYER_DISPELLABLE"` alone (no `"HARMFUL|"` prefix) does not
  register/light at all.** The full grammar string is required.
- **Guessed `candidateFilters` keys don't work**: `dispellable`,
  `isDispellable`, `canActivePlayerDispel`, `dispelTypes` were all silently
  ignored rather than erroring — those slots behaved like an unfiltered
  `"HARMFUL"` control (false positives on non-dispellable test debuffs too),
  not like a working filter. There is no known `candidateFilters` key for
  dispel-restriction; the filter string itself (`"HARMFUL|RAID_PLAYER_DISPELLABLE"`)
  is the only confirmed-working mechanism.
- **The engine owns visibility bidirectionally, including during secret/combat
  periods.** This is the core property the whole design depends on: GCDI
  never queries the bound button's shown-state (that read can itself come
  back secret/opaque post-bind — see "Verified API assumptions" below), it
  only ever tells the engine what to bind once, and the engine paints
  correctly on its own from then on, combat or not.

## How: `gcdi_setup_dispel_overlay` (`GCDIndicator.lua`, "Native
AuraContainer/AddAuraSlot dispel overlay" section, immediately after
`gcdi_setup_all_native_stack_slots` and before `create_buff_bar`)

- `gcdi_ensure_dispel_overlay_container()` — lazily creates one
  `AuraContainer` (`CreateFrame("AuraContainer", nil, main_frame,
  "CustomAuraContainerTemplate")`) bound to `"player"` via `SetUnit`. Refuses
  to create while `InCombatLockdown()` is true (native frame creation must
  happen from a clean, non-tainted context) and is retried from
  `PLAYER_REGEN_ENABLED`'s post-combat handler.
- `gcdi_setup_dispel_overlay()` — idempotent (`if dispelOverlayBound then
  return end`), registers exactly one `AddAuraSlot("gcdi_dispel_overlay",
  "HARMFUL|RAID_PLAYER_DISPELLABLE", { templateNames = {
  "GCDIDispelOverlayTemplate" }, initializeFrame = ... })`. `initializeFrame`
  anchors the button via `SetAllPoints(main_frame.dispelbar)` one frame level
  above it, sets its `Fill` texture to the same `0.6, 0.2, 0.8` purple the
  classic bar used to paint, and — once — sets the classic
  `main_frame.dispelbar` itself to permanent idle grey (`0.28, 0.28, 0.32`).
  From that point on the classic bar is purely a static background; the
  overlay button is the only thing that ever changes color/visibility for
  this indicator. `container:UpdateAllAuras()` is called once after
  registration so an already-active dispellable debuff (e.g. toggling this
  on mid-buff) binds immediately rather than waiting for the next aura-change
  event.
- Called unconditionally (no config-flag guard) from `PLAYER_ENTERING_WORLD`
  and from `PLAYER_REGEN_ENABLED`'s combat-lockdown retry — the same two
  call sites `useNativeStackBinding`'s sibling experiment uses for the same
  reason (container creation can only succeed out of combat).
- `GCDI.setup_dispel_overlay = gcdi_setup_dispel_overlay` is the only
  external export; there is no teardown export or A/B toggle anymore — see
  "What changed when this became permanent" below.

Preview mode (`GCDI.toggle_preview_mode`) still directly sets
`main_frame.dispelbar`'s color as a layout "sample" when entering preview,
and directly resets it to the idle-grey background color when leaving —
this is unrelated to detection (the overlay never runs during/because of
preview mode) and is just visual scaffolding for positioning the frame.

## What changed when this became permanent (2026-08-16)

The classic scan path was deleted outright, not just defaulted off:
`gcdi_scan_dispellable_by_index`, `gcdi_scan_dispellable_foreach`,
`player_has_dispellable_debuff_on_self`, `update_dispel_indicator`, the
`GCDI_AURAS_INSTANCE_API_UNSAFE` build-gate, `DISPEL_DEBUFF_FILTER`/
`DISPEL_DEBUFF_SCAN_MAX`, `gcdi_safe_can_dispel_flag`, and every call site
that invoked `update_dispel_indicator()` (ticker poll, `UNIT_AURA`,
`PLAYER_TARGET_CHANGED`, `PLAYER_ENTERING_WORLD`, `reposition_all`, the
initial post-load `C_Timer.After(1, ...)`, and preview-mode restore) are all
gone. `GCDI.configs.useNativeDispelBinding` no longer exists — there is
nothing to toggle. The Settings tab's "Use native engine dispel binding (A/B
test)" checkbox and the `/gcdopt nativedispel` slash command were removed;
the `showDispel` checkbox/slash-adjacent GCD-tab toggle (controls whether the
whole dispel row shows at all) is untouched and still relevant.
`gcdi_teardown_dispel_overlay` was also deleted — it existed solely to
support toggling native binding *off* back to the classic path, which is no
longer a state that exists.

`main_frame.dispelState` (a cached last-painted-state field the classic
scan used to short-circuit repaints) is gone too — nothing reads or writes
it anymore; the engine owns the purple/grey transition entirely and GCDI
never needs to know the current state to decide whether to repaint.

## Verified WoW API assumptions (12.x, not recalled from training data)

Carried over from the Phase 0 probe and the native stack-binding sibling
experiment (`CHANGE-TRACKER.md`'s "Native Stack Binding" entry, now deleted —
see `git show 563edc8:CHANGE-TRACKER.md`), both directly relevant here since
this overlay follows the same shape:

- Reads off an engine-bound `AuraContainer`/`AuraButton` after binding
  (`GetSize`, `IsShown`, `GetMinMaxValues`, etc.) can come back as
  secret/opaque values that poison any debug string built from them into
  `<SECRET>` with no error — confirmed in-game for the sibling stack-binding
  experiment. This is why `gcdi_setup_dispel_overlay`'s `initializeFrame`
  never reads state back off `button`/`container`; it only ever reports what
  it told the engine to be (a static debug string), per `CLAUDE.md`'s Secret
  Value rules.
- `CustomAuraContainerTemplate` is a genuine Blizzard stock template (used by
  other addons, e.g. Plater; documented on Warcraft Wiki), not something
  specific to this repo's own experiments.
- Native frame creation (`CreateFrame("AuraContainer", ...)`,
  `container:AddAuraSlot(...)`) must happen from a clean, non-tainted
  context — never from inside `UNIT_AURA` — and is blocked by
  `InCombatLockdown()`. This overlay only ever creates/registers from
  `PLAYER_ENTERING_WORLD` or the `PLAYER_REGEN_ENABLED` post-combat retry.

## Known gaps (flagged, not fixed here)

- **No live in-game re-verification after this cleanup pass.** The user
  confirmed the *feature itself* works in-game while it was still behind
  `configs.useNativeDispelBinding = true`. Removing the flag and the dead
  classic-scan code is a mechanical follow-up (deleting functions, call
  sites, and an options checkbox) verified only via `luajit -e
  "loadfile(...)"` compile checks and `luajit tests/runner.lua` (unaffected —
  this doesn't touch `Libs/`), not a fresh in-game pass. Do a `/reload` +
  quick sanity check (bar still shows, still turns purple/grey correctly, no
  Lua errors) before considering this fully done.
- **`showDispel` (GCD tab) unchecked + overlay bound is still untested.**
  `reposition_all` hides `main_frame.dispelbar` itself via `SetShown` when
  `showDispel` is off, but the overlay button is a sibling of `main_frame`
  (only *coordinate*-anchored to `dispelbar` via `SetAllPoints`, not parented
  to it) — its own shown state is engine-managed by the `AddAuraSlot`
  binding, not tied to `dispelbar`'s `Show`/`Hide`. Whether hiding
  `dispelbar` while the overlay is bound leaves a purple/grey square floating
  at that screen position with `showDispel` off is unverified; this repo's
  own Secret Value rules make it unclear whether it's even safe to force
  `Hide()` on an engine-bound button without fighting the engine's own
  visibility management (same unresolved question the sibling stack-binding
  experiment's buttons have, identical parenting shape). Test this
  combination explicitly before relying on `showDispel` to fully hide the
  row.
- **Combat-lockdown gated.** `gcdi_ensure_dispel_overlay_container` refuses
  to create the container while `InCombatLockdown()` is true. On a very
  first login/reload that happens to occur mid-combat, the overlay won't
  bind until `PLAYER_REGEN_ENABLED`'s retry fires — the classic bar will sit
  at whatever color it was left in (likely idle grey from a previous session,
  or the frame-creation default) until then.
