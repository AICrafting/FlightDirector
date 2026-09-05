#!/usr/bin/env bash
#
# Bring up a disposable Forgejo and provision it for flight adapter testing:
#   - admin user, scoped API token, a test repo, seed status labels
#   - writes .flightdirector/config.json + .flightdirector/secrets.json into a gitignored workdir
#
# Re-runnable: tears down nothing, but creates a fresh token each run.
# shellcheck disable=SC2015  # 'cmd && say created || say exists' is intentional: say() always returns 0.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${RIG_PORT:-3000}"
API="http://localhost:${PORT}/api/v1"
USER="rig"
PASS="rigpass123"
EMAIL="rig@example.com"
REPO="widget"
WORK="$RIG_DIR/.work"

say() { printf '\033[36m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found"
command -v jq >/dev/null || die "jq not found"

say "Starting Forgejo (port $PORT)…"
( cd "$RIG_DIR" && RIG_PORT="$PORT" docker compose up -d )

say "Waiting for the API to come up…"
for i in $(seq 1 60); do
  if curl -fsS "$API/version" >/dev/null 2>&1; then break; fi
  [ "$i" = 60 ] && die "Forgejo did not become ready in time"
  sleep 1
done
say "Up: $(curl -fsS "$API/version")"

say "Ensuring admin user '$USER'…"
( cd "$RIG_DIR" && docker compose exec -T -u 1000 forgejo \
    forgejo admin user create --admin --username "$USER" --password "$PASS" \
    --email "$EMAIL" --must-change-password=false ) >/dev/null 2>&1 \
  && say "  created" || say "  already exists (ok)"

say "Creating a scoped API token…"
TOKEN_NAME="flight-rig-$(date +%s)"
TOKEN="$(curl -fsS -u "$USER:$PASS" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"$TOKEN_NAME\",\"scopes\":[\"write:repository\",\"write:issue\",\"write:user\",\"write:organization\",\"write:misc\"]}" \
  "$API/users/$USER/tokens" | jq -r '.sha1')"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "token creation failed"
say "  token: ${TOKEN:0:8}…"

say "Ensuring repo '$USER/$REPO'…"
curl -fsS -u "$USER:$PASS" -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"$REPO\",\"auto_init\":true,\"default_branch\":\"main\"}" \
  "$API/user/repos" >/dev/null 2>&1 && say "  created" || say "  already exists (ok)"

say "Seeding status labels…"
for spec in "status/in progress:#fbca04" "status/to test:#0e8a16" "status/blocked:#b60205" "status/review:#5319e7" "status/qa:#006b75" "bug:#d73a4a"; do
  name="${spec%%:*}"; color="${spec##*:}"
  curl -fsS -H "Authorization: token $TOKEN" -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$name" --arg c "$color" '{name:$n,color:$c}')" \
    "$API/repos/$USER/$REPO/labels" >/dev/null 2>&1 && printf '  + %s\n' "$name" || printf '  · %s (exists)\n' "$name"
done

say "Writing config into workdir ($WORK)…"
rm -rf "$WORK"; mkdir -p "$WORK/.flightdirector"; git -C "$WORK" init -q
jq -n --arg api "$API" --arg owner "$USER" --arg repo "$REPO" '{
  code: { backend:"forgejo", owner:$owner, repo:$repo, api:$api,
          stages:[ { name:"main", merge:"pr" } ] },
  labels: { status: {
    "in-progress":"status/in progress", "to-test":"status/to test", "blocked":"status/blocked", "review":"status/review", "qa":"status/qa"
  } }
}' > "$WORK/.flightdirector/config.json"
jq -n --arg t "$TOKEN" '{ code: { token:$t } }' > "$WORK/.flightdirector/secrets.json"

cat <<EOF

$(printf '\033[32m✓ Rig ready.\033[0m')
  Web:    http://localhost:$PORT/    (login: $USER / $PASS)
  API:    $API
  Repo:   $USER/$REPO
  Workdir:$WORK   (git repo with .flightdirector/config.json + secrets)

Run the smoke tests:   ./smoke.sh
Drive the adapters by hand, e.g.:
  ( cd "$WORK" && "$RIG_DIR/../../flight/scripts/flight" issues list )
Tear it all down:      ./down.sh
EOF
