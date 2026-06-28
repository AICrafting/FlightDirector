#!/usr/bin/env bash
# Prove the dispatcher resolves config/secrets from inside a linked worktree
# (where the gitignored secrets file does NOT exist). Requires ./up.sh first.
set -uo pipefail
RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../lightspeed/scripts/lightspeed"
[ -f "$WORK/.lightspeed.json" ] || { echo "run ./up.sh first" >&2; exit 1; }

# Make WORK a real commit so we can add a worktree, then run the dispatcher from it.
git -C "$WORK" add -A >/dev/null 2>&1 || true
git -C "$WORK" -c user.email=rig@x -c user.name=rig commit -qm rig 2>/dev/null || true
rm -rf "$WORK/wt"; git -C "$WORK" worktree add -q wt -b wt-test
got="$( ( cd "$WORK/wt" && "$DISP" config '.code.stages[0].name' ) )"
git -C "$WORK" worktree remove --force wt 2>/dev/null || true

if [ -n "$got" ]; then printf '\033[32m✓ config read from worktree: %s\033[0m\n' "$got"
else printf '\033[31m✗ dispatcher could not resolve config from the worktree\033[0m\n'; exit 1; fi
