#!/usr/bin/env bash
#
# Exercise the live GitHub adapter verbs against the rig target and assert behavior.
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
REPO_API="$API/repos/$OWNER/$REPO"
H=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
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
[[ "$N" =~ ^[0-9]+$ ]] && ok "create returns numeric id ($N)" || no "create returns numeric id" "got '$N'"

# GitHub's issues LIST endpoint is eventually consistent — it lags create by a few
# seconds (direct `get` is immediate). Poll until the new issue shows up, up to ~20s.
OUT=""
for _ in $(seq 1 20); do
  OUT="$(lsp issues list)"
  grep -q "\[rig\] smoke $TS" <<<"$OUT" && break
  sleep 1
done
grep -q "\[rig\] smoke $TS" <<<"$OUT" && ok "list shows the new issue (eventually-consistent endpoint)" || no "list shows the new issue" "$OUT"
cols="$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')"
[ "$cols" = 3 ] && ok "list rows are 3-col TSV" || no "list rows are 3-col TSV" "got $cols cols"

GET="$(lsp issues get --number "$N")"
grep -q "\[rig\] smoke $TS" <<<"$GET" && ok "get returns title line" || no "get returns title line"
grep -q "hello body" <<<"$GET" && ok "get returns body" || no "get returns body"
ST="$(cut -f3 < <(head -1 <<<"$GET"))"
[ "$ST" = open ] && ok "get reports state=open for a fresh issue" || no "get reports state=open" "got '$ST'"

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

echo "── comment / comments / close ──"
lsp issues comment --number "$N" --body "rig comment" && ok "comment exits 0" || no "comment exits 0"
CMTS="$(lsp issues comments --number "$N")"
grep -q "rig comment" <<<"$CMTS" && ok "comments returns the posted body" || no "comments returns the posted body" "$CMTS"
grep -q $'\t' < <(head -1 <<<"$CMTS") && ok "comments header is author⇥timestamp TSV" || no "comments header is TSV" "$(head -1 <<<"$CMTS")"
lsp issues close --number "$N" && ok "close exits 0" || no "close exits 0"

echo "── pr open (rig branches off main; main untouched) ──"
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
# `pr get`'s state is normalized to open|closed|merged (#206). GitHub says `open` on
# the wire, but reports a MERGED PR as `closed` with merged_at set — the post-merge
# value below is the one a fake curl can only approximate.
PST="$(lsp pr get --number "$prnum" | cut -f3)"
[ "$PST" = open ] && ok "pr get reports state=open before the merge" || no "pr get reports state=open" "got '$PST'"

# Watch BEFORE merging, the order a real promotion uses (#185): the seeded workflow checks
# the branch out, and a repo that deletes head branches on merge would leave it nothing to
# fetch — which is how the GitLab rig's push pipeline failed on every run.
echo "── ci watch (the seeded workflow on the rig push) ──"
LINES="$(cd "$WORK" && "$DISP" ci watch --sha "$HEAD_SHA" --timeout 180 2>&1 || true)"
grep -qE "^ci runs=[0-9]+ .*status=" <<<"$LINES" && ok "ci watch streams aggregate status lines" || no "ci watch streams aggregate status lines" "$LINES"
if grep -qE "status=(success|failure|skipped)" < <(tail -1 <<<"$LINES"); then
  # A run reached a verdict, so anything but success is a real failure, not a slow runner.
  grep -q "status=success" < <(tail -1 <<<"$LINES") && ok "ci watch reaches success" || no "ci watch reaches success" "$(tail -1 <<<"$LINES")"
else
  soft "ci watch reached no verdict — Actions may be slow" "$(tail -1 <<<"$LINES")"
fi

echo "── pr merge ──"
lsp pr merge --number "$prnum" --strategy squash && ok "pr merge exits 0" || no "pr merge exits 0"
PST="$(lsp pr get --number "$prnum" | cut -f3)"
[ "$PST" = merged ] && ok "pr get reports state=merged after the merge" \
  || no "pr get reports state=merged (closed + merged_at on the wire)" "got '$PST'"

echo "── ci log on a red pull_request run (#138) ──"
# A PR whose head carries two pull_request workflows — one red (while `rig-fail` exists),
# one green — so one commit holds a failed and a passed run that started together. The
# workflow files live on the rig head branch only; pull_request runs read them from there.
put_file() {	# put_file <branch> <path> <local-file|-> [content]
  local content; if [ "$3" = "-" ]; then content="$4"; else content="$(cat "$3")"; fi
  curl -fsS "${H[@]}" -X PUT "$REPO_API/contents/$2" \
    -d "$(jq -n --arg m "[rig] add $2" --arg c "$(printf '%s' "$content" | base64 | tr -d '\n')" --arg b "$1" \
          '{message:$m, content:$c, branch:$b}')" >/dev/null
}
CBASE="rig/$TS-cibase"; CHEAD="rig/$TS-cihead"
for b in "$CBASE" "$CHEAD"; do
  curl -fsS "${H[@]}" -X POST "$REPO_API/git/refs" \
    -d "$(jq -n --arg r "refs/heads/$b" --arg s "$MAIN_SHA" '{ref:$r, sha:$s}')" >/dev/null
done
seeded=1
put_file "$CHEAD" ".github/workflows/rig-pr-red.yml"   "$RIG_DIR/workflows/rig-pr-red.yml"   || seeded=0
put_file "$CHEAD" ".github/workflows/rig-pr-green.yml" "$RIG_DIR/workflows/rig-pr-green.yml" || seeded=0
put_file "$CHEAD" "rig-fail" - "fail until removed ($TS)" || seeded=0
[ "$seeded" = 1 ] && ok "seeded red + green pull_request workflows on $CHEAD" \
  || no "seeded the pull_request workflows (token needs the 'workflow' scope)"
CPR="$(lsp pr open --head "$CHEAD" --base "$CBASE" --title "[rig] ci-log pr $TS" --body "rig ci log")"
cprnum="$(awk -F'\t' '{print $1}' <<<"$CPR")"
CHEAD_SHA="$(curl -fsS "${H[@]}" "$REPO_API/git/ref/heads/$CHEAD" | jq -r '.object.sha')"
[[ "$cprnum" =~ ^[0-9]+$ ]] && ok "opened the ci-log PR (#$cprnum)" || no "opened the ci-log PR" "got '$CPR'"

LINES="$(cd "$WORK" && "$DISP" ci watch --pr "$cprnum" --timeout 300 2>&1 || true)"
if ! grep -qE "^ci runs=[0-9]+ .*status=(failure|success|skipped)" <<<"$LINES"; then
  soft "no terminal CI verdict for the ci-log PR — Actions may be disabled or slow; ci log checks skipped" "$(tail -1 <<<"$LINES")"
else
  grep -q "status=failure" < <(tail -1 <<<"$LINES") && ok "ci watch --pr ends at status=failure" || no "ci watch --pr ends at status=failure" "$(tail -1 <<<"$LINES")"
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
  fsha="$(curl -fsS "${H[@]}" "$REPO_API/contents/rig-fail?ref=$CHEAD" | jq -r '.sha')"
  curl -fsS "${H[@]}" -X DELETE "$REPO_API/contents/rig-fail" \
    -d "$(jq -n --arg m "[rig] remove rig-fail" --arg s "$fsha" --arg b "$CHEAD" '{message:$m, sha:$s, branch:$b}')" >/dev/null
  sleep 5	# let the synchronize event create the new runs before watching
  LINES="$(cd "$WORK" && "$DISP" ci watch --pr "$cprnum" --timeout 300 2>&1 || true)"
  if grep -q "status=success" < <(tail -1 <<<"$LINES"); then
    ok "after the fix the PR's new head watches green"
    LOG="$(lsp ci log --pr "$cprnum" 2>&1)"; rc=$?
    [ "$rc" = 0 ] && grep -q "no failed jobs" <<<"$LOG" && ok "ci log --pr on a green head says '(no failed jobs …)', exit 0" \
      || no "ci log --pr on a green head says '(no failed jobs …)', exit 0" "rc=$rc $(head -3 <<<"$LOG")"
  else
    soft "the fixed head did not watch green in time" "$(tail -1 <<<"$LINES")"
  fi
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
