#!/usr/bin/env bash
# Prove the dispatcher resolves config/secrets from inside a linked worktree
# (where the gitignored secrets file does NOT exist). Requires ./up.sh first.
set -uo pipefail
RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../lightspeed/scripts/lightspeed"
[ -f "$WORK/.lightspeed.json" ] || { echo "run ./up.sh first" >&2; exit 1; }

# Make WORK a real commit so we can add a worktree.
git -C "$WORK" add -A >/dev/null 2>&1 || true
git -C "$WORK" -c user.email=rig@x -c user.name=rig commit -qm rig >/dev/null 2>&1 || true

# Unique names so repeated runs never collide; clean up the worktree AND its
# branch on exit (success or failure), so this script is re-runnable.
WT="wt-$$"; BR="wt-test-$$"
cleanup() {
  git -C "$WORK" worktree remove --force "$WT" >/dev/null 2>&1 || true
  git -C "$WORK" branch -D "$BR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git -C "$WORK" worktree add -q "$WT" -b "$BR"
got="$( ( cd "$WORK/$WT" && "$DISP" config '.code.stages[0].name' ) )"

if [ -n "$got" ]; then printf '\033[32m✓ config read from worktree: %s\033[0m\n' "$got"
else printf '\033[31m✗ dispatcher could not resolve config from the worktree\033[0m\n'; exit 1; fi
