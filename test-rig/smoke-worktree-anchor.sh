#!/usr/bin/env bash
# Backend-free regression test for the nested-worktree bug (issue #57).
#
# working-an-issue used to create the worktree with a bare relative path guarded
# only by the prose "run this from the repo root". The shell's cwd persists
# across calls, so starting issue B while still inside issue A's worktree put B
# *inside* A — git allows nested worktrees and prints no warning.
#
# This asserts two things:
#   1. the failure mode is real (the naive relative form nests), and
#   2. the ROOT= idiom the skill actually ships defeats it.
#
# The idiom is extracted from working-an-issue/SKILL.md rather than duplicated
# here, so the test fails if the shipped snippet drifts.
set -uo pipefail
RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$RIG_DIR/../flight/skills/working-an-issue/SKILL.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; exit 1; }
pass() { printf '\033[32m✓ %s\033[0m\n' "$1"; }

# The line the skill tells the model to run. If it stops existing, that IS the bug.
IDIOM="$(grep -m1 '^ROOT=' "$SKILL")" \
  || fail "no ROOT= anchor line in working-an-issue/SKILL.md — the fix for #57 was lost"

git init -q "$WORK/main"
git -C "$WORK/main" -c user.email=rig@x -c user.name=rig commit -q --allow-empty -m init
git -C "$WORK/main" branch -M develop
git -C "$WORK/main" worktree add -q ".worktrees/97-first" -b feature/97-first develop

# 1. Reproduce: naive relative path, run from inside the previous worktree.
( cd "$WORK/main/.worktrees/97-first" \
  && git worktree add -q ".worktrees/98-naive" -b feature/98-naive develop ) \
  || fail "setup: naive worktree add failed"
[ -d "$WORK/main/.worktrees/97-first/.worktrees/98-naive" ] \
  || fail "expected the naive form to nest, but it didn't — re-check the diagnosis"
pass "reproduced: relative path nests under the previous worktree"

# 2. The shipped idiom, run from the same (wrong) cwd, must land at the repo root.
( cd "$WORK/main/.worktrees/97-first" \
  && eval "$IDIOM" \
  && git -C "$ROOT" worktree add -q ".worktrees/99-anchored" -b feature/99-anchored develop ) \
  || fail "shipped idiom failed to create the worktree"

[ -d "$WORK/main/.worktrees/99-anchored" ] \
  || fail "anchored worktree did not land at the repo root"
[ -d "$WORK/main/.worktrees/97-first/.worktrees/99-anchored" ] \
  && fail "anchored worktree still nested — the ROOT= idiom is broken"
pass "anchored: shipped idiom lands at the repo root from a nested cwd"

# 3. Same idiom from a doubly-nested worktree (worst case) still finds the root.
got="$( cd "$WORK/main/.worktrees/97-first/.worktrees/98-naive" && eval "$IDIOM" && echo "$ROOT" )"
[ "$got" = "$WORK/main" ] || fail "ROOT resolved to '$got', expected '$WORK/main'"
pass "anchored: resolves the main root even from a doubly-nested worktree"
