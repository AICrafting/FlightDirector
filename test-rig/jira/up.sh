#!/usr/bin/env bash
#
# Provision the Jira Cloud test target for flight adapter testing.
# Jira Cloud can't be containerized like Forgejo, so — like the github rig — this
# verifies access to a LIVE site and writes a gitignored workdir config.
#
#   - verify Basic auth (email:api_token) via GET /rest/api/3/myself
#   - verify project access
#   - write .work/.flightdirector/config.json + secrets.json (gitignored), with
#     issues.backend=jira and a throwaway `code` backend (issues-axis-only testing)
#
# Secrets come from a gitignored test-rig/jira/.env, resolved from the MAIN repo
# root (this may run inside a linked worktree where the .env isn't checked out).
# Never writes the token to a tracked file. Idempotent; safe to re-run.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"

say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"

# Resolve the MAIN repo root (parent of the common git dir) so the .env is found
# whether we run from the main checkout or a linked worktree.
MAIN="$(cd "$(git -C "$RIG_DIR" rev-parse --git-common-dir)/.." && pwd)" || die "not in a git repo"
ENV_FILE="$MAIN/test-rig/jira/.env"
# shellcheck disable=SC1090  # .env is gitignored; shellcheck can't follow it
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

SITE="${FLIGHT_JIRA_SITE:-${LIGHTSPEED_JIRA_SITE:-}}"
EMAIL="${FLIGHT_JIRA_EMAIL:-${LIGHTSPEED_JIRA_EMAIL:-}}"
TOKEN="${FLIGHT_JIRA_TOKEN:-${LIGHTSPEED_JIRA_TOKEN:-}}"
PROJECT="${FLIGHT_JIRA_PROJECT:-${LIGHTSPEED_JIRA_PROJECT:-}}"
[ -n "$SITE" ]    || die "no FLIGHT_JIRA_SITE — set it in $ENV_FILE (e.g. https://x.atlassian.net)"
[ -n "$EMAIL" ]   || die "no FLIGHT_JIRA_EMAIL — set it in $ENV_FILE"
[ -n "$TOKEN" ]   || die "no FLIGHT_JIRA_TOKEN — set it in $ENV_FILE (Atlassian API token)"
[ -n "$PROJECT" ] || die "no FLIGHT_JIRA_PROJECT — set it in $ENV_FILE (project key, e.g. KAN)"
SITE="${SITE%/}"

AUTH=(-u "${EMAIL}:${TOKEN}")

say "Verifying Basic auth (email:api_token)…"
who="$(curl -fsS "${AUTH[@]}" -H "Accept: application/json" "$SITE/rest/api/3/myself" | jq -r '.displayName // .accountId // empty')" \
  || die "auth rejected by GET /rest/api/3/myself (check email + API token)"
say "  authenticated as: $who"

say "Verifying project access ($PROJECT)…"
curl -fsS "${AUTH[@]}" -H "Accept: application/json" "$SITE/rest/api/3/project/$PROJECT" >/dev/null \
  || die "cannot access project '$PROJECT' (check the key and token permissions)"

# Write the gitignored workdir config. .work/ is its own throwaway git repo so the
# dispatcher resolves config from HERE (git rev-parse --git-common-dir), not the
# plugin's own repo. The `code` backend is a throwaway (never exercised here —
# this rig tests only the issues axis); status labels are space-free (Jira labels
# cannot contain spaces).
say "Writing workdir config…"
rm -rf "$WORK"; mkdir -p "$WORK/.flightdirector"; git -C "$WORK" init -q
jq -n --arg site "$SITE" --arg proj "$PROJECT" --arg email "$EMAIL" '{
  code:   { backend:"none", stages:[{name:"main", merge:"pr"}] },
  issues: { backend:"jira", api:$site, project:$proj, email:$email },
  labels: { status: {
    "in-progress":"status/in-progress",
    "to-test":"status/to-test",
    "in-review":"status/in-review",
    "in-qa":"status/in-qa"
  } }
}' > "$WORK/.flightdirector/config.json"
jq -n --arg t "$TOKEN" '{ issues: { token:$t } }' > "$WORK/.flightdirector/secrets.json"

say "Up. Workdir: $WORK  (site=$SITE project=$PROJECT)"
