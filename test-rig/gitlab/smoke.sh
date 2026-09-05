#!/usr/bin/env bash
#
# Exercise the live GitLab adapter verbs against the rig target and assert behavior.
# Requires ./up.sh to have run first. Everything created is marker-tagged ([rig] title
# + 'rig' label) so ./down.sh can clean up exactly its own artifacts.
# shellcheck disable=SC2015  # 'cond && ok || no' is intentional: ok() returns 0.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../flight/scripts/flight"
[ -f "$WORK/.flightdirector/config.json" ] || { echo "no workdir config — run ./up.sh first" >&2; exit 1; }

API="$(jq -r '.code.api' "$WORK/.flightdirector/config.json")"
OWNER="$(jq -r '.code.owner' "$WORK/.flightdirector/config.json")"
REPO="$(jq -r '.code.repo' "$WORK/.flightdirector/config.json")"
TOKEN="$(jq -r '.code.token' "$WORK/.flightdirector/secrets.json")"
ENC="$(printf '%s' "$OWNER/$REPO" | jq -sRr @uri)"
PROJECT_API="$API/projects/$ENC"
H=(-H "PRIVATE-TOKEN: $TOKEN")
DEFAULT_BRANCH="$(curl -fsS "${H[@]}" "$PROJECT_API" | jq -r '.default_branch // "main"')"
TS="$(date -u +%Y%m%d%H%M%S)"

lsp() { ( cd "$WORK" && "$DISP" "$@" ); }
pass=0; fail=0
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1)); }
no() { printf '\033[31m  ✗ %s\033[0m  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "── issues create / list / get ──"
N="$(lsp issues create --title "[rig] smoke $TS" --body "hello body" --label rig)"
[[ "$N" =~ ^[0-9]+$ ]] && ok "create returns numeric iid ($N)" || no "create returns numeric iid" "got '$N'"

OUT="$(lsp issues list)"
grep -q "\[rig\] smoke $TS" <<<"$OUT" && ok "list shows the new issue" || no "list shows the new issue" "$OUT"
cols="$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')"
[ "$cols" = 3 ] && ok "list rows are 3-col TSV" || no "list rows are 3-col TSV" "got $cols cols"

GET="$(lsp issues get --number "$N")"
grep -q "\[rig\] smoke $TS" <<<"$GET" && ok "get returns title line" || no "get returns title line"
grep -q "hello body" <<<"$GET" && ok "get returns body" || no "get returns body"

echo "── labels resolve ──"
id="$(lsp labels resolve --name "status/to test" | awk -F'\t' '{print $2}')"
[[ "$id" =~ ^[0-9]+$ ]] && ok "resolve returns name⇥id ($id)" || no "resolve returns name⇥id" "got '$id'"
empty="$(lsp labels resolve --name "no-such-label" | awk -F'\t' '{print $2}')"
[ -z "$empty" ] && ok "unknown label resolves to empty id" || no "unknown label resolves to empty id" "got '$empty'"

echo "── set-status (single-status invariant) ──"
lsp issues set-status --number "$N" --status in-progress
lsp issues set-status --number "$N" --status to-test
LBLS="$(curl -fsS "${H[@]}" "$PROJECT_API/issues/$N" | jq -r '(.labels // []) | map(select(startswith("status/"))) | sort | join(",")')"
[ "$LBLS" = "status/to test" ] && ok "only the latest status label remains ($LBLS)" \
  || no "only the latest status label remains" "got '$LBLS'"

echo "── comment / comments / close ──"
lsp issues comment --number "$N" --body "rig comment" && ok "comment exits 0" || no "comment exits 0"
CMTS="$(lsp issues comments --number "$N")"
grep -q "rig comment" <<<"$CMTS" && ok "comments returns the posted body" || no "comments returns the posted body" "$CMTS"
head -1 <<<"$CMTS" | grep -q $'\t' && ok "comments header is author⇥timestamp TSV" || no "comments header is TSV" "$(head -1 <<<"$CMTS")"
lsp issues close --number "$N" && ok "close exits 0" || no "close exits 0"

echo "── pr (MR) open / merge (rig branches off default; default untouched) ──"
BASE="rig/$TS-base"; HEAD="rig/$TS-head"
for b in "$BASE" "$HEAD"; do
  curl -fsS "${H[@]}" -X POST "$PROJECT_API/repository/branches?branch=$(printf '%s' "$b" | jq -sRr @uri)&ref=$DEFAULT_BRANCH" >/dev/null
done
curl -fsS "${H[@]}" -X POST "$PROJECT_API/repository/files/$(printf '%s' "rig-$TS.txt" | jq -sRr @uri)" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg b "$HEAD" --arg c "rig $TS" '{branch:$b, content:$c, commit_message:"[rig] commit"}')" >/dev/null
HEAD_SHA="$(curl -fsS "${H[@]}" "$PROJECT_API/repository/branches/$(printf '%s' "$HEAD" | jq -sRr @uri)" | jq -r '.commit.id')"
MR="$(lsp pr open --head "$HEAD" --base "$BASE" --title "[rig] pr $TS" --body "rig mr")"
mrnum="$(awk -F'\t' '{print $1}' <<<"$MR")"
[[ "$mrnum" =~ ^[0-9]+$ ]] && ok "pr open returns number⇥url ($mrnum)" || no "pr open returns number⇥url" "got '$MR'"

# GitLab computes MR mergeability asynchronously; retry briefly.
merged=0
for _ in $(seq 1 10); do
  if lsp pr merge --number "$mrnum" --strategy squash 2>/dev/null; then merged=1; break; fi
  sleep 2
done
[ "$merged" = 1 ] && ok "pr merge exits 0" || no "pr merge exits 0"

echo "── ci watch (the seeded pipeline on the rig push) ──"
LINES="$(cd "$WORK" && "$DISP" ci watch --sha "$HEAD_SHA" --timeout 150 2>&1 || true)"
if grep -qE "ci runs=[0-9]+ " <<<"$LINES"; then
  ok "ci watch streams aggregate status lines"
  grep -q "status=success" <<<"$LINES" && ok "ci watch reaches success" \
    || printf '\033[33m  ⚠ ci watch ran but no success verdict (soft — pipeline may fail/skip)\033[0m\n'
else
  printf '\033[33m  ⚠ ci watch produced no pipeline line (soft — gitlab.com shared runners may be unavailable for this project)\033[0m\n'
  printf '\033[33m    %s\033[0m\n' "$(head -1 <<<"$LINES")"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
