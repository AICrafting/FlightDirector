#!/usr/bin/env bash
#
# Provision the GitLab test target for flight adapter testing:
#   - verify token + project access
#   - ensure seed status labels exist
#   - ensure a .gitlab-ci.yml exists on the default branch (for ci watch/log)
#   - write .work/.flightdirector/config.json + secrets.json (gitignored)
#
# Creds resolve from a gitignored test-rig/gitlab/.env. Because this may run from a
# linked worktree (where that gitignored file does NOT exist), resolve it from the
# MAIN repo root first, then fall back to $RIG_DIR/.env. Never writes the token to a
# tracked file. Idempotent; safe to re-run.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"

say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"

# Resolve .env from the MAIN repo root (worktree-safe), then the rig dir.
MAIN="$(cd "$(git -C "$RIG_DIR" rev-parse --git-common-dir)/.." && pwd)"
# shellcheck disable=SC1091  # .env is gitignored; shellcheck can't follow it
if [ -f "$MAIN/test-rig/gitlab/.env" ]; then . "$MAIN/test-rig/gitlab/.env"
elif [ -f "$RIG_DIR/.env" ]; then . "$RIG_DIR/.env"; fi

TOKEN="${FLIGHT_GITLAB_TOKEN:-${LIGHTSPEED_GITLAB_TOKEN:-}}"
API="${FLIGHT_GITLAB_API:-${LIGHTSPEED_GITLAB_API:-https://gitlab.com/api/v4}}"
PROJECT="${FLIGHT_GITLAB_PROJECT:-${LIGHTSPEED_GITLAB_PROJECT:-}}"
[ -n "$TOKEN" ]   || die "no token — set FLIGHT_GITLAB_TOKEN in test-rig/gitlab/.env (gitignored). Scope: api."
[ -n "$PROJECT" ] || die "no project — set FLIGHT_GITLAB_PROJECT (group/project) in test-rig/gitlab/.env"

OWNER="${PROJECT%/*}"    # everything before the last '/'
REPO="${PROJECT##*/}"    # the final path segment
ENC="$(printf '%s' "$PROJECT" | jq -sRr @uri)"
PROJECT_API="$API/projects/$ENC"
H=(-H "PRIVATE-TOKEN: $TOKEN")

say "Verifying token…"
curl -fsS "${H[@]}" "$API/user" >/dev/null || die "token rejected by GET /user"
say "Verifying project access ($PROJECT)…"
DEFAULT_BRANCH="$(curl -fsS "${H[@]}" "$PROJECT_API" | jq -r '.default_branch // "main"')" \
  || die "cannot access project $PROJECT (check token scope/path)"

# Seed status labels (idempotent). name|color(#hex)|description
say "Ensuring seed labels…"
existing="$(curl -fsS "${H[@]}" "$PROJECT_API/labels?per_page=100" | jq -r '.[].name')"
seed_labels=(
  "status/in progress|#1d76db|In flight"
  "status/to test|#fbca04|Built, awaiting verification"
  "status/in review|#0e8a16|In review"
  "status/in qa|#5319e7|In QA"
  "rig|#ededed|test-rig artifact (safe to delete)"
)
for row in "${seed_labels[@]}"; do
  n="${row%%|*}"; rest="${row#*|}"; c="${rest%%|*}"; d="${rest#*|}"
  if grep -Fxq "$n" <<<"$existing"; then :; else
    curl -fsS "${H[@]}" -X POST "$PROJECT_API/labels" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg n "$n" --arg c "$c" --arg d "$d" '{name:$n,color:$c,description:$d}')" >/dev/null \
      && say "  created label '$n'"
  fi
done

# Ensure a .gitlab-ci.yml on the default branch so pipelines can run (idempotent).
say "Ensuring .gitlab-ci.yml on $DEFAULT_BRANCH…"
FP="$(printf '%s' ".gitlab-ci.yml" | jq -sRr @uri)"
if ! curl -fsS "${H[@]}" "$PROJECT_API/repository/files/$FP?ref=$DEFAULT_BRANCH" >/dev/null 2>&1; then
  content="$(cat "$RIG_DIR/gitlab-ci.yml")"
  curl -fsS "${H[@]}" -X POST "$PROJECT_API/repository/files/$FP" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg b "$DEFAULT_BRANCH" --arg c "$content" \
          '{branch:$b, content:$c, commit_message:"rig: add .gitlab-ci.yml"}')" >/dev/null \
    && say "  created .gitlab-ci.yml"
fi

# Write the gitignored workdir config. .work/ is its own throwaway git repo so the
# dispatcher resolves config from HERE (git rev-parse --git-common-dir).
say "Writing workdir config…"
rm -rf "$WORK"; mkdir -p "$WORK/.flightdirector"; git -C "$WORK" init -q
jq -n --arg api "$API" --arg o "$OWNER" --arg r "$REPO" '{
  code: { backend:"gitlab", owner:$o, repo:$r, api:$api,
          stages:[{name:"main", merge:"pr"}] },
  labels: { status: {
    "in-progress":"status/in progress",
    "to-test":"status/to test",
    "in-review":"status/in review",
    "in-qa":"status/in qa"
  } }
}' > "$WORK/.flightdirector/config.json"
jq -n --arg t "$TOKEN" '{ code: { token:$t } }' > "$WORK/.flightdirector/secrets.json"

say "Up. Workdir: $WORK  (project $PROJECT, default branch $DEFAULT_BRANCH)"
