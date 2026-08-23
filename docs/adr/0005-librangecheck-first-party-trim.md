# 0005. First-party trimmed fork of LibRangeCheck-3.0

Date: 2026-08-19
Status: Accepted

Full detail: [`docs/librangecheck-trim.md`](../librangecheck-trim.md)

## Context

GCDIndicator vendored the third-party `LibRangeCheck-3.0` (upstream MIT,
~5000 lines, 75 public functions) but only ever called 3 of them
(`init`, `GetRange`, `GetSmartMaxChecker`). ~600 lines were dead weight
shipping in-game unused: the entire `--@do-not-package@` debug/measurement
block (upstream's own packager strips this; GCDIndicator doesn't use that
packager), the unused `Get*Checker` accessor family, dead-even-upstream
`UNIT_AURA` handling (never registered, so it can't fire), and several
zero-caller helpers.

## Decision

Fork it as `Libs/LibGCDI-RangeCheck/LibGCDI-RangeCheck.lua`, a first-party
file where normal editing rules apply (unlike the genuinely third-party libs
in `CLAUDE.md` — LibStub, CallbackHandler-1.0, LibDataBroker-1.1, etc.,
which stay untouched). Removed everything not in the real call graph,
verified via `codebase-memory` graph tracing (`trace_path` outbound from the
3 real entry points) cross-checked against `grep` by hand, since the graph
can't see WoW's dynamic `self[event](...)`/duck-typed dispatch. API surface
for the 3 methods GCDIndicator uses is unchanged — only the `LibStub` name
changed, from `"LibRangeCheck-3.0"` to `"LibGCDI-RangeCheck"`.

## Consequences

- ~600 fewer lines shipped and loaded, no behavior change for anything
  GCDIndicator actually uses.
- Diverges from upstream — future upstream bug fixes/improvements to
  `LibRangeCheck-3.0` won't automatically flow in; would need to be
  re-applied by hand against the trimmed fork.
- If a future feature needs a removed accessor (e.g. `GetFriendMinChecker`),
  it's recoverable from git history (`git log --diff-filter=D`) or by
  diffing against upstream directly, per the linked doc's "Re-diffing
  against upstream" section — not a dead end, just a deliberate one-time
  cost if it comes up.
- The persisted setting key `settings.gcdSettings.useLibRangeCheck` and the
  function name `TryRangeWithLibRangeCheck` in `LibGCDI-Range.lua` were
  deliberately *not* renamed to match — they're `LibGCDI-Profiles`-persisted
  SavedVariables keys, and renaming would silently reset existing users'
  toggle state for no functional benefit.

## Alternatives considered

- **Keep vendoring the full upstream file.** Simpler to stay in sync with
  upstream, but ships and parses ~600 lines of genuinely dead code on every
  load for no benefit.
- **Strip it down in place without renaming the `LibStub` key.** Would avoid
  updating the one call site in `LibGCDI-Range.lua`, but blurs the line
  between "third-party, don't touch" and "first-party, edit freely" that
  `CLAUDE.md`'s critical-constraints section otherwise draws clearly for
  every other vendored lib.
