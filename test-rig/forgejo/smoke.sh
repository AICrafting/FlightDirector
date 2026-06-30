#!/usr/bin/env bash
#
# Exercise the live Forgejo adapter verbs against the rig and assert behavior.
# Requires ./up.sh to have run first.
# shellcheck disable=SC2015  # 'cond && ok || no' is intentional: ok() always returns 0, so no() only runs when cond fails.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../lightspeed/scripts/lightspeed"
[ -f "$WORK/.lightspeed/config.json" ] || { echo "no workdir config — run ./up.sh first" >&2; exit 1; }

API="$(jq -r '.code.api' "$WORK/.lightspeed/config.json")"
OWNER="$(jq -r '.code.owner' "$WORK/.lightspeed/config.json")"
REPO="$(jq -r '.code.repo' "$WORK/.lightspeed/config.json")"
TOKEN="$(jq -r '.code.token' "$WORK/.lightspeed/secrets.json")"
REPO_API="$API/repos/$OWNER/$REPO"

lsp() { ( cd "$WORK" && "$DISP" "$@" ); }
pass=0; fail=0
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1)); }
no() { printf '\033[31m  ✗ %s\033[0m  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "── issues create / list / get ──"
N="$(lsp issues create --title "First issue" --body "hello body")"
[[ "$N" =~ ^[0-9]+$ ]] && ok "create returns numeric id ($N)" || no "create returns numeric id" "got '$N'"

OUT="$(lsp issues list)"
grep -q "First issue" <<<"$OUT" && ok "list shows the new issue" || no "list shows the new issue" "$OUT"
cols="$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')"
[ "$cols" = 3 ] && ok "list rows are 3-col TSV" || no "list rows are 3-col TSV" "got $cols cols"

GET="$(lsp issues get --number "$N")"
head -1 <<<"$GET" | grep -q "First issue" && ok "get returns title line" || no "get returns title line" "$GET"
grep -q "hello body" <<<"$GET" && ok "get returns body" || no "get returns body"

echo "── labels resolve ──"
RES="$(lsp labels resolve --name "status/to test")"
id="$(awk -F'\t' '{print $2}' <<<"$RES")"
[[ "$id" =~ ^[0-9]+$ ]] && ok "resolve returns name⇥id ($id)" || no "resolve returns name⇥id" "got '$RES'"
EMPTY="$(lsp labels resolve --name "no-such-label" | awk -F'\t' '{print $2}')"
[ -z "$EMPTY" ] && ok "unknown label resolves to empty id" || no "unknown label resolves to empty id" "got '$EMPTY'"

echo "── set-status (single-status invariant) ──"
lsp issues set-status --number "$N" --status in-progress
lsp issues set-status --number "$N" --status to-test
LBLS="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/issues/$N" | jq -r '[.labels[].name] | sort | join(",")')"
[ "$LBLS" = "status/to test" ] && ok "only the latest status label remains ($LBLS)" \
  || no "only the latest status label remains" "got '$LBLS'"

echo "── comment ──"
if lsp issues comment --number "$N" --body "a smoke comment"; then
  cnt="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/issues/$N/comments" | jq 'length')"
  [ "$cnt" -ge 1 ] && ok "comment posted (count=$cnt)" || no "comment posted" "count=$cnt"
else no "comment exits 0"; fi

echo "── comments (read) ──"
CMTS="$(lsp issues comments --number "$N")"
grep -q "a smoke comment" <<<"$CMTS" && ok "comments returns the posted body" || no "comments returns the posted body" "$CMTS"
head -1 <<<"$CMTS" | grep -q $'\t' && ok "comments header line is author⇥timestamp TSV" || no "comments header is TSV" "$(head -1 <<<"$CMTS")"

echo "── pr open / merge ──"
# Make a branch with a diff via the API (create a file on a new branch off main).
# Unique branch + path per run so smoke.sh is re-runnable without resetting the rig.
BR="feat-smoke-$$"
curl -fsS -H "Authorization: token $TOKEN" -X POST -H 'Content-Type: application/json' \
  -d "$(jq -n --arg br "$BR" '{content:"aGVsbG8K", message:"add file", branch:"main", new_branch:$br}')" \
  "$REPO_API/contents/${BR}.txt" >/dev/null 2>&1 \
  && ok "created $BR branch with a commit" || no "created $BR branch"
PR="$(lsp pr open --head "$BR" --base main --title "Smoke PR")"
prnum="$(awk -F'\t' '{print $1}' <<<"$PR")"
[[ "$prnum" =~ ^[0-9]+$ ]] && grep -q "http" <<<"$PR" && ok "pr open returns number⇥url ($prnum)" \
  || no "pr open returns number⇥url" "got '$PR'"
if lsp pr merge --number "$prnum" --strategy squash; then
  merged="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/pulls/$prnum" | jq -r '.merged')"
  [ "$merged" = "true" ] && ok "pr merged" || no "pr merged" "merged=$merged"
else no "pr merge exits 0"; fi

echo "── close ──"
lsp issues close --number "$N"
state="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/issues/$N" | jq -r '.state')"
[ "$state" = "closed" ] && ok "issue closed" || no "issue closed" "state=$state"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m✓ ALL %d CHECKS PASSED\033[0m\n' "$pass"
else
  printf '\033[31m✗ %d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1
fi
