#!/usr/bin/env bash
#
# Surgical, marker-only teardown of GitLab rig artifacts. Touches ONLY:
#   - issues carrying the 'rig' label   -> closed (GitLab REST can't delete issues)
#   - open MRs whose title starts '[rig]' -> closed
#   - branches named rig/*              -> deleted
# Leaves seed labels + .gitlab-ci.yml in place (up.sh re-ensures them). Removes .work/.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }

if [ -f "$WORK/.flightdirector/config.json" ]; then
  API="$(jq -r '.code.api' "$WORK/.flightdirector/config.json")"
  OWNER="$(jq -r '.code.owner' "$WORK/.flightdirector/config.json")"
  REPO="$(jq -r '.code.repo' "$WORK/.flightdirector/config.json")"
  TOKEN="$(jq -r '.code.token' "$WORK/.flightdirector/secrets.json" 2>/dev/null || echo "")"
  ENC="$(printf '%s' "$OWNER/$REPO" | jq -sRr @uri)"
  PROJECT_API="$API/projects/$ENC"
  H=(-H "PRIVATE-TOKEN: $TOKEN")

  if [ -n "$TOKEN" ]; then
    say "Closing open MRs titled '[rig]…'…"
    # shellcheck disable=SC2046  # iids are whitespace-free integers; word-splitting is intended.
    for m in $(curl -fsS "${H[@]}" "$PROJECT_API/merge_requests?state=opened&per_page=100" \
                 | jq -r '.[] | select(.title | startswith("[rig]")) | .iid'); do
      curl -fsS "${H[@]}" -X PUT "$PROJECT_API/merge_requests/$m" -d 'state_event=close' >/dev/null && say "  closed MR !$m"
    done

    say "Closing open issues labelled 'rig'…"
    # shellcheck disable=SC2046  # iids are whitespace-free integers; word-splitting is intended.
    for i in $(curl -fsS "${H[@]}" "$PROJECT_API/issues?state=opened&labels=rig&per_page=100" \
                 | jq -r '.[].iid'); do
      curl -fsS "${H[@]}" -X PUT "$PROJECT_API/issues/$i" -d 'state_event=close' >/dev/null && say "  closed issue #$i"
    done

    say "Deleting rig/* branches…"
    # shellcheck disable=SC2046  # branch names from the API are whitespace-free; word-splitting is intended.
    for b in $(curl -fsS "${H[@]}" "$PROJECT_API/repository/branches?per_page=100" \
                 | jq -r '.[].name | select(startswith("rig/"))'); do
      enc="$(printf '%s' "$b" | jq -sRr @uri)"
      curl -fsS "${H[@]}" -X DELETE "$PROJECT_API/repository/branches/$enc" >/dev/null && say "  deleted $b"
    done
  fi
fi

rm -rf "$WORK"
printf '\033[32m✓ Rig torn down (rig issues/MRs closed, rig/* branches deleted, .work/ removed).\033[0m\n'
