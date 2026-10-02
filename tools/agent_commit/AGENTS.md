# agent_commit

Commit a logical chunk of work attributed to the agent. Wraps `git commit` so the
author is the agent and the human maintainer is credited as co-author.

## CLI

```
bash tools/agent_commit/agent_commit.sh "message" "model" [path ...]
```

- **message** — commit message (imperative, concise).
- **model** — the agent's model short name in kebab-case (e.g. `opus-4.8`). Lowercased.
- **path ...** — optional. If given, only those paths are staged (`git add -- …`), so
  work can be split into several logical commits. With no paths, everything is staged
  (`git add -A`; `.gitignore` is respected, so generated mirrors and `.tdd/` are skipped).

Author becomes `Agent <model> <agent.ringov@gmail.com>`; a `Co-authored-by` trailer
credits the maintainer. The committer is left as the repo's git config. If nothing is
staged, the script exits cleanly without an empty commit.

Override via env: `AGENT_EMAIL`, `COMMIT_COAUTHOR`.
