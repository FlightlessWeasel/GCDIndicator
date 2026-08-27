# GCDIndicator

WoW addon: pixel-based HUD for GCD, combat/aggro/channeling state, class
resources, spell/item cooldowns, and buffs/DoTs (pandemic windows). See
`README.md` for user-facing features/commands.

## Companion project: `../AHK`

Sibling repo (AutoHotkey v2) reads this addon's HUD via **screen-pixel
sampling only** (no IPC/file/memory channel) to drive rotations. Any change
to `GCDI.configs` (size/barHeight/bgPadding/barSpacing), bar/row/column
layout, or indicator colors desyncs it **silently** (wrong reads, no crash).
Flag such changes to the user and check `../AHK/CLAUDE.md`'s mapping table.

The frame's on-screen anchor, the effective WoW UI Scale, and compactMode no
longer need hand-syncing: `GCDI.toggle_calibration_mode()` (`/gcdopt
calibrate`, or Options > Developer > Calibrate Position) shows a 4-swatch
marker — three fixed primaries the companion script measures the on-screen
*width* of (doubling as a UI-scale reading, not an assumed constant) plus a
white/gray swatch reflecting `configs.compactMode` — which the companion
script scans for to derive its own anchor/scale/compactMode constants. See
`GCDI.CALIBRATION_COLORS`/`GCDI.CALIBRATION_MODE_COLORS`/
`CALIBRATION_OFFSET_X`/`CALIBRATION_BORDER` in `GCDIndicator.lua` (search
"CALIBRATION MODE"). Changing the marker's size, colors, swatch count, or
offset from `main_frame.anchor` is exactly the kind of change that desyncs
the companion script's `lib/PositionCalibration.ahk` — treat it the same as
any other layout/color change above.

**Never mention AHK inside `GCDIndicator.lua` or `LibGCDI-Options.lua`** —
no code comments, no user-visible text (chat, tooltips, labels). Call it
"the companion script." This file may name AHK freely.

## Critical constraints

- **No live WoW client, no full addon test coverage.** `Libs/*` pure logic
  has real LuaJIT unit tests; `GCDIndicator.lua`/`LibGCDI-Options.lua`
  (frame-heavy, untested) are verified only via `check.js`/`scope.js` +
  manual reasoning. Nothing is confirmed working in-game unless a prior
  session said so — say so explicitly.
- **Don't modify third-party libs** (`Libs/LibDataBroker-1.1`,
  `LibDBIcon-1.0`, `CallbackHandler-1.0`, `LibStub`, `LibDispellable-1.0`).
  `LibGCDI-RangeCheck` is first-party (trimmed fork of LibRangeCheck-3.0,
  see `docs/librangecheck-trim.md`) — normal editing rules apply. `.toc`
  load order: LibStub-family → first-party `Lib*` → `GCDIndicator.lua` →
  Options UI.
- **Real-time over caching.** Combat-visible data (buffs, stacks, GCD,
  resources) must stay near-real-time. Don't trade display latency for perf
  (ticker rate, cross-frame caching, batching) without confirming with the user.
- **Secret Value system (WoW 12.1+).** Some aura/API fields (`applications`,
  `auraInstanceID`, some spell IDs) are opaque; comparing/printing/table-keying
  them errors or redacts to `<SECRET>`. `pcall`-wrap reads of secret-capable
  APIs, never `tostring()`/concat a possibly-secret value into debug output,
  pass secrets straight into UI setters designed for them instead of inspecting.
- **CDM frame pool is stateful/reused.** `C_CooldownViewer`'s `itemFramePool`
  reassigns frames across buffs/cooldownIDs. Any `cooldownID -> frame` cache
  (e.g. `cdmBuffFrames`) must check `frame.cooldownID` still matches, not
  trust a cached reference.
- **UNIT_AURA taint.** Must not run in the same call chain as Blizzard's CDM
  handlers — use `RegisterUnitEvent("UNIT_AURA", "player")` +
  `C_Timer.After(0, ...)`. Native `AuraContainer` frame creation needs a clean
  (non-`UNIT_AURA`) context and is blocked by `InCombatLockdown()` on most
  12.1 builds.

## Development directives

- **Evidence over memory.** Verify WoW APIs (existence/signature/return
  shape) via `wow-addon-architect` agent, `warcraft.wiki.gg`, or existing
  codebase patterns before depending on them — never from training-data
  recall. Secret Values make wrong assumptions fail silently, not loudly.
- **Test-first for `tests/`-covered code** (`LibGCDI-Catalog`,
  `LibGCDI-Profiles`, `LibGCDI-Range`, `LibGCDI`): write/update a failing
  spec, confirm it fails for the right reason, implement, confirm it passes.
  For `GCDIndicator.lua`/`LibGCDI-Options.lua`: `check.js`/`scope.js` + ask
  the user to test in-game; don't claim coverage that doesn't exist.
- **Mocks are the contract.** `tests/mocks/wow_api.lua` must reflect verified
  real API behavior. If addon code and mock disagree, fix the addon code —
  never loosen the mock to pass.
- **Document architecture changes in `docs/`** (not `.claude/rules/`, which
  auto-loads into every session) for any structural refactor/new subsystem/
  non-obvious pattern (what/why/how + API contracts), and add a one-line
  pointer to it from the relevant section here. In addition to
  `MISTAKES.md`.
- **Record deliberate design decisions as ADRs** in `docs/adr/` (see
  `docs/adr/README.md` for format) — one file per decision, numbered
  sequentially, covering the *why*/alternatives-considered for major
  structural choices. A topic doc under `docs/` can still hold the full
  implementation detail an ADR links to; the ADR itself is the decision
  record. This is separate from `MISTAKES.md`, which is per-incident
  postmortems, not decisions.

## Verification tooling

- **Static checks**: Node.js `luaparse`-based `check.js` (syntax) and
  `scope.js` (unresolved-globals diff) in a temp dir, not in this repo —
  recreate with `luaparse` if missing, don't skip. `scope.js` false-positives
  on table-constructor keys (`{ foo = 1 }`) as unresolved globals — check
  `TableKeyString` before treating a hit as real.
- **Unit tests**: `luajit tests/runner.lua` — hand-rolled
  `describe`/`it`/`assert` (no busted/luarocks, no C compiler available) vs.
  `Libs/LibGCDI-Catalog`, `LibGCDI-Profiles`, `LibGCDI-Range` under real Lua
  5.1 + `tests/mocks/wow_api.lua` stubs. Exits non-zero on failure. Extend
  the mock (verify against a real source first) before adding coverage. See
  `docs/test-harness.md` for why it's hand-rolled instead of busted, and
  exactly what is/isn't covered.

## Config vs. settings

- `GCDI.configs` — global, not per-profile, hardcoded defaults in
  `GCDIndicator.lua` (`debugMode`, `compactMode`). Not persisted unless
  explicitly wired to SavedVariables.
- `settings.*` — profile-based, persisted via `LibGCDI-Profiles`, per spec/character.
- `settings.resourceSettings[key]` must never default to enabled for a
  resource the player's class can't use, and load/save paths must re-enforce
  that — see `docs/resource-class-defaults.md`.

## Conventions

- Slash commands: `SlashCmdList["GCDOPT"]` in `GCDIndicator.lua`, follow
  `elseif msg == "..." then` style, prefix chat output with
  `|cff00ff00GCDIndicator:|r `. Add a matching Settings-tab control in
  `LibGCDI-Options.lua` for anything a user should toggle without a command.
- New experimental features: gate behind a `GCDI.configs` flag (see
  `compactMode`), wire both a slash command and Settings checkbox.
- Code should read clearly without comments — prefer clear naming and
  structure over explanatory comments. A comment earns its place only if the
  code it sits on is complex/non-obvious enough that a reader could not
  otherwise tell what it does (e.g. a hidden constraint like WoW taint rules
  that forces an odd control-flow shape). Never add a comment to justify
  *why* a design decision was made (rationale, alternatives considered,
  history) if the code reads the same without it — drop those. Don't bloat
  code or add excess whitespace to avoid a needed comment: if a concise
  comment is shorter than the bloat/whitespace needed to avoid it, add the
  comment, kept terse.
- Spells/Items/Buffs tab row reordering uses drag-and-drop
  (`add_row_drag_handle`), not per-row buttons — read `docs/options-drag-reorder.md`
  before touching row layout there or extending drag-and-drop to another tab.
- Options UI sections can be made collapsible via `add_section_header`'s
  `collapsible`/`sectionKey` params (Settings/Developer tabs so far) — read
  `docs/options-collapsible-sections.md` (see ADR 0009) before adding a new
  collapsible section or extending the pattern to another tab.
- Log mistakes in `MISTAKES.md` (repo root) whenever a change turns out
  wrong: what broke, root cause, fix — a few tight sentences each, not
  headers/prose. Create the file on first use.
