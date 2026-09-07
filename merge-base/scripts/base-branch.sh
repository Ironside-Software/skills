#!/usr/bin/env bash
# Resolve which branch to merge in: the open PR's base if the current branch has one,
# else the repo's default branch. Prints the branch name on stdout.
set -euo pipefail

base=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null) || true
if [ -z "${base:-}" ]; then
  base=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) || true
fi
if [ -z "${base:-}" ]; then
  base=$(git remote show origin | sed -n 's/.*HEAD branch: //p')
fi
[ -n "${base:-}" ] || { echo "could not resolve base branch (no PR, no gh, no origin/HEAD)" >&2; exit 1; }
echo "$base"
