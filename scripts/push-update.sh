#!/bin/bash
# Build, install, commit, and push Hermes Pong updates to GitHub
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MSG="${*:-Update Hermes Pong}"

bash "$ROOT/scripts/build-app.sh"
bash "$ROOT/scripts/install.sh"

if [[ ! -d .git ]]; then
  echo "Not a git repo yet. Run scripts/init-repo.sh first."
  exit 1
fi

git add -A
if git diff --cached --quiet; then
  echo "No code changes to commit (app reinstalled)."
else
  git commit -m "$MSG"
  git push -u origin HEAD
  echo "Pushed to GitHub."
fi

git status -sb
