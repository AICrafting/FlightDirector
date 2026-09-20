#!/usr/bin/env bash
#
# Exercise the live Forgejo adapter verbs against the rig and assert behavior.
# Requires ./up.sh to have run first.
# shellcheck disable=SC2015  # 'cond && ok || no' is intentional: ok() always returns 0, so no() only runs when cond fails.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../flight/scripts/flight"
[ -f "$WORK/.flightdirector/config.json" ] || { echo "no workdir config — run ./up.sh first" >&2; exit 1; }

API="$(jq -r '.code.api' "$WORK/.flightdirector/config.json")"
OWNER="$(jq -r '.code.owner' "$WORK/.flightdirector/config.json")"
REPO="$(jq -r '.code.repo' "$WORK/.flightdirector/config.json")"
TOKEN="$(jq -r '.code.token' "$WORK/.flightdirector/secrets.json")"
REPO_API="$API/repos/$OWNER/$REPO"

lsp() { ( cd "$WORK" && "$DISP" "$@" ); }
pass=0; fail=0
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1)); }
no() { printf '\033[31m  ✗ %s\033[0m  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
# A condition the rig cannot control: no runner, or CI too slow to reach a verdict. Locally
# that is a warning — the rig still proves everything it could reach. Under RIG_STRICT=1 (what
# the CI workflow sets) it is a failure instead: in an unattended run a warning nobody reads is
# a silent skip, and "the rig was green" would then mean "the rig checked nothing" (#187).
soft() {
	if [ "${RIG_STRICT:-0}" = 1 ]; then no "$1" "${2:-}"
	else printf '\033[33m  ⚠ %s (soft)\033[0m\n' "$1"; [ -z "${2:-}" ] || printf '\033[33m    %s\033[0m\n' "$2"; fi
}

echo "── issues create / list / get ──"
N="$(lsp issues create --title "First issue" --body "hello body")"
[[ "$N" =~ ^[0-9]+$ ]] && ok "create returns numeric id ($N)" || no "create returns numeric id" "got '$N'"

OUT="$(lsp issues list)"
grep -q "First issue" <<<"$OUT" && ok "list shows the new issue" || no "list shows the new issue" "$OUT"
cols="$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')"
[ "$cols" = 3 ] && ok "list rows are 3-col TSV" || no "list rows are 3-col TSV" "got $cols cols"

GET="$(lsp issues get --number "$N")"
grep -q "First issue" < <(head -1 <<<"$GET") && ok "get returns title line" || no "get returns title line" "$GET"
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

echo "── assign / unassign ──"
lsp issues assign --number "$N" --user "$OWNER"
ASG="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/issues/$N" | jq -r '[.assignees[]?.login] | join(",")')"
[ "$ASG" = "$OWNER" ] && ok "assign sets the assignee ($ASG)" || no "assign sets the assignee" "got '$ASG'"
lsp issues unassign --number "$N"
ASG="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/issues/$N" | jq -r '[.assignees[]?.login] | join(",")')"
[ -z "$ASG" ] && ok "unassign clears assignees" || no "unassign clears assignees" "got '$ASG'"

echo "── comment ──"
if lsp issues comment --number "$N" --body "a smoke comment"; then
  cnt="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/issues/$N/comments" | jq 'length')"
  [ "$cnt" -ge 1 ] && ok "comment posted (count=$cnt)" || no "comment posted" "count=$cnt"
else no "comment exits 0"; fi

echo "── comments (read) ──"
CMTS="$(lsp issues comments --number "$N")"
grep -q "a smoke comment" <<<"$CMTS" && ok "comments returns the posted body" || no "comments returns the posted body" "$CMTS"
grep -q $'\t' < <(head -1 <<<"$CMTS") && ok "comments header line is author⇥timestamp TSV" || no "comments header is TSV" "$(head -1 <<<"$CMTS")"

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

echo "── reopen ──"
lsp issues reopen --number "$N"
state="$(curl -fsS -H "Authorization: token $TOKEN" "$REPO_API/issues/$N" | jq -r '.state')"
[ "$state" = "open" ] && ok "issue reopened" || no "issue reopened" "state=$state"

echo "── ci watch / ci log on a red pull_request run (#138, #186) ──"
# A PR whose head carries two pull_request workflows — one red (while `rig-fail` exists),
# one green — so one commit holds a failed and a passed run that started together, both
# under the PR ref rather than refs/heads/<branch>. The rig's runner executes them in host
# mode; if it never came online the section warns and skips instead of failing.
TS="$(date -u +%Y%m%d%H%M%S)"
AUTH=(-H "Authorization: token $TOKEN" -H 'Content-Type: application/json')
put_file() {	# put_file <branch> <path> <content>
  curl -fsS "${AUTH[@]}" -X POST "$REPO_API/contents/$2" \
    -d "$(jq -n --arg m "[rig] add $2" --arg c "$(printf '%s' "$3" | base64 | tr -d '\n')" --arg b "$1" \
          '{message:$m, content:$c, branch:$b}')" >/dev/null
}
CBASE="rig/$TS-cibase"; CHEAD="rig/$TS-cihead"
for b in "$CBASE" "$CHEAD"; do
  curl -fsS "${AUTH[@]}" -X POST "$REPO_API/branches" \
    -d "$(jq -n --arg n "$b" '{new_branch_name:$n, old_branch_name:"main"}')" >/dev/null
done
seeded=1
put_file "$CHEAD" ".forgejo/workflows/rig-pr-red.yml"   "$(cat "$RIG_DIR/workflows/rig-pr-red.yml")"   || seeded=0
put_file "$CHEAD" ".forgejo/workflows/rig-pr-green.yml" "$(cat "$RIG_DIR/workflows/rig-pr-green.yml")" || seeded=0
put_file "$CHEAD" "rig-fail" "fail until removed ($TS)" || seeded=0
[ "$seeded" = 1 ] && ok "seeded red + green pull_request workflows on $CHEAD" || no "seeded the pull_request workflows"
CPR="$(lsp pr open --head "$CHEAD" --base "$CBASE" --title "[rig] ci-log pr $TS" --body "rig ci log")"
cprnum="$(awk -F'\t' '{print $1}' <<<"$CPR")"
CHEAD_SHA="$(curl -fsS "${AUTH[@]}" "$REPO_API/branches/$(printf '%s' "$CHEAD" | jq -sRr @uri)" | jq -r '.commit.id')"
[[ "$cprnum" =~ ^[0-9]+$ ]] && ok "opened the ci-log PR (#$cprnum)" || no "opened the ci-log PR" "got '$CPR'"

watch_pr() { ( cd "$WORK" && LS_CI_POLL_SECONDS=3 "$DISP" ci watch --pr "$cprnum" --timeout 180 2>&1 ) || true; }
LINES="$(watch_pr)"
if ! grep -qE "^ci runs=[0-9]+ .*status=(failure|success|skipped)" <<<"$LINES"; then
  soft "no terminal CI verdict for the ci-log PR — is the rig runner online? see up.sh output; ci checks skipped" "$(tail -1 <<<"$LINES")"
else
  ok "ci watch streams aggregate status lines"
  grep -q "runs=2 .*status=failure" < <(tail -1 <<<"$LINES") && ok "ci watch --pr sees both runs and ends at status=failure" \
    || no "ci watch --pr sees both runs and ends at status=failure" "$(tail -1 <<<"$LINES")"
  for form in "--pr $cprnum" "--sha $CHEAD_SHA" "--failed $CHEAD"; do
    # shellcheck disable=SC2086  # $form is a flag and its value, split on purpose
    LOG="$(lsp ci log $form 2>&1)"
    if grep -q "RIG-RED-OUTPUT" <<<"$LOG" && ! grep -q "RIG-GREEN-OUTPUT" <<<"$LOG"; then
      ok "ci log ${form%% *} shows the red job's log and not the green one's"
    else
      no "ci log ${form%% *} shows the red job's log and not the green one's" "$(head -5 <<<"$LOG")"
    fi
  done

  # Remove rig-fail → the PR's new head commit goes green → ci log has nothing to show.
  fsha="$(curl -fsS "${AUTH[@]}" "$REPO_API/contents/rig-fail?ref=$(printf '%s' "$CHEAD" | jq -sRr @uri)" | jq -r '.sha')"
  curl -fsS "${AUTH[@]}" -X DELETE "$REPO_API/contents/rig-fail" \
    -d "$(jq -n --arg m "[rig] remove rig-fail" --arg s "$fsha" --arg b "$CHEAD" '{message:$m, sha:$s, branch:$b}')" >/dev/null
  sleep 3	# let the synchronize event create the new runs before watching
  LINES="$(watch_pr)"
  if grep -q "status=success" < <(tail -1 <<<"$LINES"); then
    ok "after the fix the PR's new head watches green"
    LOG="$(lsp ci log --pr "$cprnum" 2>&1)"; rc=$?
    [ "$rc" = 0 ] && grep -q "no failed jobs" <<<"$LOG" && ok "ci log --pr on a green head says '(no failed jobs …)', exit 0" \
      || no "ci log --pr on a green head says '(no failed jobs …)', exit 0" "rc=$rc $(head -3 <<<"$LOG")"
  else
    no "after the fix the PR's new head watches green" "$(tail -1 <<<"$LINES")"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m✓ ALL %d CHECKS PASSED\033[0m\n' "$pass"
else
  printf '\033[31m✗ %d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1
fi
