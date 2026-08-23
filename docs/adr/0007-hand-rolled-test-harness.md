# 0007. Hand-rolled Lua 5.1 test harness instead of busted

Date: 2026-08-15
Status: Accepted

Full detail: [`docs/test-harness.md`](../test-harness.md)

## Context

The reference point for "normal" WoW addon testing (e.g. BetterBags) runs
real `busted` tests against Lua 5.1 with WoW API mocks. `busted` depends on
`luafilesystem`, a compiled C extension — this dev machine has no C compiler
and no admin rights for a system-wide toolchain install, confirmed directly
(`luarocks install luacheck` fails at `luafilesystem`'s build step with
`'gcc' is not recognized`), not assumed.

## Decision

LuaJIT 2.1 (installed via a single MSI, no compiler needed;
`_VERSION == "Lua 5.1"`, same semantics for everything these tests exercise
— the same exception BetterBags' own docs carve out) plus a ~90-line
hand-rolled `describe`/`it`/`assert*` framework
(`tests/framework.lua`/`tests/runner.lua`), no dependencies. Spec discovery
is a static list (`SPEC_FILES` in `runner.lua`), not a directory scan —
stock Lua 5.1 has no filesystem-listing API without the same `lfs` extension
that can't be built here. Scope is deliberately narrow: only the first-party
`Libs/*` modules that are pure table manipulation with no frame/widget
dependency (`LibGCDI-Catalog`, `LibGCDI-Profiles`, the settings-logic half
of `LibGCDI-Range`) — `GCDIndicator.lua` and `LibGCDI-Options.lua` are not
covered, verified only via `check.js`/`scope.js` static checks plus manual
reasoning and in-game testing.

## Consequences

- Runs and exits non-zero on failure with zero install friction beyond the
  one-time LuaJIT MSI — no build step, no admin rights needed, works on
  this machine.
- New spec files must be registered by hand in `SPEC_FILES`; forgetting this
  silently excludes a spec from the run rather than erroring.
- `GCDIndicator.lua` (~4500 lines) and `LibGCDI-Options.lua` (~3100 lines)
  have no automated test coverage at all — mocking `CreateFrame`, the update
  ticker, `C_CooldownViewer`, `UNIT_AURA`, and native `AuraContainer`
  bindings faithfully (especially the CDM frame-pool reuse semantics from
  ADR 0002 and Secret Value behavior from ADR 0001) is a substantially
  larger undertaking than the four `Libs/*` modules, and an inaccurate mock
  that addon code gets bent to satisfy would actively work against
  `CLAUDE.md`'s "mocks are the contract" rule. This is a known, accepted
  gap, not an oversight — extending coverage there is its own future
  decision requiring a deliberately planned mock surface.

## Alternatives considered

- **`busted` + LuaRocks, matching BetterBags.** Rejected: doesn't run on
  this machine without a C compiler, confirmed by direct attempt, not
  assumed.
- **No automated tests at all, rely entirely on static checks + manual/
  in-game verification.** Rejected for the `Libs/*` modules specifically —
  they're pure logic with real edge cases (`deepcopy` cycle-safety,
  serialize/deserialize round-trips) worth locking down mechanically; static
  syntax checking alone wouldn't catch a logic regression there.
