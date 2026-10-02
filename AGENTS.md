# Entropy Sync

Independent public repository: `https://github.com/kltsv/entropy-sync`.
The repository root is also the Obsidian plugin's npm package.

## Source of truth

- `app/` contains framework-independent behavior and test specs.
- `src/` implements the desktop Obsidian plugin; `packages/` contains Dart engines.
- `SPEC.md` sidecars link implementations and tests to specs by name and digest.
- `python3 compile.py` is project compile: validate those links before changes
  and after regeneration. It is distinct from any agent harness compile.
- Change behavior in its spec first, then regenerate implementation and tests.
  Refresh digests only after verification. Do not add development-version
  migrations, deprecated names or compatibility shims.
- Use `AGENTS.md` for directory documentation. `README.md` belongs only here
  at the repository root.
- Do not use private agent memory or edit generated agent mirrors.
- Commit completed, verified work through `.agents/skills/agent-commit/SKILL.md`:
  `bash tools/agent_commit/agent_commit.sh "message" "model" [paths...]`.

## Delivery

BRAT installs `main.js`, `manifest.json`, `styles.css` from a versioned release.
Native binaries are assets of that same immutable release. Release assembly
embeds all supported OS/CPU checksums in the script. Tag names must equal the
manifest version. Public source starts with a clean independent Git history.

## Verify

See the root README for standalone commands. CI builds native engines on
macOS arm64/x64, Linux arm64/x64 and Windows x64, then assembles one BRAT script.
Generated engines, release artifacts, dependencies and local overrides are
ignored. Do not commit credentials, vault contents or dependency checkouts.
