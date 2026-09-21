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
# A condition the rig cannot control: no runner, or CI too slow to reach a verdict. Locally
# that is a warning — the rig still proves everything it could reach. Under RIG_STRICT=1 (what
# the CI workflow sets) it is a failure instead: in an unattended run a warning nobody reads is
# a silent skip, and "the rig was green" would then mean "the rig checked nothing" (#187).
soft() {
	if [ "${RIG_STRICT:-0}" = 1 ]; then no "$1" "${2:-}"
	else printf '\033[33m  ⚠ %s (soft)\033[0m\n' "$1"; [ -z "${2:-}" ] || printf '\033[33m    %s\033[0m\n' "$2"; fi
}

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
# GitLab's wire value for an open issue is `opened`; the adapter normalizes it (#205).
ST="$(cut -f3 < <(head -1 <<<"$GET"))"
[ "$ST" = open ] && ok "get normalizes GitLab's 'opened' to open" || no "get normalizes 'opened'" "got '$ST'"

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
grep -q $'\t' < <(head -1 <<<"$CMTS") && ok "comments header is author⇥timestamp TSV" || no "comments header is TSV" "$(head -1 <<<"$CMTS")"
lsp issues close --number "$N" && ok "close exits 0" || no "close exits 0"

echo "── pr (MR) open (rig branches off default; default untouched) ──"
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

# Watch BEFORE merging, the order a real promotion uses (#185). This project removes the
# source branch on merge (`remove_source_branch_after_merge`), and a runner picks the push
# pipeline's job up a few seconds after the push — merge first and its fetch of
# refs/heads/<branch> finds nothing, so the job dies with exit 128 before running a line of
# its script and the success path is never exercised.
echo "── ci watch (the seeded pipeline on the rig push) ──"
LINES="$(cd "$WORK" && "$DISP" ci watch --sha "$HEAD_SHA" --timeout 150 2>&1 || true)"
if grep -qE "ci runs=[0-9]+ .*status=(success|failure|skipped)" <<<"$LINES"; then
  ok "ci watch streams aggregate status lines"
  # A pipeline ran to a verdict, so anything but success is a real failure, not a slow runner.
  grep -q "status=success" < <(tail -1 <<<"$LINES") && ok "ci watch reaches success" \
    || no "ci watch reaches success" "$(tail -1 <<<"$LINES")"
else
  soft "ci watch reached no verdict — gitlab.com shared runners may be unavailable for this project" "$(tail -1 <<<"$LINES")"
fi

echo "── pr (MR) merge ──"
# GitLab computes MR mergeability asynchronously; retry briefly.
merged=0
for _ in $(seq 1 10); do
  if lsp pr merge --number "$mrnum" --strategy squash 2>/dev/null; then merged=1; break; fi
  sleep 2
done
[ "$merged" = 1 ] && ok "pr merge exits 0" || no "pr merge exits 0"

echo "── ci log on a red merge-request pipeline (#138) ──"
# An MR whose head carries an MR-only .gitlab-ci.yml with a red job (while `rig-fail`
# exists) and a green one. The pipeline's ref is refs/merge-requests/<iid>/head, so nothing
# ever fails under the branch ref itself.
enc() { printf '%s' "$1" | jq -sRr @uri; }
put_file() {	# put_file <branch> <path> <content>  (update if the branch already has it, else create)
  local body; body="$(jq -n --arg b "$1" --arg c "$3" --arg m "[rig] write $2" '{branch:$b, content:$c, commit_message:$m}')"
  curl -fsS "${H[@]}" -X PUT "$PROJECT_API/repository/files/$(enc "$2")" -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 \
    || curl -fsS "${H[@]}" -X POST "$PROJECT_API/repository/files/$(enc "$2")" -H 'Content-Type: application/json' -d "$body" >/dev/null
}
CBASE="rig/$TS-cibase"; CHEAD="rig/$TS-cihead"
for b in "$CBASE" "$CHEAD"; do
  curl -fsS "${H[@]}" -X POST "$PROJECT_API/repository/branches?branch=$(enc "$b")&ref=$DEFAULT_BRANCH" >/dev/null
done
seeded=1
put_file "$CHEAD" ".gitlab-ci.yml" "$(cat "$RIG_DIR/gitlab-ci-mr.yml")" || seeded=0
put_file "$CHEAD" "rig-fail" "fail until removed ($TS)" || seeded=0
[ "$seeded" = 1 ] && ok "seeded the MR-only red + green pipeline on $CHEAD" || no "seeded the MR-only pipeline"
CMR="$(lsp pr open --head "$CHEAD" --base "$CBASE" --title "[rig] ci-log mr $TS" --body "rig ci log")"
cmrnum="$(awk -F'\t' '{print $1}' <<<"$CMR")"
CHEAD_SHA="$(curl -fsS "${H[@]}" "$PROJECT_API/repository/branches/$(enc "$CHEAD")" | jq -r '.commit.id')"
[[ "$cmrnum" =~ ^[0-9]+$ ]] && ok "opened the ci-log MR (!$cmrnum)" || no "opened the ci-log MR" "got '$CMR'"

LINES="$(cd "$WORK" && "$DISP" ci watch --pr "$cmrnum" --timeout 300 2>&1 || true)"
if ! grep -qE "ci runs=[0-9]+ .*status=(failure|success|skipped)" <<<"$LINES"; then
  soft "no terminal pipeline verdict for the ci-log MR — shared runners may be unavailable; ci log checks skipped" "$(tail -1 <<<"$LINES")"
else
  grep -q "status=failure" < <(tail -1 <<<"$LINES") && ok "ci watch --pr ends at status=failure" || no "ci watch --pr ends at status=failure" "$(tail -1 <<<"$LINES")"
  for form in "--pr $cmrnum" "--sha $CHEAD_SHA" "--failed $CHEAD"; do
    # shellcheck disable=SC2086  # $form is a flag and its value, split on purpose
    LOG="$(lsp ci log $form 2>&1)"
    if grep -q "RIG-RED-OUTPUT" <<<"$LOG" && ! grep -q "RIG-GREEN-OUTPUT" <<<"$LOG"; then
      ok "ci log ${form%% *} shows the red job's trace and not the green one's"
    else
      no "ci log ${form%% *} shows the red job's trace and not the green one's" "$(head -5 <<<"$LOG")"
    fi
  done

  # Remove rig-fail → the MR's new head pipeline goes green → ci log has nothing to show.
  curl -fsS "${H[@]}" -X DELETE "$PROJECT_API/repository/files/rig-fail" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg b "$CHEAD" '{branch:$b, commit_message:"[rig] remove rig-fail"}')" >/dev/null
  sleep 5	# let the push create the new MR pipeline before watching
  LINES="$(cd "$WORK" && "$DISP" ci watch --pr "$cmrnum" --timeout 300 2>&1 || true)"
  if grep -q "status=success" < <(tail -1 <<<"$LINES"); then
    ok "after the fix the MR's new head watches green"
    LOG="$(lsp ci log --pr "$cmrnum" 2>&1)"; rc=$?
    [ "$rc" = 0 ] && grep -q "no failed jobs" <<<"$LOG" && ok "ci log --pr on a green head says '(no failed jobs …)', exit 0" \
      || no "ci log --pr on a green head says '(no failed jobs …)', exit 0" "rc=$rc $(head -3 <<<"$LOG")"
  else
    soft "the fixed head did not watch green in time" "$(tail -1 <<<"$LINES")"
  fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
