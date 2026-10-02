---
name: agent-commit
description: Commit completed work as the agent, in logical chunks, with the maintainer credited as co-author. Use after finishing a coherent unit of work that is in a known-good state.
---

# Agent commit

Commit the work you just finished, attributed to the agent. Always go through the
script — never run raw `git commit` / `git add`. The script handles author
attribution and the co-author trailer; doing it by hand loses that.

## When

Commit when a coherent unit of work is **finished and in a known-good state** —
e.g. a passing module, a self-contained harness change, a doc update. Do not
commit a half-written or broken tree (a failed build, a workflow that aborted
mid-run). Prefer **several small logical commits** over one large dump.

## How

From the repo root:

```
bash tools/agent_commit/agent_commit.sh "message" "<your-model>" [path ...]
```

- `<your-model>` — your own model short name in kebab-case, from the system prompt
  (e.g. `opus-4.8`). If unknown, use `unknown-agent`.
- Pass explicit `path` arguments to scope a commit to one logical chunk; omit them
  to stage everything currently uncommitted.

Run the script once per logical chunk. It stages, then commits with author
`Agent <model> <agent.ringov@gmail.com>` and a `Co-authored-by` trailer for the
maintainer. Generated mirrors (`.claude/`, `.codex/`, `.opencode/`, `.tdd/`) are
gitignored and won't be staged.

## Rules

- Never `git commit`/`git add` directly — always this script.
- Never commit a broken or half-finished tree.
- One commit per logical chunk; write a clear imperative message.
- Don't push unless asked.
