#!/usr/bin/env bash
# issue-identity.sh (#198) — the shared retained-identity contract every workflow script
# and skill uses: branch → identity (qualified, legacy-bound, explicit), manifest and
# history references, `remember`, and the code-PR issue line (closing keywords only for
# the code repository's own issues). Runs against the REAL dispatcher's `issues resolve`
# in a throwaway repo — no network is involved in any of these verbs.
set -euo pipefail

unset LS_TOKEN FLIGHT_TOKEN FORGEJO_TOKEN LS_SECRETS_FILE LS_EMAIL FLIGHT_SELF FLIGHT_REPO_ROOT
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IDENTITY="$REPO_ROOT/flight/scripts/issue-identity.sh"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }
# tracks <ID> — pr-reference's cross-tracker line: the id is a code span (#247).
BT='`'
tracks() { printf 'Tracks %s%s%s' "$BT" "$1" "$BT"; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
CFG="$R/.flightdirector/config.json"
BIND="$R/.flightdirector/batches/work-items/identities.json"

# FJ is the code repository's own issue tracker (same backend + api + owner/repo — the
# api differs only by a trailing slash). GH is another forge whose issue numbers overlap
# FJ's. JIR is a Jira project whose native key (PROJ) differs from its ref.
cat >"$CFG" <<'JSON'
{
  "schemaVersion": 3,
  "code": {"backend":"forgejo","api":"https://code.example.com/api/v1/","owner":"acme","repo":"widget","stages":[{"name":"develop"},{"name":"main"}]},
  "issues": {"backend":"requires-newer-flight"},
  "legacyIssueTracker": "FJ",
  "issueTrackers": [
    {"ref":"FJ","name":"Code issues","default":true,"backend":"forgejo","api":"https://code.example.com/api/v1","owner":"acme","repo":"widget","credentialRef":"code"},
    {"ref":"GH","aliases":["Hub"],"name":"Public issues","backend":"github","api":"https://api.github.com","owner":"acme","repo":"widget"},
    {"ref":"JIR","name":"Jira","backend":"jira","api":"https://jira.example.com","project":"PROJ","email":"bot@example.com"}
  ]
}
JSON
cp "$CFG" "$SANDBOX/config.good"
mkdir -p "$(dirname "$BIND")"
cat >"$BIND" <<'JSON'
{"schemaVersion":1,"legacyDefaultTracker":"FJ",
 "branches":{"feature/12-old-work":{"tracker":"FJ","number":"12","qualified":"FJ-12","branchPrefix":"fj-12","legacy":true}},
 "manifests":{"run1":{"tracker":"FJ","legacy":true}}}
JSON
cp "$BIND" "$SANDBOX/bind.good"

run() { (cd "$R" && "$IDENTITY" "$@"); }
ok() { "$@" >/dev/null 2>&1 && echo 1 || echo 0; }
status_of() { local rc=0; (cd "$R" && "$IDENTITY" "$@") >/dev/null 2>&1 || rc=$?; echo "$rc"; }
errtext() { { (cd "$R" && "$IDENTITY" "$@" >/dev/null) || true; } 2>&1; }
field() { jq -r ".$1" <<<"$2"; }
make_default() { jq --arg r "$1" '.issueTrackers |= map(.default = (.ref == $r))' "$SANDBOX/config.good" >"$CFG"; }

printf '\033[1m── branches ──\033[0m\n'
out="$(run from-branch --branch feature/fj-1-first)"; out2="$(run from-branch --branch feature/gh-1-second)"
check "two issues numbered 1 on different trackers are two identities" \
	"$([ "$(field qualified "$out")" = FJ-1 ] && [ "$(field qualified "$out2")" = GH-1 ] && echo 1 || echo 0)" "$out / $out2"
check "the identity is exactly the resolver keys" \
	"$(jq -e 'keys == ["branchPrefix","display","number","qualified","tracker"]' <<<"$out" >/dev/null && echo 1 || echo 0)" "$out"
out="$(run from-branch --branch feature/jir-7-jira-work)"
check "a Jira branch keeps the native key and qualifies with the tracker ref" \
	"$([ "$out" = '{"tracker":"JIR","number":"PROJ-7","qualified":"JIR-7","display":"JIR-7","branchPrefix":"jir-7"}' ] && echo 1 || echo 0)" "$out"
out="$(run from-branch --branch feature/12-old-work)"
check "a reconcile-bound legacy branch returns its binding without the legacy flag" \
	"$([ "$out" = '{"tracker":"FJ","number":"12","qualified":"FJ-12","display":"FJ-12","branchPrefix":"fj-12"}' ] && echo 1 || echo 0)" "$out"
check "a non-issue branch reports 'no identity' (3)" "$([ "$(status_of from-branch --branch release/0.1.0)" = 3 ] && echo 1 || echo 0)"
check "a word prefix that is no tracker is not an issue (3)" "$([ "$(status_of from-branch --branch feature/add-2-things)" = 3 ] && echo 1 || echo 0)"
check "an explicit tracker contradicting a qualified branch fails (1)" "$([ "$(status_of from-branch --branch feature/gh-8-x --tracker FJ)" = 1 ] && echo 1 || echo 0)"
check "an alias of the branch's own tracker is accepted" "$(ok run from-branch --branch feature/gh-8-x --tracker hub)"

printf '\033[1m── default change mid-work ──\033[0m\n'
make_default GH
out="$(run from-branch --branch feature/fj-3-started-under-fj)"
check "a qualified branch keeps its tracker after the default changes" "$([ "$(field tracker "$out")" = FJ ] && echo 1 || echo 0)" "$out"
out="$(run from-branch --branch bugfix/17-unbound-legacy)"
check "an unbound legacy branch uses the migrated legacy default, not the current one" \
	"$([ "$(field qualified "$out")" = FJ-17 ] && echo 1 || echo 0)" "$out"
out="$(run from-branch --branch feature/12-old-work)"
check "a bound legacy branch is unaffected by the default change" "$([ "$(field qualified "$out")" = FJ-12 ] && echo 1 || echo 0)" "$out"
out="$(run from-history --ref '#40')"
check "a bare history reference belongs to the legacy tracker" "$([ "$(field qualified "$out")" = FJ-40 ] && echo 1 || echo 0)" "$out"
out="$(run from-history --ref JIR-41)"
check "a qualified history reference resolves to its own tracker" "$([ "$(field number "$out")" = PROJ-41 ] && echo 1 || echo 0)" "$out"
out="$(run from-manifest --run-id run1 --entry 5)"
check "a legacy manifest entry uses its run's binding" "$([ "$(field qualified "$out")" = FJ-5 ] && echo 1 || echo 0)" "$out"
cp "$SANDBOX/config.good" "$CFG"

printf '\033[1m── unrecoverable legacy work ──\033[0m\n'
printf '{"schemaVersion":1,"branches":{},"manifests":{}}\n' >"$BIND"
check "an unbound legacy branch with no legacy default needs --tracker (4)" \
	"$([ "$(status_of from-branch --branch feature/9-old)" = 4 ] && echo 1 || echo 0)"
check "the error tells the user to choose, never guesses" \
	"$(grep -q 'rerun with --tracker' <<<"$(errtext from-branch --branch feature/9-old)" && echo 1 || echo 0)"
check "a legacy manifest with no binding needs a choice (4)" "$([ "$(status_of from-manifest --run-id other --entry 5)" = 4 ] && echo 1 || echo 0)"
check "a bare history reference with no binding needs a choice (4)" "$([ "$(status_of from-history --ref '#5')" = 4 ] && echo 1 || echo 0)"
out="$(run from-branch --branch feature/9-old --tracker gh)"
check "an explicit tracker recovers the legacy branch" "$([ "$(field qualified "$out")" = GH-9 ] && echo 1 || echo 0)" "$out"
check "…and is retained, so the next lookup needs no selector" \
	"$([ "$(run from-branch --branch feature/9-old | jq -r .qualified)" = GH-9 ] && echo 1 || echo 0)"
check "a retained binding refuses a contradicting selector" "$([ "$(status_of from-branch --branch feature/9-old --tracker FJ)" = 1 ] && echo 1 || echo 0)"
cp "$SANDBOX/bind.good" "$BIND"

printf '\033[1m── remember ──\033[0m\n'
ID="$(cd "$R" && "$REPO_ROOT/flight/scripts/flight" issues resolve --number GH-1)"
run remember --branch feature/gh-1-widget --identity "$ID"
check "remember stores the canonical identity" \
	"$(jq -e '.branches["feature/gh-1-widget"] == {"tracker":"GH","number":"1","qualified":"GH-1","branchPrefix":"gh-1"}' "$BIND" >/dev/null && echo 1 || echo 0)"
check "remember keeps the reconcile keys and legacy entries" \
	"$(jq -e '.legacyDefaultTracker == "FJ" and .branches["feature/12-old-work"].legacy == true and .manifests.run1.tracker == "FJ" and .schemaVersion == 1' "$BIND" >/dev/null && echo 1 || echo 0)"
check "remember is idempotent" "$(ok run remember --branch feature/gh-1-widget --identity "$ID")"
check "remember accepts a legacy-bound branch's own identity (legacy flag is metadata)" \
	"$(ok run remember --branch feature/12-old-work --identity '{"tracker":"FJ","number":"12","qualified":"FJ-12","display":"FJ-12","branchPrefix":"fj-12"}')"
check "remember never re-points a legacy binding" \
	"$([ "$(status_of remember --branch feature/12-old-work --identity '{"tracker":"GH","number":"12","qualified":"GH-12","display":"GH-12","branchPrefix":"gh-12"}')" = 1 ] && echo 1 || echo 0)"
check "remember refuses an identity the branch name contradicts" \
	"$([ "$(status_of remember --branch feature/gh-4-x --identity '{"tracker":"FJ","number":"4","qualified":"FJ-4","display":"FJ-4","branchPrefix":"fj-4"}')" = 1 ] && echo 1 || echo 0)"
check "remember refuses a hand-built identity the resolver disagrees with" \
	"$([ "$(status_of remember --branch feature/gh-4-x --identity '{"tracker":"GH","number":"4","qualified":"GH-99","display":"GH-99","branchPrefix":"gh-4"}')" = 1 ] && echo 1 || echo 0)"
check "remember accepts a Jira native id" \
	"$(ok run remember --branch feature/jir-8-work --identity '{"tracker":"JIR","number":"PROJ-8","qualified":"JIR-8","display":"JIR-8","branchPrefix":"jir-8"}')"
pids=""
for n in 21 22 23 24 25; do
	run remember --branch "feature/gh-$n-concurrent" \
		--identity "{\"tracker\":\"GH\",\"number\":\"$n\",\"qualified\":\"GH-$n\",\"branchPrefix\":\"gh-$n\"}" &
	pids="$pids $!"
done
concurrent_ok=1
for pid in $pids; do wait "$pid" || concurrent_ok=0; done
check "concurrent remembers keep every update (shared lock protocol)" \
	"$([ "$concurrent_ok" = 1 ] && [ "$(jq '[.branches | keys[] | select(test("concurrent"))] | length' "$BIND")" -eq 5 ] && [ ! -d "$BIND.lock" ] && echo 1 || echo 0)"
check "the helper never writes the retired work-items.json location" "$([ ! -e "$R/.flightdirector/work-items.json" ] && echo 1 || echo 0)"

printf '\033[1m── bare #N from history ──\033[0m\n'
# A bare #N has two writers: pre-migration history (the legacy tracker) and PR bodies
# written since, which say `Closes #N` for the code repository's own tracker (FJ here).
cp "$SANDBOX/bind.good" "$BIND"
out="$(run from-history --ref '#40')"
check "legacy tracker == code-repo tracker: a bare #N maps to it" "$([ "$(field qualified "$out")" = FJ-40 ] && echo 1 || echo 0)" "$out"
jq '.legacyDefaultTracker = "GH"' "$SANDBOX/bind.good" >"$BIND"
check "legacy tracker != code-repo tracker: a bare #N is ambiguous (4)" "$([ "$(status_of from-history --ref '#40')" = 4 ] && echo 1 || echo 0)"
check "…and the error names both candidates and asks for --tracker" \
	"$(grep -q 'rerun with --tracker' <<<"$(errtext from-history --ref '#40' | grep 'ambiguous' | grep 'GH' | grep 'FJ')" && echo 1 || echo 0)" \
	"$(errtext from-history --ref '#40')"
out="$(run from-history --ref '#40' --tracker gh)"
check "…which an explicit --tracker settles" "$([ "$(field qualified "$out")" = GH-40 ] && echo 1 || echo 0)" "$out"
jq '(.issueTrackers[] | select(.ref == "FJ")) |= (.repo = "tickets" | del(.credentialRef))' "$SANDBOX/config.good" >"$CFG"
out="$(run from-history --ref '#40')"
check "no code-repo tracker: a bare #N maps to the legacy tracker" "$([ "$(field qualified "$out")" = GH-40 ] && echo 1 || echo 0)" "$out"
jq 'del(.legacyIssueTracker)' "$SANDBOX/config.good" >"$CFG"
printf '{"schemaVersion":1,"branches":{},"manifests":{}}\n' >"$BIND"
out="$(run from-history --ref '#40')"
check "a never-migrated repo: a bare #N is its code-repo tracker's" "$([ "$(field qualified "$out")" = FJ-40 ] && echo 1 || echo 0)" "$out"
cp "$SANDBOX/config.good" "$CFG"
cp "$SANDBOX/bind.good" "$BIND"

printf '\033[1m── code PR issue line ──\033[0m\n'
fj='{"tracker":"FJ","number":"3","qualified":"FJ-3","display":"FJ-3","branchPrefix":"fj-3"}'
gh='{"tracker":"GH","number":"3","qualified":"GH-3","display":"GH-3","branchPrefix":"gh-3"}'
jir='{"tracker":"JIR","number":"PROJ-3","qualified":"JIR-3","display":"JIR-3","branchPrefix":"jir-3"}'
check "the code repository's own issue gets Closes #N on a closing stage" "$([ "$(run pr-reference --identity "$fj" --closes true)" = 'Closes #3' ] && echo 1 || echo 0)"
check "…and the non-closing Ready #N otherwise" "$([ "$(run pr-reference --identity "$fj" --closes false)" = 'Ready #3' ] && echo 1 || echo 0)"
out="$(run pr-reference --identity "$gh" --closes true)"
check "a cross-tracker issue can never close the same-number code issue" "$([ "$out" = "$(tracks GH-3)" ] && echo 1 || echo 0)" "$out"
check "the qualified id is a code span, so GitHub cannot autolink it to the code repo (#247)" \
	"$(case "$out" in *"$(tracks GH-3 | cut -d' ' -f2)") echo 1 ;; *) echo 0 ;; esac)" "$out"
check "…while Closes #N stays a live keyword (no backticks)" \
	"$([ "$(run pr-reference --identity "$fj" --closes true | tr -d "$BT")" = "$(run pr-reference --identity "$fj" --closes true)" ] && echo 1 || echo 0)"
check "a Jira issue gets its qualified id, not a #N" "$([ "$(run pr-reference --identity "$jir" --closes true)" = "$(tracks JIR-3)" ] && echo 1 || echo 0)"
printf '{"code":{"repo":"other"}}\n' >"$R/.flightdirector/config.local.json"
check "eligibility uses the effective (local-override) code repository" "$([ "$(run pr-reference --identity "$fj" --closes true)" = "$(tracks FJ-3)" ] && echo 1 || echo 0)"
rm -f "$R/.flightdirector/config.local.json"
jq '(.issueTrackers[] | select(.ref == "FJ")) |= (.api = "https://other.example.com/api/v1" | del(.credentialRef))' "$SANDBOX/config.good" >"$CFG"
check "same owner/repo on another host is not the same repository" "$([ "$(run pr-reference --identity "$fj" --closes true)" = "$(tracks FJ-3)" ] && echo 1 || echo 0)"
cp "$SANDBOX/config.good" "$CFG"

printf '\033[1m── Windows: native jq.exe writes CRLF ──\033[0m\n'
# Emulate MSYS with a native jq.exe: OSTYPE=msys switches _portable.sh's shim on, and a
# jq on PATH ending every line in \r stands in for jq.exe's text-mode stdout. The helper
# must strip it like every other entrypoint does — or the schema check, the tracker
# lookups and the pr-reference comparison fail on an invisible byte. Outputs are
# compared byte-exact: `$(…)` strips the newline but keeps a \r.
CRLF_BIN="$SANDBOX/crlf-bin"; mkdir -p "$CRLF_BIN"
REAL_JQ="$(command -v jq)"
cat >"$CRLF_BIN/jq" <<SH
#!/usr/bin/env bash
"$REAL_JQ" "\$@" | awk '{ printf "%s\r\n", \$0 }'; exit \${PIPESTATUS[0]}
SH
chmod +x "$CRLF_BIN/jq"
msys() { (cd "$R" && PATH="$CRLF_BIN:$PATH" OSTYPE=msys "$IDENTITY" "$@"); }
msys_status() { local rc=0; msys "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
has_cr() { grep -q '\\r' <<<"$(od -c)"; }
check "the emulated jq really emits CR" "$(printf '1\n' | "$CRLF_BIN/jq" . | has_cr && echo 1 || echo 0)"
cp "$SANDBOX/bind.good" "$BIND"
out="$(msys from-branch --branch feature/gh-1-second 2>&1 || true)"
check "msys: a qualified branch resolves, CR-free" \
	"$([ "$out" = '{"tracker":"GH","number":"1","qualified":"GH-1","display":"GH-1","branchPrefix":"gh-1"}' ] && echo 1 || echo 0)" "$out"
out="$(msys from-branch --branch feature/12-old-work 2>&1 || true)"
check "msys: a bound legacy branch resolves" \
	"$([ "$out" = '{"tracker":"FJ","number":"12","qualified":"FJ-12","display":"FJ-12","branchPrefix":"fj-12"}' ] && echo 1 || echo 0)" "$out"
out="$(msys from-branch --branch bugfix/17-unbound 2>&1 || true)"
check "msys: an unbound legacy branch uses the legacy default" \
	"$([ "$out" = '{"tracker":"FJ","number":"17","qualified":"FJ-17","display":"FJ-17","branchPrefix":"fj-17"}' ] && echo 1 || echo 0)" "$out"
out="$(msys from-branch --branch feature/12-old-work --tracker fj 2>&1 || true)"
check "msys: an alias/case lookup compares clean refs" \
	"$([ "$out" = '{"tracker":"FJ","number":"12","qualified":"FJ-12","display":"FJ-12","branchPrefix":"fj-12"}' ] && echo 1 || echo 0)" "$out"
out="$(msys from-manifest --run-id run1 --entry 5 2>&1 || true)"
check "msys: a legacy manifest entry resolves" "$([ "$out" = '{"tracker":"FJ","number":"5","qualified":"FJ-5","display":"FJ-5","branchPrefix":"fj-5"}' ] && echo 1 || echo 0)" "$out"
out="$(msys from-history --ref '#40' 2>&1 || true)"
check "msys: a bare history reference resolves" "$([ "$out" = '{"tracker":"FJ","number":"40","qualified":"FJ-40","display":"FJ-40","branchPrefix":"fj-40"}' ] && echo 1 || echo 0)" "$out"
check "msys: a non-issue branch is still 'no identity' (3)" "$([ "$(msys_status from-branch --branch release/0.1.0)" = 3 ] && echo 1 || echo 0)"
check "msys: remember stores a verified identity" "$(ok msys remember --branch feature/gh-2-msys --identity '{"tracker":"GH","number":"2","qualified":"GH-2","display":"GH-2","branchPrefix":"gh-2"}')"
check "msys: the bindings file stays CR-free" "$(has_cr <"$BIND" && echo 0 || echo 1)"
out="$(msys pr-reference --identity "$fj" --closes true 2>&1 || true)"
check "msys: the code repository's own issue still gets Closes #N" "$([ "$out" = 'Closes #3' ] && echo 1 || echo 0)" "$out"
out="$(msys pr-reference --identity "$gh" --closes true 2>&1 || true)"
check "msys: another tracker's issue still gets Tracks" "$([ "$out" = "$(tracks GH-3)" ] && echo 1 || echo 0)" "$out"
cp "$SANDBOX/bind.good" "$BIND"

printf '\033[1m── schema guard ──\033[0m\n'
jq '.schemaVersion = 2 | del(.issueTrackers, .legacyIssueTracker) | .issues = {"backend":"forgejo"}' "$SANDBOX/config.good" >"$CFG"
check "a pre-schema-3 config is refused with a reconcile hint" \
	"$(grep -q 'flight reconcile' <<<"$(errtext from-branch --branch feature/fj-1-x)" && echo 1 || echo 0)"
cp "$SANDBOX/config.good" "$CFG"

[ "$fail" -gt 0 ] && colour=$'\033[0;31m' || colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
