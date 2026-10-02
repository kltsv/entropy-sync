# app

Source of truth for this product's behavior, decomposed by module, described in plain English. Framework-agnostic. Each file here is a **module spec**.

Dart packages and the Obsidian TypeScript plugin implement these specs. If we ever add another target, the specs do not change.

## Format

Each module spec is a markdown file with frontmatter:

```yaml
---
name: <module-name>
description: <one-line>
status: draft | active | deprecated
---
```

The spec is identified by `name` — a stable identifier independent of file location. Implementation targets reference specs by this name, not by file path.

Body structure:

- **Purpose** — what this module is for
- **Inputs** — what it consumes
- **Outputs** — what it produces
- **Behavior** — rules, invariants, edge cases
- **Non-goals** — explicit list of things this module does *not* do
- **Examples** — concrete input → output pairs

## Spec → implementation linkage

Specs do **not** point to implementations. The dependency direction is reversed: each implementation directory contains a `SPEC.md` declaring which spec it realises:

```yaml
---
implements: <spec-name>
---
```

This means adding a new target (e.g., `swift/`) doesn't touch any spec. The new target's directories declare what they implement.

## Agnostic test-specs

Each behaviour spec has a companion **agnostic test-spec**: `app/<module>.tests.md`,
framework-agnostic test cases derived from the spec. It is the source of truth for
*tests*, the way the spec is the source of truth for *behaviour*. Frontmatter:

```yaml
---
tests: <module-name>   # the behaviour spec these cases exercise
---
```

A test-spec carries no `name:` of its own (it is not a behaviour spec). Each case
is written in strict **Arrange / Act / Assert** form with explicit setup, in plain
English, so any target can realise it. Framework test directories link back with a
`SPEC.md` containing `implements-tests: <module-name>` — the mirror of the
`implements:` linkage for code. `compile.py` validates both directions.

## When to edit

Edit the spec **before** the code. If you find yourself editing code without touching the corresponding spec, stop and use the `update-spec` skill.

## What does NOT live here

- Framework scaffolding (Flutter project files, native platform code, build configs) — implementation-only, lives in the target dir.
- Framework tests (Dart, etc.) — they live next to the code they verify. (The framework-*agnostic* test-spec, `<module>.tests.md`, does live here — see above.)
- Vault content (the user's actual markdown notes) — that's a separate repository.
