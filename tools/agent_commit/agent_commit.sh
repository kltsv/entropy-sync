#!/usr/bin/env bash
#
# agent_commit.sh — commit a logical chunk authored by the agent.
#
#   agent_commit.sh "message" "model" [path ...]
#
# Author    = the agent: "Agent <model> <$AGENT_EMAIL>" (model lowercased).
# Co-author = the human maintainer, via a Co-authored-by trailer.
# Committer = whatever git is configured with (left untouched).
#
# With no paths it stages everything (`git add -A`, .gitignore respected);
# with paths it stages only those, so work can be split into logical commits.
#
# Overridable via env:
#   AGENT_EMAIL       (default: agent.ringov@gmail.com)
#   COMMIT_COAUTHOR   (default: Sergey Koltsov <uz.koltsov@gmail.com>)

set -euo pipefail

MSG="${1:?usage: agent_commit.sh \"message\" \"model\" [path ...]}"
MODEL_RAW="${2:?usage: agent_commit.sh \"message\" \"model\" [path ...]}"
shift 2

MODEL="$(printf '%s' "$MODEL_RAW" | tr '[:upper:]' '[:lower:]')"
AGENT_EMAIL="${AGENT_EMAIL:-agent.ringov@gmail.com}"
COMMIT_COAUTHOR="${COMMIT_COAUTHOR:-Sergey Koltsov <uz.koltsov@gmail.com>}"

if [ "$#" -gt 0 ]; then
  git add -- "$@"
else
  git add -A
fi

if git diff --cached --quiet; then
  echo "agent_commit: nothing staged — nothing to commit"
  exit 0
fi

git commit \
  --author="Agent ${MODEL} <${AGENT_EMAIL}>" \
  -m "${MSG}" \
  -m "Co-authored-by: ${COMMIT_COAUTHOR}"
