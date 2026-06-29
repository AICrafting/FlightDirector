#!/usr/bin/env bash
#
# Provision the GitHub test target for lightspeed adapter testing:
#   - verify token + repo access
#   - ensure seed status labels exist
#   - ensure .github/workflows/ci.yml exists (for ci watch/log)
#   - write .work/.lightspeed.json + .lightspeed.secrets.json (gitignored)
#
# Token: $LIGHTSPEED_GH_TOKEN, else a gitignored test-rig/github/.env sourced here.
# Never writes the token to a tracked file. Idempotent; safe to re-run.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
API="https://api.github.com"
OWNER="DaveWoodCom"
REPO="LightspeedTestTarget"
WORK="$RIG_DIR/.work"
REPO_API="$API/repos/$OWNER/$REPO"

say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"

# Resolve token.
# shellcheck disable=SC1091  # .env is gitignored; shellcheck can't follow it
[ -n "${LIGHTSPEED_GH_TOKEN:-}" ] || { [ -f "$RIG_DIR/.env" ] && . "$RIG_DIR/.env"; }
TOKEN="${LIGHTSPEED_GH_TOKEN:-}"
[ -n "$TOKEN" ] || die "no token — export LIGHTSPEED_GH_TOKEN or put it in test-rig/github/.env (gitignored). Scope: repo + workflow."

H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

say "Verifying token…"
curl -fsS "${H[@]}" "$API/user" >/dev/null || die "token rejected by GET /user"
say "Verifying repo access ($OWNER/$REPO)…"
curl -fsS "${H[@]}" "$REPO_API" >/dev/null || die "cannot access $OWNER/$REPO (check token scope/repo)"

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
mkdir -p "$WORK"
jq -n --arg api "$API" --arg o "$OWNER" --arg r "$REPO" '{
  code: { backend:"github", owner:$o, repo:$r, api:$api,
          stages:[{name:"main", merge:"pr"}] },
  labels: { status: {
    "in-progress":"status/in progress",
    "to-test":"status/to test",
    "in-review":"status/in review",
    "in-qa":"status/in qa"
  } }
}' > "$WORK/.lightspeed.json"
jq -n --arg t "$TOKEN" '{ code: { token:$t } }' > "$WORK/.lightspeed.secrets.json"

say "Up. Workdir: $WORK"
