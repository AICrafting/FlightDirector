#!/usr/bin/env bash
# Unit tests for the dispatcher's token resolution: the backend-neutral
# FLIGHT_TOKEN env override, the legacy FORGEJO_TOKEN name, LS_TOKEN taking
# precedence over both, and the secrets file as the fallback. The network is
# stubbed with a fake `curl` on PATH that records the Authorization header.
#
# It also covers what #177 added on top of that order: the winning source is
# reported by `auth check` (LS_TOKEN_SOURCE), and the legacy FORGEJO_TOKEN
# shadowing a present secrets file that holds a DIFFERENT token says so on
# stderr. The order itself is unchanged, which the five original cases below
# still assert.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DISP="$REPO_ROOT/flight/scripts/flight"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m\n' "$1"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
R="$SANDBOX/repo"; mkdir -p "$R/.flightdirector"; git -C "$R" init -q
cat >"$R/.flightdirector/config.json" <<'EOF'
{"schemaVersion":2,"code":{"backend":"forgejo","owner":"acme","repo":"widget",
 "api":"https://forge.example/api/v1","stages":[{"name":"main"}]},"labels":{}}
EOF
echo '{"code":{"token":"from-secrets"}}' >"$R/.flightdirector/secrets.json"

# Fake curl: record every -H header, answer 200 with an empty JSON array.
FAKE_DIR="$SANDBOX/bin"; mkdir -p "$FAKE_DIR"
HDRS="$SANDBOX/headers"
cat >"$FAKE_DIR/curl" <<EOF
#!/usr/bin/env bash
outfile=""; want_code=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -H) printf '%s\n' "\$2" >>"$HDRS"; shift 2 ;;
    -o) outfile="\$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "\$outfile" ]; then printf '[]' >"\$outfile"; else printf '[]'; fi
[ "\$want_code" = 1 ] && printf '200'
exit 0
EOF
chmod +x "$FAKE_DIR/curl"

run() {	# run [VAR=value …] — invokes `issues list` with the given env, returns the token sent
	rm -f "$HDRS"
	(cd "$R" && env -u LS_TOKEN -u FLIGHT_TOKEN -u FORGEJO_TOKEN PATH="$FAKE_DIR:$PATH" "$@" \
		"$DISP" issues list --state open --limit 5 >/dev/null 2>"$SANDBOX/err") || { cat "$SANDBOX/err" >&2; return 1; }
	sed -n '/^Authorization: token /{s///p;q;}' "$HDRS"	# first match only; no `| head` (SIGPIPE, #110)
}

check "secrets file is the fallback when no env var is set" \
	"$([ "$(run)" = from-secrets ] && echo 1 || echo 0)"
check "FLIGHT_TOKEN overrides the secrets file" \
	"$([ "$(run FLIGHT_TOKEN=from-flight)" = from-flight ] && echo 1 || echo 0)"
check "legacy FORGEJO_TOKEN still overrides the secrets file" \
	"$([ "$(run FORGEJO_TOKEN=from-forgejo)" = from-forgejo ] && echo 1 || echo 0)"
check "FLIGHT_TOKEN wins over FORGEJO_TOKEN" \
	"$([ "$(run FLIGHT_TOKEN=from-flight FORGEJO_TOKEN=from-forgejo)" = from-flight ] && echo 1 || echo 0)"
check "LS_TOKEN wins over both" \
	"$([ "$(run LS_TOKEN=from-ls FLIGHT_TOKEN=from-flight FORGEJO_TOKEN=from-forgejo)" = from-ls ] && echo 1 || echo 0)"

# --- #177: the resolved source is reported ---------------------------------
# `auth check` is the verb that has to name its source. The fake curl answers
# 200/`[]` for every probe, so identity "passes" with empty fields — enough for
# the adapter to print its `authenticates` line, which is all we read here.
echo '{"code":{"token":"from-candidate"}}' >"$R/cand-secrets.json"

auth_check() {	# auth_check [VAR=value …] — `flight auth check` against the live secrets file
	(cd "$R" && env -u LS_TOKEN -u FLIGHT_TOKEN -u FORGEJO_TOKEN -u LS_SECRETS_FILE \
		PATH="$FAKE_DIR:$PATH" "$@" "$DISP" auth check 2>"$SANDBOX/err") || true
}
auth_check_secrets() {	# auth_check_secrets FILE [VAR=value …] — the same, against a CANDIDATE file
	local f="$1"; shift
	(cd "$R" && env -u LS_TOKEN -u FLIGHT_TOKEN -u FORGEJO_TOKEN -u LS_SECRETS_FILE \
		PATH="$FAKE_DIR:$PATH" "$@" "$DISP" auth check --secrets "$f" 2>"$SANDBOX/err") || true
}
from() { sed -n 's/.*(from \(.*\))$/\1/p' | sed -n '1p'; }	# first match only; no `| head` (SIGPIPE, #110)

# A function, not an inline `case` inside $(…): bash 3.2 (the macOS CI leg) ends
# the substitution at the pattern's own `)`. Same reason as quiet()/noted() below.
names_secrets() { case "$1" in */.flightdirector/secrets.json) echo 1 ;; *) echo 0 ;; esac; }

named="$(auth_check | from)"
check "auth check names the secrets file when it is the source" \
	"$(names_secrets "$named")"
check "the path it names resolves from the main checkout too" \
	"$( (cd "$R" && [ -f "$named" ]) && echo 1 || echo 0)"
# shellcheck disable=SC2016  # the literal env-var NAME is what the output must contain
check "auth check names \$FORGEJO_TOKEN when the legacy env var is the source" \
	"$([ "$(auth_check FORGEJO_TOKEN=from-forgejo | from)" = '$FORGEJO_TOKEN' ] && echo 1 || echo 0)"
# shellcheck disable=SC2016  # the literal env-var NAME is what the output must contain
check "auth check names the winner (\$FLIGHT_TOKEN) when both env vars are set" \
	"$([ "$(auth_check FLIGHT_TOKEN=from-flight FORGEJO_TOKEN=from-forgejo | from)" = '$FLIGHT_TOKEN' ] && echo 1 || echo 0)"
# shellcheck disable=SC2016  # the literal env-var NAME is what the output must contain
check "auth check names \$LS_TOKEN when it outranks the rest" \
	"$([ "$(auth_check LS_TOKEN=from-ls FLIGHT_TOKEN=from-flight | from)" = '$LS_TOKEN' ] && echo 1 || echo 0)"
check "auth check --secrets names the candidate file, not a shadowing env var" \
	"$([ "$(auth_check_secrets cand-secrets.json FORGEJO_TOKEN=from-forgejo | from)" = "cand-secrets.json" ] && echo 1 || echo 0)"

# --- #177: the shadow note -------------------------------------------------
# It rides the every-verb path, so it is deliberately narrow: ONLY the legacy
# FORGEJO_TOKEN winning over a present secrets file that holds something else.
# A deliberate LS_TOKEN/FLIGHT_TOKEN override must not nag a two-forge setup on
# every single call; `auth check` names the source for those, which is enough.
# `issues list` is used here, not `auth check`, to prove it is the general path.
# Both of these wrap their `case` in a function on purpose: bash 3.2 (the macOS CI
# leg) mis-parses a `case` written inline inside `$(…)`, ending the substitution at
# the pattern's own `)`. Quoting the pattern does not help; only the function does.
quiet() { case "$(cat "$SANDBOX/err")" in *overrides*) echo 0 ;; *) echo 1 ;; esac; }
# shellcheck disable=SC2016  # the literal env-var NAME is what the output must contain
noted() { case "$(cat "$SANDBOX/err")" in *'$FORGEJO_TOKEN is set and overrides '*'/.flightdirector/secrets.json'*) echo 1 ;; *) echo 0 ;; esac; }

run FORGEJO_TOKEN=from-forgejo >/dev/null
check "the legacy FORGEJO_TOKEN shadowing a differing secrets file notes it on stderr" "$(noted)"
run FORGEJO_TOKEN=from-secrets >/dev/null
check "a legacy env token that merely repeats the secrets file stays quiet" "$(quiet)"
run FLIGHT_TOKEN=from-flight >/dev/null
check "a deliberate FLIGHT_TOKEN override stays quiet on the every-verb path" "$(quiet)"
run LS_TOKEN=from-ls >/dev/null
check "a deliberate LS_TOKEN override stays quiet on the every-verb path" "$(quiet)"
run >/dev/null
check "a secrets-only setup stays quiet" "$(quiet)"
auth_check_secrets cand-secrets.json FORGEJO_TOKEN=from-forgejo >/dev/null
check "--secrets stays quiet: the env is already out of the picture" "$(quiet)"

# --- #196: the named path resolves from a LINKED WORKTREE ------------------
# The dominant invocation context, per AGENTS.md: every issue is worked in its own
# .worktrees/<N>-<slug>. The secrets file is gitignored, so it exists ONLY in the
# main checkout — a repo-relative name is a path the reader cannot cat from there,
# which is exactly the 401 wild-goose-chase #177 set out to end. The assertion is
# resolvability, not string equality: `git rev-parse --git-common-dir` realpaths
# its answer, and on macOS $TMPDIR is a /var → /private/var symlink, so comparing
# the printed path against "$R/…" would fail on that CI leg for the wrong reason.
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" worktree add -q "$R/.worktrees/x" -b x
wt_named="$( (cd "$R/.worktrees/x" && env -u LS_TOKEN -u FLIGHT_TOKEN -u FORGEJO_TOKEN \
	-u LS_SECRETS_FILE PATH="$FAKE_DIR:$PATH" "$DISP" auth check 2>/dev/null) | from)"

check "auth check from a linked worktree still names the secrets file" \
	"$(names_secrets "$wt_named")"
# The guard that matters: the relative form does NOT resolve from the worktree, so
# a $sec_rel regression fails here even though the case above would still pass.
check "the path it names resolves from the worktree's own directory" \
	"$( (cd "$R/.worktrees/x" && [ -f "$wt_named" ]) && echo 1 || echo 0)"
check "…and the relative form genuinely would not have (the test can fail)" \
	"$( (cd "$R/.worktrees/x" && [ ! -f ".flightdirector/secrets.json" ]) && echo 1 || echo 0)"

# Summary: plain when nothing failed, red when something did (#123).
[ "$fail" -gt 0 ] && summary_colour=$'\033[0;31m' || summary_colour=''
printf '\n%sPassed: %d  Failed: %d\033[0m\n' "$summary_colour" "$pass" "$fail"
[ "$fail" -eq 0 ]
