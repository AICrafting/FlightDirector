#!/usr/bin/env bash
#
# Surgical, marker-only teardown of GitHub rig artifacts. Touches ONLY:
#   - issues carrying the 'rig' label  -> closed (GitHub REST can't delete issues)
#   - open PRs whose title starts '[rig]' -> closed
#   - branches named rig/*             -> deleted
# Leaves seed labels + the ci workflow in place (up.sh re-ensures them). Removes .work/.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }

if [ -f "$WORK/.lightspeed/config.json" ]; then
  API="$(jq -r '.code.api' "$WORK/.lightspeed/config.json")"
  OWNER="$(jq -r '.code.owner' "$WORK/.lightspeed/config.json")"
  REPO="$(jq -r '.code.repo' "$WORK/.lightspeed/config.json")"
  TOKEN="$(jq -r '.code.token' "$WORK/.lightspeed/secrets.json" 2>/dev/null || echo "")"
  REPO_API="$API/repos/$OWNER/$REPO"
  H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

  if [ -n "$TOKEN" ]; then
    say "Closing open PRs titled '[rig]…'…"
    # shellcheck disable=SC2046  # ids are whitespace-free integers; word-splitting is intended.
    for p in $(curl -fsS "${H[@]}" "$REPO_API/pulls?state=open&per_page=100" \
                 | jq -r '.[] | select(.title | startswith("[rig]")) | .number'); do
      curl -fsS "${H[@]}" -X PATCH "$REPO_API/pulls/$p" -d '{"state":"closed"}' >/dev/null && say "  closed PR #$p"
    done

    say "Closing open issues labelled 'rig'…"
    # shellcheck disable=SC2046  # ids are whitespace-free integers; word-splitting is intended.
    for i in $(curl -fsS "${H[@]}" "$REPO_API/issues?state=open&labels=rig&per_page=100" \
                 | jq -r '.[] | select(.pull_request | not) | .number'); do
      curl -fsS "${H[@]}" -X PATCH "$REPO_API/issues/$i" -d '{"state":"closed"}' >/dev/null && say "  closed issue #$i"
    done

    say "Deleting rig/* branches…"
    # shellcheck disable=SC2046  # ref names from the API are whitespace-free; word-splitting is intended.
    for ref in $(curl -fsS "${H[@]}" "$REPO_API/git/matching-refs/heads/rig/" | jq -r '.[].ref'); do
      curl -fsS "${H[@]}" -X DELETE "$REPO_API/git/${ref}" >/dev/null && say "  deleted ${ref#refs/}"
    done
  fi
fi

rm -rf "$WORK"
printf '\033[32m✓ Rig torn down (rig issues/PRs closed, rig/* branches deleted, .work/ removed).\033[0m\n'
