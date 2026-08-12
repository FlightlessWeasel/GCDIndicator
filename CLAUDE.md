# GCDIndicator

A World of Warcraft addon: a compact, pixel-based HUD that tracks GCD, combat/aggro/
channeling state, class resources, spell/item cooldowns, and buffs/DoTs (with pandemic
windows). See `README.md` for the user-facing feature list and slash commands.

## Structure

- `GCDIndicator.xml` — defines `GCDINativeStackButtonTemplate` (experimental, see
  `CHANGE-TRACKER.md`). Loads before `GCDIndicator.lua`.
- `GCDIndicator.lua` (~4500 lines) — the addon core. Creates the `GCDI` global
  namespace, all bar/indicator frames, the update ticker, event handling, and
  slash commands (`/gcdopt`, `/gcdi`, `/gcdr`).
- `Libs/LibGCDI-Options/LibGCDI-Options.lua` (~3100 lines) — the options UI
  (tabs: GCD, Resources, Spells, Items, Buffs, Settings, Profiles). Depends on
  `GCDI` namespace existing first, hence loaded last in the `.toc`.
- `Libs/LibGCDI*` — first-party LibStub libraries, each independently
  versioned:
  - `LibGCDI` — frame drag/position persistence.
  - `LibGCDI-Catalog` — generic ordering logic shared by spell/item/buff catalogs.
  - `LibGCDI-Profiles` — per-spec/character profile save/load, deep-copy helpers.
  - `LibGCDI-Range` — range-check indicator logic (wraps `LibRangeCheck-3.0` and
    `C_Spell`/`IsActionInRange` fallbacks).
- `Libs/LibRangeCheck-3.0`, `LibDataBroker-1.1`, `LibDBIcon-1.0`,
  `CallbackHandler-1.0`, `LibStub`, `LibDispellable-1.0` — third-party
  libraries, don't modify.
- `GCDIndicator.toc` — load order matters: LibStub-family libs → first-party
  Lib* → `GCDIndicator.xml`/`.lua` (creates `GCDI` namespace) → Options UI.
- `OPTIMIZATION-NOTES.md` — running perf-work handoff doc, read/update it
  when touching the update ticker or per-frame work.
- `CHANGE-TRACKER.md` — tracks experimental, toggleable features (currently:
  native `AuraContainer`/`AddAuraSlot` stack binding) with exact revert steps,
  so they can be fully undone in a future session. Check it before touching
  anything it references; add an entry any time you gate new work behind a
  config toggle for A/B testing rather than committing to one approach.

## Critical constraints

- **No live WoW client or Lua interpreter in this dev environment.** All
  verification is static: `luaparse`-based syntax/scope checking (see
  "Verification tooling" below). Nothing here has been visually confirmed
  working in-game unless a session's conversation history says a user tested
  it. Say so explicitly when reporting on unverified changes — don't imply
  in-game confirmation that didn't happen.
- **Real-time over caching.** Combat-visible data (buffs, stacks, GCD state,
  resources) must read as close to real-time as possible. Do not trade
  display latency for performance without confirming with the user first —
  this includes ticker rate changes, caching aura/buff state across frames,
  and batching updates that are currently per-event.
- **Secret Value system (WoW 12.1+).** Many aura/API fields (`applications`,
  `auraInstanceID`, spell IDs on some paths) can be opaque "secret" userdata:
  comparing, printing, or table-keying them errors or silently redacts to
  `<SECRET>` in chat. Safe patterns already in use in this codebase:
  - `pcall`-wrap reads of secret-capable APIs.
  - Never `tostring()`/concatenate a value that might be secret into a debug
    string — build the message from only known-safe values.
  - Pass secret values straight into UI setters designed to accept them
    (`StatusBar:SetValue`, the native `SetApplicationBar`/`SetDurationBar`
    engine bindings) rather than inspecting them in Lua.
- **CDM (Blizzard Cooldown Manager) integration is stateful and reused.**
  `C_CooldownViewer`'s `itemFramePool` reassigns the same frame object to
  different buffs/cooldownIDs over a session. Any code caching a
  `cooldownID -> frame` mapping (see `cdmBuffFrames` in `GCDIndicator.lua`)
  must guard against staleness (check `frame.cooldownID` still matches) rather
  than trusting a cached reference indefinitely.
- **UNIT_AURA taint.** Addon code reacting to `UNIT_AURA` must not run in the
  same call chain as Blizzard's own CDM handlers. The existing pattern is
  `RegisterUnitEvent("UNIT_AURA", "player")` + deferred `C_Timer.After(0, ...)`.
  Frame creation for native `AuraContainer`-type frames must happen from a
  clean (non-tainted) context — never from inside a `UNIT_AURA` handler — and
  is blocked entirely by `InCombatLockdown()` on most 12.1 builds.

## Verification tooling

No WoW client available here — verification is syntax/scope checks only, run
from a Node.js `luaparse`-based toolkit kept in a temp directory (not part of
this repo): `check.js` (syntax) and `scope.js` (AST-based diff of unresolved
globals, used before/after an edit to catch a missing `local`). If that
toolkit isn't present in a new environment, recreate it with `luaparse` before
relying on syntax checks — don't skip verification silently.

`scope.js` has a known false-positive: it has no explicit case for Lua table
constructors, so table-constructor key names (`{ foo = 1 }`) can get
misreported as unresolved-global reads of `foo`. Before treating a `scope.js`
diff hit as a real bug, check whether it's a `TableKeyString` key rather than
an actual bare identifier use.

## Config vs. settings

Two distinct state stores — don't conflate them:
- `GCDI.configs` — global, not per-profile, plain Lua table with hardcoded
  defaults at the top of `GCDIndicator.lua` (e.g. `debugMode`,
  `useNativeStackBinding`). Not persisted across sessions unless explicitly
  wired to SavedVariables.
- `settings.*` — profile-based, persisted via `LibGCDI-Profiles`, per
  spec/character.

## Conventions

- Slash commands live under `SlashCmdList["GCDOPT"]` in `GCDIndicator.lua`;
  follow the existing `elseif msg == "..." then` branch style and print
  feedback with the `|cff00ff00GCDIndicator:|r ` chat prefix (see the
  existing `debug()` helper for the debug-mode-gated version).
  Add a matching options-UI control in `LibGCDI-Options.lua`'s Settings tab
  for anything a user should be able to toggle without a slash command.
- New experimental/toggleable features: gate behind a `GCDI.configs` flag
  (matching `useNativeStackBinding`'s precedent), wire both a slash command
  and a Settings-tab checkbox, and add a `CHANGE-TRACKER.md` entry with exact
  file/line touch points and revert steps.
