#!/usr/bin/env bash
#
# Exercise the live Jira adapter verbs against the rig project and assert behavior.
# Requires ./up.sh to have run first. Everything created is marker-tagged
# ('[rig]' summary + 'rig' label) so ./down.sh can clean up exactly its own artifacts.
# shellcheck disable=SC2015  # 'cond && ok || no' is intentional: ok() returns 0.
set -uo pipefail

RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$RIG_DIR/.work"
DISP="$RIG_DIR/../../flight/scripts/flight"
[ -f "$WORK/.flightdirector/config.json" ] || { echo "no workdir config — run ./up.sh first" >&2; exit 1; }

PROJECT="$(jq -r '.issues.project' "$WORK/.flightdirector/config.json")"
SITE="$(jq -r '.issues.api' "$WORK/.flightdirector/config.json")"; SITE="${SITE%/}"
EMAIL="$(jq -r '.issues.email' "$WORK/.flightdirector/config.json")"
TOKEN="$(jq -r '.issues.token' "$WORK/.flightdirector/secrets.json")"
AUTH=(-u "${EMAIL}:${TOKEN}")
# Jira's JQL search index is eventually consistent — `issues get` and direct
# issue reads are immediate, but `issues list` (JQL) lags a create/label change
# by a few seconds. So list-based assertions poll, and label/status invariants
# are verified via a direct issue read (immediate), mirroring the github rig.
issue_labels() { curl -fsS "${AUTH[@]}" -H "Accept: application/json" "$SITE/rest/api/3/issue/$1?fields=labels" | jq -r '.fields.labels // [] | join(",")'; }
issue_catkey() { curl -fsS "${AUTH[@]}" -H "Accept: application/json" "$SITE/rest/api/3/issue/$1?fields=status"  | jq -r '.fields.status.statusCategory.key // ""'; }
TS="$(date -u +%Y%m%d%H%M%S)"

lsp() { ( cd "$WORK" && "$DISP" "$@" ); }
pass=0; fail=0
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1)); }
no() { printf '\033[31m  ✗ %s\033[0m  %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "── issues create / list / get (key-as-id, ADF body) ──"
K="$(lsp issues create --title "[rig] smoke $TS" --body $'hello body\n\n- item one\n- item two' --label rig)"
[[ "$K" =~ ^${PROJECT}-[0-9]+$ ]] && ok "create returns a Jira key ($K)" || no "create returns a Jira key" "got '$K'"

OUT=""
for _ in $(seq 1 20); do
  OUT="$(lsp issues list)"
  grep -q "\[rig\] smoke $TS" <<<"$OUT" && break
  sleep 1
done
grep -q "\[rig\] smoke $TS" <<<"$OUT" && ok "list shows the new issue (eventually-consistent JQL index)" || no "list shows the new issue" "$OUT"
cols="$(head -1 <<<"$OUT" | awk -F'\t' '{print NF}')"
[ "$cols" = 3 ] && ok "list rows are 3-col TSV" || no "list rows are 3-col TSV" "got $cols cols"

GET="$(lsp issues get --number "$K")"
grep -q "\[rig\] smoke $TS" <<<"$GET" && ok "get returns key⇥summary⇥state line" || no "get returns key⇥summary⇥state line" "$GET"
# Jira has no state field: `.fields.status.statusCategory.key` decides (#205).
ST="$(cut -f3 < <(head -1 <<<"$GET"))"
[ "$ST" = open ] && ok "get maps a non-done status category to open" || no "get maps status category to open" "got '$ST'"
grep -q "hello body" <<<"$GET" && ok "get returns body (ADF→text)" || no "get returns body" "$GET"
grep -q -- "- item one" <<<"$GET" && ok "get renders a bullet list from ADF" || no "get renders a bullet list" "$GET"

echo "── labels resolve (name is its own id) ──"
r="$(lsp labels resolve --name "rig" | awk -F'\t' '{print $2}')"
[ "$r" = "rig" ] && ok "resolve returns name⇥name ($r)" || no "resolve returns name⇥name" "got '$r'"

echo "── set-status (single-status invariant, via Jira labels) ──"
lsp issues set-status --number "$K" --status in-progress && ok "set-status in-progress exits 0" || no "set-status in-progress"
lsp issues set-status --number "$K" --status to-test     && ok "set-status to-test exits 0"     || no "set-status to-test"
# Single-status invariant, read directly off the issue (immediate consistency).
STATUS_LBLS="$(issue_labels "$K" | tr ',' '\n' | grep '^status/' | sort | paste -sd, -)"
[ "$STATUS_LBLS" = "status/to-test" ] && ok "only the latest status label remains ($STATUS_LBLS)" \
  || no "only the latest status label remains" "got '$STATUS_LBLS'"

echo "── comment / comments (ADF round-trip) ──"
lsp issues comment --number "$K" --body $'rig comment\n\n```\ncode block\n```' && ok "comment exits 0" || no "comment exits 0"
CMTS="$(lsp issues comments --number "$K")"
grep -q "rig comment" <<<"$CMTS" && ok "comments returns the posted body" || no "comments returns the posted body" "$CMTS"
grep -q "code block" <<<"$CMTS" && ok "comment code block round-trips" || no "comment code block round-trips" "$CMTS"
grep -q $'\t' < <(head -1 <<<"$CMTS") && ok "comments header is author⇥timestamp TSV" || no "comments header is TSV" "$(head -1 <<<"$CMTS")"

echo "── close / reopen (workflow transitions) ──"
lsp issues close --number "$K" && ok "close exits 0 (Done transition)" || no "close exits 0"
[ "$(issue_catkey "$K")" = "done" ] && ok "issue is in the Done status category" || no "issue is in the Done status category" "got '$(issue_catkey "$K")'"
lsp issues reopen --number "$K" && ok "reopen exits 0 (To-Do/In-Progress transition)" || no "reopen exits 0"
CAT="$(issue_catkey "$K")"
[ "$CAT" != "done" ] && ok "reopened issue left the Done category ($CAT)" || no "reopened issue left the Done category" "still done"

echo "── issues block / blockers / blocking / unblock (FJ-271) ──"
# The rig writes a legacy (schema 2) config; the dependency verbs route by named tracker,
# which needs schema 3 — migrate the throwaway workdir in place first.
lsp reconcile --harness claude >/dev/null 2>&1 || no "reconcile (schema 3 migration)"
DA="$(lsp issues create --title "[rig] blocked" --body "dependency smoke")"
DB="$(lsp issues create --title "[rig] blocker" --body "dependency smoke")"
OUT="$(lsp issues block --number "$DA" --by "$DB" --no-status 2>&1)"
VIA="$(sed -nE 's/.*\((native|text)\)$/\1/p' <<<"$OUT" | tail -n1)"
# Native, not text: pins the inwardIssue/outwardIssue direction in flight/scripts/adapters/jira/issues.
[ "$VIA" = native ] && ok "block uses the native link ($VIA)" || no "block uses the native link" "via='$VIA' $OUT"
OUT="$(lsp issues blockers --number "$DA")"
grep -q "blocker	open	$VIA$" <<<"$OUT" && ok "blockers lists it ($VIA)" || no "blockers lists it" "$OUT"
OUT="$(lsp issues blocking --number "$DB")"
grep -q "blocked	open	$VIA$" <<<"$OUT" && ok "blocking lists the reverse" || no "blocking lists the reverse" "$OUT"
lsp issues unblock --number "$DA" --by "$DB" --no-status >/dev/null
RC=0; OUT="$(lsp issues blockers --number "$DA" 2>&1)" || RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "unblock removes it" || no "unblock removes it" "rc=$RC $OUT"
lsp issues close --number "$DA" >/dev/null; lsp issues close --number "$DB" >/dev/null

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
