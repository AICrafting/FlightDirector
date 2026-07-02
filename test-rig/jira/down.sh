#!/usr/bin/env bash
#
# Surgical, marker-only teardown of Jira rig artifacts. Touches ONLY issues in
# the rig project whose summary starts with '[rig]': deletes them outright
# (DELETE /rest/api/3/issue/{key}). Removes .work/.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }

MAIN="$(cd "$(git -C "$RIG_DIR" rev-parse --git-common-dir)/.." && pwd)" || MAIN=""
ENV_FILE="$MAIN/test-rig/jira/.env"
# shellcheck disable=SC1090  # .env is gitignored; shellcheck can't follow it
[ -n "$MAIN" ] && [ -f "$ENV_FILE" ] && . "$ENV_FILE"

SITE="${LIGHTSPEED_JIRA_SITE:-}"; EMAIL="${LIGHTSPEED_JIRA_EMAIL:-}"
TOKEN="${LIGHTSPEED_JIRA_TOKEN:-}"; PROJECT="${LIGHTSPEED_JIRA_PROJECT:-}"
SITE="${SITE%/}"

if [ -n "$SITE" ] && [ -n "$EMAIL" ] && [ -n "$TOKEN" ] && [ -n "$PROJECT" ]; then
  AUTH=(-u "${EMAIL}:${TOKEN}")
  say "Deleting rig issues (summary starts '[rig]') in $PROJECT…"
  jql="project = \"$PROJECT\" AND summary ~ \"\\\\[rig\\\\]\" ORDER BY created DESC"
  keys="$(curl -fsS "${AUTH[@]}" -H "Content-Type: application/json" -X POST "$SITE/rest/api/3/search/jql" \
            --data "$(jq -n --arg j "$jql" '{jql:$j, maxResults:100, fields:["summary"]}')" \
          | jq -r '.issues[]? | select(.fields.summary | startswith("[rig]")) | .key')"
  for k in $keys; do
    curl -fsS "${AUTH[@]}" -X DELETE "$SITE/rest/api/3/issue/$k" >/dev/null 2>&1 && say "  deleted $k"
  done
fi

rm -rf "$WORK"
printf '\033[32m✓ Rig torn down (rig issues deleted, .work/ removed).\033[0m\n'
