#!/usr/bin/env bash
#
# Exercise the live GitHub adapter verbs against the rig target and assert behavior.
# Requires ./up.sh to have run first. Everything created is marker-tagged ([rig] title
# + 'rig' label) so ./down.sh can clean up exactly its own artifacts.
# shellcheck disable=SC2015  # 'cond && ok || no' is intentional: ok() returns 0.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../lightspeed/scripts/lightspeed"
[ -f "$WORK/.lightspeed.json" ] || { echo "no workdir config — run ./up.sh first" >&2; exit 1; }

API="$(jq -r '.code.api' "$WORK/.lightspeed.json")"
OWNER="$(jq -r '.code.owner' "$WORK/.lightspeed.json")"
REPO="$(jq -r '.code.repo' "$WORK/.lightspeed.json")"
TOKEN="$(jq -r '.code.token' "$WORK/.lightspeed.secrets.json")"
REPO_API="$API/repos/$OWNER/$REPO"
H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
TS="$(date -u +%Y%m%d%H%M%S)"

lsp() { ( cd "$WORK" && "$DISP" "$@" ); }
pass=0; fail=0
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1)); }
no() { printf '\033[31m  ✗ %s\033[0m  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "── issues create / list / get ──"
N="$(lsp issues create --title "[rig] smoke $TS" --body "hello body" --label rig)"
[[ "$N" =~ ^[0-9]+$ ]] && ok "create returns numeric id ($N)" || no "create returns numeric id" "got '$N'"

OUT="$(lsp issues list)"
grep -q "\[rig\] smoke $TS" <<<"$OUT" && ok "list shows the new issue" || no "list shows the new issue"
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
LBLS="$(curl -fsS "${H[@]}" "$REPO_API/issues/$N" | jq -r '[.labels[].name] | map(select(startswith("status/"))) | sort | join(",")')"
[ "$LBLS" = "status/to test" ] && ok "only the latest status label remains ($LBLS)" \
  || no "only the latest status label remains" "got '$LBLS'"

echo "── comment / close ──"
lsp issues comment --number "$N" --body "rig comment" && ok "comment exits 0" || no "comment exits 0"
lsp issues close --number "$N" && ok "close exits 0" || no "close exits 0"

echo "── pr open / merge (rig branches off main; main untouched) ──"
MAIN_SHA="$(curl -fsS "${H[@]}" "$REPO_API/git/ref/heads/main" | jq -r '.object.sha')"
[[ "$MAIN_SHA" =~ ^[0-9a-f]{40}$ ]] && ok "read main sha for rig branch setup" || no "could not read main sha — pr/ci setup will fail" "$MAIN_SHA"
BASE="rig/$TS-base"; HEAD="rig/$TS-head"
for b in "$BASE" "$HEAD"; do
  curl -fsS "${H[@]}" -X POST "$REPO_API/git/refs" \
    -d "$(jq -n --arg r "refs/heads/$b" --arg s "$MAIN_SHA" '{ref:$r, sha:$s}')" >/dev/null
done
curl -fsS "${H[@]}" -X PUT "$REPO_API/contents/rig-$TS.txt" \
  -d "$(jq -n --arg m "[rig] commit $TS" --arg c "$(printf 'rig %s' "$TS" | base64 | tr -d '\n')" --arg b "$HEAD" \
        '{message:$m, content:$c, branch:$b}')" >/dev/null
HEAD_SHA="$(curl -fsS "${H[@]}" "$REPO_API/git/ref/heads/$HEAD" | jq -r '.object.sha')"
PR="$(lsp pr open --head "$HEAD" --base "$BASE" --title "[rig] pr $TS" --body "rig pr")"
prnum="$(awk -F'\t' '{print $1}' <<<"$PR")"
[[ "$prnum" =~ ^[0-9]+$ ]] && ok "pr open returns number⇥url ($prnum)" || no "pr open returns number⇥url" "got '$PR'"
lsp pr merge --number "$prnum" --strategy squash && ok "pr merge exits 0" || no "pr merge exits 0"

echo "── ci watch (the seeded workflow on the rig push) ──"
LINES="$(timeout 180 bash -c "cd '$WORK' && '$DISP' ci watch --sha '$HEAD_SHA'" || true)"
grep -qE "task-[0-9]+ status=" <<<"$LINES" && ok "ci watch streams task status lines" || no "ci watch streams task status lines" "$LINES"
if grep -q "status=completed" <<<"$LINES"; then
  ok "ci watch reaches completed"
else
  printf '\033[33m  ⚠ ci watch did not reach completed (soft — Actions may be slow)\033[0m\n'
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
