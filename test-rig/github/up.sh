#!/usr/bin/env bash
#
# Provision the GitHub test target for flight adapter testing:
#   - verify token + repo access
#   - ensure seed status labels exist
#   - ensure .github/workflows/ci.yml exists (for ci watch/log)
#   - write .work/.flightdirector/config.json + .flightdirector/secrets.json (gitignored)
#
# Target + token come from the environment or a gitignored test-rig/github/.env
# (see .env.example): FLIGHT_GH_REPO=owner/repo, FLIGHT_GH_TOKEN, optional FLIGHT_GH_API.
# Nothing is hard-coded here — every contributor points the rig at their own throwaway repo.
# Never writes the token to a tracked file. Idempotent; safe to re-run.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"

say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"

# Resolve .env from the MAIN repo root (worktree-safe), then the rig dir. Values already
# exported in the shell win over the file (captured before sourcing, restored after).
MAIN="$(cd "$(git -C "$RIG_DIR" rev-parse --git-common-dir)/.." && pwd)"
_env_token="${FLIGHT_GH_TOKEN:-${LIGHTSPEED_GH_TOKEN:-}}"; _env_api="${FLIGHT_GH_API:-}"; _env_repo="${FLIGHT_GH_REPO:-}"
# shellcheck disable=SC1091  # .env is gitignored; shellcheck can't follow it
if [ -f "$MAIN/test-rig/github/.env" ]; then . "$MAIN/test-rig/github/.env"
elif [ -f "$RIG_DIR/.env" ]; then . "$RIG_DIR/.env"; fi

TOKEN="${_env_token:-${FLIGHT_GH_TOKEN:-${LIGHTSPEED_GH_TOKEN:-}}}"
API="${_env_api:-${FLIGHT_GH_API:-https://api.github.com}}"
TARGET="${_env_repo:-${FLIGHT_GH_REPO:-}}"
[ -n "$TOKEN" ]  || die "no token — set FLIGHT_GH_TOKEN in test-rig/github/.env (gitignored). Scope: repo + workflow."
[ -n "$TARGET" ] || die "no target repo — set FLIGHT_GH_REPO=owner/repo in test-rig/github/.env (a throwaway repo the rig may write to)"
case "$TARGET" in
  */*) ;;
  *) die "FLIGHT_GH_REPO must be owner/repo (got '$TARGET')" ;;
esac
OWNER="${TARGET%%/*}"
REPO="${TARGET#*/}"
REPO_API="$API/repos/$OWNER/$REPO"

H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

say "Verifying token + repo access ($OWNER/$REPO)…"
curl -fsS "${H[@]}" "$REPO_API" >/dev/null || die "cannot access $OWNER/$REPO (token rejected, or wrong scope/repo)"

# Seed status labels (idempotent). name|color(bare hex)|description
say "Ensuring seed labels…"
seed_labels=(
  "status/in progress|1d76db|In flight"
  "status/to test|fbca04|Built, awaiting verification"
  "status/in review|0e8a16|In review"
  "status/in qa|5319e7|In QA"
  "rig|ededed|test-rig artifact (safe to delete)"
)
for row in "${seed_labels[@]}"; do
  n="${row%%|*}"; rest="${row#*|}"; c="${rest%%|*}"; d="${rest#*|}"
  if curl -fsS "${H[@]}" "$REPO_API/labels/$(printf '%s' "$n" | jq -sRr @uri)" >/dev/null 2>&1; then
    :
  else
    curl -fsS "${H[@]}" -X POST "$REPO_API/labels" \
      -d "$(jq -n --arg n "$n" --arg c "$c" --arg d "$d" '{name:$n,color:$c,description:$d}')" >/dev/null \
      && say "  created label '$n'"
  fi
done

# Ensure the CI workflow exists on the default branch (idempotent).
say "Ensuring .github/workflows/ci.yml…"
if ! curl -fsS "${H[@]}" "$REPO_API/contents/.github/workflows/ci.yml" >/dev/null 2>&1; then
  content_b64="$(base64 < "$RIG_DIR/workflows/ci.yml" | tr -d '\n')"
  curl -fsS "${H[@]}" -X PUT "$REPO_API/contents/.github/workflows/ci.yml" \
    -d "$(jq -n --arg m "rig: add ci workflow" --arg c "$content_b64" '{message:$m, content:$c}')" >/dev/null \
    && say "  created .github/workflows/ci.yml"
fi

# Write the gitignored workdir config.
say "Writing workdir config…"
# .work/ is its own throwaway git repo so the dispatcher resolves config from HERE
# (git rev-parse --git-common-dir) instead of walking up to the plugin's own repo.
rm -rf "$WORK"; mkdir -p "$WORK/.flightdirector"; git -C "$WORK" init -q
jq -n --arg api "$API" --arg o "$OWNER" --arg r "$REPO" '{
  code: { backend:"github", owner:$o, repo:$r, api:$api,
          stages:[{name:"main", merge:"pr"}] },
  labels: { status: {
    "in-progress":"status/in progress",
    "to-test":"status/to test",
    "in-review":"status/in review",
    "in-qa":"status/in qa"
  } }
}' > "$WORK/.flightdirector/config.json"
jq -n --arg t "$TOKEN" '{ code: { token:$t } }' > "$WORK/.flightdirector/secrets.json"

say "Up. Workdir: $WORK  (repo $OWNER/$REPO)"
