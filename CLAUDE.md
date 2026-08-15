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
- `.claude/rules/` — deep architecture/design-rationale docs for a subsystem
  (what/why/how, API contracts), as opposed to `CHANGE-TRACKER.md`'s
  toggle-specific revert steps or `OPTIMIZATION-NOTES.md`'s perf handoff log.
  Add or update an entry here for any structural refactor or new pattern, not
  just experimental toggles.
- `tests/` — Lua 5.1 (via LuaJIT) unit tests for the first-party `Libs/*`
  modules' pure logic, run with `luajit tests/runner.lua` from the repo root.
  See `.claude/rules/test-harness.md` for what it covers, what it doesn't
  (`GCDIndicator.lua`/`LibGCDI-Options.lua` are frame-heavy and untested here),
  and how to extend it.

## Companion project: AHK rotation scripts

`../AHK` (sibling repo, not part of this one) contains AutoHotkey v2 scripts
that read this addon's HUD via screen-pixel sampling (no IPC/file/memory
channel — pixels only) and drive class rotations from it. See `../AHK/CLAUDE.md`
for the full pixel protocol. The practical implication for this repo: **any
change to `GCDI.configs` (size/barHeight/bgPadding/barSpacing), bar/row/column
layout, or indicator colors (`RESOURCE_COLORS`, status/range/buff/charge
colors) desyncs the AHK scripts' pixel reads silently** (no crash — wrong
`CanCast`/stack reads instead). If you touch any of those, flag it to the user
and check `../AHK/CLAUDE.md`'s mapping table for what needs mirroring on the
AHK side.

**No mention of AHK inside `GCDIndicator.lua`/`Libs/LibGCDI-Options/LibGCDI-Options.lua`** —
not in code comments, and not in anything user-visible (chat `print()`
messages, `GameTooltip` text, button/checkbox labels, slash-command output).
Refer to it generically as "the companion script" instead. This constraint
is specific to those two Lua files; this file (`CLAUDE.md`) and
`CHANGE-TRACKER.md` are developer-only docs, never shipped or rendered
in-game, and may keep naming AHK explicitly (e.g. the section above).

## Critical constraints

- **No live WoW client in this dev environment, and no full addon test
  coverage.** A real Lua 5.1 interpreter (LuaJIT — see "Verification tooling")
  runs unit tests for the first-party `Libs/*` modules' pure logic, but
  `GCDIndicator.lua` and `LibGCDI-Options.lua` are frame/event-driven and have
  no mock coverage, so they're still verified only via `luaparse`-based
  syntax/scope checking plus manual reasoning. Nothing here has been visually
  confirmed working in-game unless a session's conversation history says a
  user tested it. Say so explicitly when reporting on unverified changes —
  don't imply in-game or test confirmation that didn't happen.
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

## Development directives

- **Evidence over memory.** Never assert a WoW API's existence, signature, or
  return-value semantics from training-data recall. Verify it — via the
  `wow-addon-architect` agent (`.claude/agents/wow-addon-architect.md`),
  `warcraft.wiki.gg`, or existing patterns already used elsewhere in this
  codebase — before writing code that depends on it. This matters more here
  than in most codebases because of the Secret Value system: a wrong
  assumption about an API's return shape doesn't always throw, it can just
  return `<SECRET>` and fail silently downstream.
- **Test-first for anything `tests/` can cover.** If a change touches
  `Libs/LibGCDI-Catalog`, `Libs/LibGCDI-Profiles`, `Libs/LibGCDI-Range`, or
  `Libs/LibGCDI`, add or update a failing spec under `tests/spec/` first, run
  `luajit tests/runner.lua` to confirm it fails for the right reason, then
  implement, then confirm it passes. For `GCDIndicator.lua` and
  `LibGCDI-Options.lua` — not covered by the harness (see "Critical
  constraints") — fall back to `check.js`/`scope.js` plus asking the user to
  test in-game; don't claim test coverage that doesn't exist.
- **Mocks are the contract, not a shortcut.** `tests/mocks/wow_api.lua` stubs
  must reflect real WoW API behavior, verified the same way as any other API
  claim (see "Evidence over memory" above). If addon code and a mock disagree,
  fix the addon code to match the mock's (verified) contract — never loosen
  the mock to make a shortcut pass.
- **Document architecture changes in `.claude/rules/`.** Any structural
  refactor, new subsystem, or non-obvious pattern gets a rules file explaining
  what/why/how and citing the relevant API contracts — see `test-harness.md`
  for the shape these should take. This is in addition to, not instead of,
  `CHANGE-TRACKER.md` (toggle-specific revert steps) and `MISTAKES.md`
  (postmortems).

## Verification tooling

Two layers, since there's no live WoW client:

- **Static syntax/scope checks** — a Node.js `luaparse`-based toolkit kept in
  a temp directory (not part of this repo): `check.js` (syntax) and `scope.js`
  (AST-based diff of unresolved globals, used before/after an edit to catch a
  missing `local`). If that toolkit isn't present in a new environment,
  recreate it with `luaparse` before relying on syntax checks — don't skip
  verification silently. `scope.js` has a known false-positive: it has no
  explicit case for Lua table constructors, so table-constructor key names
  (`{ foo = 1 }`) can get misreported as unresolved-global reads of `foo`.
  Before treating a `scope.js` diff hit as a real bug, check whether it's a
  `TableKeyString` key rather than an actual bare identifier use.
- **Real Lua 5.1 unit tests** — `luajit tests/runner.lua` from the repo root
  runs a hand-rolled `describe`/`it`/`assert` suite (no busted/luarocks: this
  machine has no C compiler, so `luafilesystem` — busted's dependency — can't
  be built; see `.claude/rules/test-harness.md` for the full story) against
  `Libs/LibGCDI-Catalog`, `Libs/LibGCDI-Profiles`, and `Libs/LibGCDI-Range`
  under real Lua 5.1 semantics, with WoW API stubs from
  `tests/mocks/wow_api.lua`. Exits non-zero on any failure. Extend
  `tests/mocks/wow_api.lua` (verifying each stub against a real source first)
  before adding coverage for code that touches more of the WoW API surface.

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
- Log mistakes in `MISTAKES.md` at the repo root: whenever a change turns out
  to be wrong (broke something, needed reverting, was based on a bad
  assumption, etc.), add an entry with **What happened**, **Root cause**, and
  **Prevention**. Create the file on first use.
