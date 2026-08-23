# Architecture Decision Records

Records the *why* behind this repo's major structural decisions — one file
per decision, numbered sequentially, never renumbered or deleted once
merged. Format (lightweight MADR):

```
# NNNN. Title

Date: YYYY-MM-DD
Status: Accepted | Superseded by NNNN | Deprecated

## Context
What problem/constraint forced a decision.

## Decision
What was actually done.

## Consequences
What this buys us, and what it costs / what to watch for.

## Alternatives considered
What else was on the table and why it lost.
```

Full implementation detail (API contracts, verified WoW API assumptions,
exact call sites) stays in the topic doc under `docs/` that most of these
ADRs link to — the ADR itself is the decision record, not the reference
manual. When a decision is reversed, add a new ADR and mark the old one
Superseded; don't edit history in place.

This complements, not replaces, `MISTAKES.md` (repo root) — that file is
per-incident postmortems (what broke, root cause, fix), a different genre
from a deliberate design decision with alternatives that were weighed.

## Index

| # | Title | Status |
|---|-------|--------|
| [0001](0001-secret-value-taint-safe-access.md) | Secret Value / taint-safe API access pattern | Accepted |
| [0002](0002-cdm-buff-tracking-frame-pool-cache.md) | CDM buff/debuff tracking via a self-healing frame-pool cache | Accepted |
| [0003](0003-native-auracontainer-dispel-overlay.md) | Native AuraContainer/AddAuraSlot dispel overlay | Accepted |
| [0004](0004-class-appropriate-resource-defaults.md) | Class-appropriate resource bar defaults + profile-dirty indicator | Accepted |
| [0005](0005-librangecheck-first-party-trim.md) | First-party trimmed fork of LibRangeCheck-3.0 | Accepted |
| [0006](0006-options-drag-to-reorder.md) | Drag-to-reorder rows in the Options UI | Accepted |
| [0007](0007-hand-rolled-test-harness.md) | Hand-rolled Lua 5.1 test harness instead of busted | Accepted |
| [0008](0008-ultra-compact-mode.md) | Ultra-Compact Mode: machine-only minimum-footprint layout | Accepted |
