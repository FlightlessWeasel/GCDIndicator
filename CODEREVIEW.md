# GCDIndicator Code Review & Fix Progress

**Date:** 2026-08-16
**Reviewer:** Codex, via `codex-rescue` (full-codebase review, dispatched by the
`.claude/skills/code-review` override — see that file for why/how heavy
reviews route to Codex instead of running in-context).
**Status:** Fixes complete — Batch 1 done, Batch 2 done (Codex hit its
usage limit mid-run partway through, resets Sep 15, 2026, but #3/#4 were
finished directly), Batch 3 done, Batch 4 done. All batches complete.

This supersedes an earlier, lower-confidence auto-generated `CODEREVIEW.md`
that was in this repo before this session — that content is gone, this is
the real one.

---

## How to resume

1. Check whether Codex quota has reset: `/codex:status`, or just try
   dispatching the next batch below via the `codex-rescue` agent (or
   `codex resume 01a00cf6-dd62-7da3-937c-a76b46e84eb2` to continue Batch 2's
   exact session instead of starting fresh).
2. Work through "Remaining work" in order — batches are intentionally scoped
   to be independently dispatchable to Codex (`--write --wait`), except
   Batch 2 which is already half-done (see below) and should be finished
   before moving to Batch 3.
3. After each batch: verify the diff yourself (`git diff --stat`), rerun
   `luajit tests/runner.lua` for anything touching `Libs/*`, and confirm
   `GCDIndicator.lua`/`LibGCDI-Options.lua` still parse
   (`luajit -e "loadfile('GCDIndicator.lua')"`) before trusting the agent's
   self-report — don't just accept the returned summary at face value.

---

## Remaining work

### Batch 2 (in progress) — finish items #3 and #4

- [x] #1 — Secret aura instance ID retained/compared outside pcall
      (`durationArmedFor` → `durationArmedGeneration` counter) — **done**
- [x] #2 — Debug slash commands (`/gcdopt buffs`, `buffdebug`, `cdm`) bypass
      secret-value safeguards — **done** (now pcall-wrapped, presence-only
      output; stack counts/spell IDs/names were dropped from debug output
      entirely rather than risk leaking a secret value — a behavior
      simplification worth knowing about, not just a safety wrap)
- [x] #3 — `update_dispel_indicator()` still called synchronously inside the
      `UNIT_AURA` handler (~line 3925), right after the correctly-deferred
      `schedule_update_all_buff_bars_after_aura()`. Needs to move into the
      same `C_Timer.After(0, ...)` deferred callback. — **done** (removed the
      redundant synchronous call; `schedule_update_all_buff_bars_after_aura`'s
      existing `C_Timer.After(0, ...)` callback already called
      `update_dispel_indicator()`)
- [x] #4 — `UNIT_AURA` is still only registered for `"player"`
      (`RegisterUnitEvent("UNIT_AURA", "player")`, line 4332). Target
      debuffs still rely on the 0.5s safety poll only. Needs:
      - `RegisterUnitEvent("UNIT_AURA", "player", "target")` — verified valid
        via warcraft.wiki.gg (`Frame:RegisterUnitEvent` supports up to 4
        units per call, added Patch 5.0.4).
      - An `arg1 == "target"` branch in the `UNIT_AURA` handler that defers
        (via `C_Timer.After(0, ...)`, never synchronous) a refresh of
        whatever function(s) drive the target-debuff bars — find these near
        the existing 0.5s poll code (~lines 1323, 4329, 4432).
      - A target-debuff refresh call added inside the existing
        `elseif event == "PLAYER_TARGET_CHANGED" then` branch (~line
        3903-3906), so switching targets doesn't show stale data from the
        previous target.
      — **done** (registration now includes `"target"`; the `UNIT_AURA`
      handler's `arg1 == "player" or arg1 == "target"` branch calls the same
      `schedule_update_all_buff_bars_after_aura()` deferred scheduler, which
      already drives both player and target-debuff bars via
      `update_all_buff_bars()`; `PLAYER_TARGET_CHANGED` now also calls it)

### Batch 3 — done: data-correctness bugs

- [x] #5 — Startup profile load path (~GCDIndicator.lua:4349) omits
  `profile.resourceSettings`/`profile.gcdSettings` that the normal
  `LibProfiles:LoadProfile` path (LibGCDI-Profiles.lua:188) does copy. Fix:
  reuse `LibProfiles:LoadProfile` for startup, or copy the two missing
  fields explicitly.
- [x] #9 — `GetEnabledOrdered()` (LibGCDI-Catalog.lua:119) is nondeterministic —
  appends unordered entries via `pairs()`, unlike `GetAllOrdered()` which
  alphabetizes. Test-first in `catalog_spec.lua` per repo convention.
- [x] #11 — Stale fallback range cache (LibGCDI-Range.lua:535) —
  `cachedFallbackInRange` isn't cleared on target change / unavailable
  reading, can show a stale green/red. Test-first in `range_spec.lua`.
- [x] #12 — Three separate profile-save code paths (LibGCDI-Options.lua:2559,
  2713) duplicate deep-copy/serialize logic instead of delegating to the
  shared `save_profile`/`LibGCDI-Profiles` path — collapse onto one.

### Batch 4 — cleanup, naming, config default

- [x] #6 — Redundant `rebuild_item_bars()` calls where `rebuild_spell_bars()`
  (GCDIndicator.lua:416) already covers it (extra call site: :3726).
- [x] #7 — Disabled-by-default native `AddAuraSlot` bindings accumulate across
  rebuilds (GCDIndicator.lua:1691, 1860) — already noted in
  `CHANGE-TRACKER.md`; remove and update that entry.
- [x] #8, #13 — "AHK" naming baked into shipped source
  (`ahk_string_escape`, `ahk_normalize_name`, `export_ahk_config` in
  GCDIndicator.lua:2927+; same pattern in LibGCDI-Options.lua:2539, 3435) —
  violates `CLAUDE.md`'s explicit no-AHK-mentions rule for these two files.
  Rename to generic "companion" terminology.
- [x] #14 — `GCDI.configs.compactMode` defaults to `false`
  (GCDIndicator.lua:18), but **all 11** shipped `../AHK/specs/*.ahk` profiles
  already default `ResolveCompactMode(true)` — confirmed via
  `../AHK/CLAUDE.md` ("every profile now defaults to `true`"). The addon
  default is the actual drift; flip it to `true` to match, and note the flip
  in `CHANGE-TRACKER.md` per the companion-project section (no AHK-side
  changes needed).

---

## Full original Codex review (reference)

No files were changed during the review itself. Codex did not run in-game
verification — no client available in this dev environment (see `CLAUDE.md`).

### GCDIndicator.lua

1. **Bug — Secret aura instance IDs compared directly** —
   `GCDIndicator.lua:1474`. `data.durationArmedFor ~= cdmFrame.auraInstanceID`
   compares an explicitly secret-capable value outside `pcall` and retains it
   for a later comparison, unlike the approved `~= nil` presence-check
   pattern. *(Fixed in Batch 2.)*

2. **Bug — Debug slash commands bypass secret-value safeguards** —
   `GCDIndicator.lua:4774, 4801, 4933`. `/gcdopt buffs` calls aura APIs
   without `pcall`, reads `applications`, and concatenates it into chat
   output; `/gcdopt buffdebug` calls a secret-capable aura API directly;
   `/gcdopt cdm` reads CDM spell IDs without sanitizing before concatenating
   into debug text. *(Fixed in Batch 2.)*

3. **Bug — `UNIT_AURA` directly scans aura state in Blizzard's handler
   chain** — `GCDIndicator.lua:3920`. The buff update is correctly deferred,
   but `update_dispel_indicator()` is called immediately afterward,
   synchronously, inside the `UNIT_AURA` call chain — contrary to the
   documented taint rule. *(Fixed in Batch 2.)*

4. **Bug — Target-debuff bars only refresh at the 2 Hz safety poll** —
   `GCDIndicator.lua:1323, 3921, 4329, 4432`. `UNIT_AURA` is registered only
   for `player`; target debuff activity/stacks fall back to the 0.5s poll —
   an uncalled-out latency tradeoff for combat-visible state. *(Fixed in
   Batch 2.)*

5. **Bug — Active-profile startup path omits resource and GCD settings** —
   `GCDIndicator.lua:4349`, vs. the full copy at
   `LibGCDI-Profiles.lua:188`. Active profile can load differently on login
   vs. selecting it in the UI. *(Fixed in Batch 3.)*

6. **Cleanup — Redundant full item-bar rebuilds** — `GCDIndicator.lua:416,
   3726`. `rebuild_spell_bars()` already calls `rebuild_item_bars()`, but
   several callers invoke both. *(Fixed in Batch 4.)*

7. **Cleanup — Disabled experimental native slots accumulate across
   rebuilds** — `GCDIndicator.lua:1691, 1860`. Already recorded in
   `CHANGE-TRACKER.md`; rebuild loses Lua references but doesn't remove
   registered native `AddAuraSlot` bindings. *(Fixed in Batch 4.)*

8. **Cleanup — Shipped-source terminology violates the repository
   constraint** — `GCDIndicator.lua:2927`. `CLAUDE.md` prohibits mentioning
   "AHK" in this file, including code comments; core contains exported
   function names/comments using it. *(Fixed in Batch 4.)*

### Libs/LibGCDI-Catalog/LibGCDI-Catalog.lua

9. **Bug — HUD ordering is nondeterministic for catalog entries absent from
   saved order** — `LibGCDI-Catalog.lua:119`. `GetEnabledOrdered()` appends
   unordered enabled entries via `pairs(catalog)`, unlike `GetAllOrdered()`,
   which alphabetizes them; risks desyncing the companion pixel layout from
   Options order. *(Fixed in Batch 3.)*

### Libs/LibGCDI-Profiles/LibGCDI-Profiles.lua

10. **Bug — Import deserialization executes attacker-controlled Lua** —
    `LibGCDI-Profiles.lua:91`. Import UI passed user-pasted text to
    `deserialize`, which ran `loadstring("return " .. str)`; an empty
    environment blocks global access but not resource exhaustion from
    well-formed-but-malicious input. *(Fixed in Batch 1 — replaced with a
    bounded, non-executing recursive-descent parser; test-first, 40/40 tests
    passing, no `loadstring`/`load`/`setfenv` remain in the file.)*

### Libs/LibGCDI-Range/LibGCDI-Range.lua

11. **Bug — Fallback range cache can show a stale range color** —
    `LibGCDI-Range.lua:535`. When the proxy range API returns `nil` and
    LibRangeCheck is disabled, code reuses `cachedFallbackInRange` from a
    prior sample — can retain a stale green/red after retargeting. *(Fixed in
    Batch 3.)*

### Libs/LibGCDI-Options/LibGCDI-Options.lua

12. **Cleanup — Three profile-save implementations can drift** —
    `LibGCDI-Options.lua:2559, 2713`. Save-confirmation callback and
    `do_save_profile` each duplicate deep-copy/serialization logic instead of
    calling the core's `save_profile` path. *(Fixed in Batch 3.)*

13. **Cleanup — Explicit terminology constraint violation through
    companion-export API names** — `LibGCDI-Options.lua:2539, 3435`. Same
    `CLAUDE.md` source-text restriction as #8. *(Fixed in Batch 4.)*

### Companion interaction

14. **Bug — Fresh addon and shipped spec scripts default to opposite compact
    layouts** — `GCDIndicator.lua:18`. Addon defaults `compactMode = false`;
    companion spec scripts (e.g. `AHK/specs/BrewmasterMonk.ahk:18`) default
    `ResolveCompactMode(true)`. Mismatch silently desyncs pixel reads on a
    fresh install. *(Fixed in Batch 4; confirmed all 11 AHK profiles default
    `true`, so the addon side is what changed.)*

### Reviewed without additional findings

`GCDIndicator.toc` load order, `GCDIndicator.xml`, `LibGCDI.lua`, test
framework/runner/mocks/specs, and the remaining Options UI paths.

---

## Session/job references

- Codex review session: `codex resume 01a00ce1-971a-7a40-a710-04a6df6c9086`
- Batch 1 (loadstring fix): completed, `Libs/LibGCDI-Profiles/LibGCDI-Profiles.lua`
  + `tests/spec/profiles_spec.lua` touched, 40/40 tests passing.
- Batch 2 (secret-value/taint fixes): partial — Codex session
  `01a00cf6-dd62-7da3-937c-a76b46e84eb2`, hit usage limit (resets Sep 15,
  2026) after completing #1 and #2. `GCDIndicator.lua` touched, still
  parses clean, only #3/#4 remain.
