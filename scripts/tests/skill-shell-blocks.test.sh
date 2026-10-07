#!/usr/bin/env bash
# Contract tests for flight/references/skill-shell-blocks.md (FJ-226): one check per rule that
# reference states, run over the shell in every fenced block of every markdown file the plugin
# ships.
#
# This is deliberately NOT a general linter. Extracting the blocks and running shellcheck on them
# would have caught about one of the seventeen #209 findings: those were semantic (a slash in a
# file name is valid shell, a `# STOP` comment is a comment). Each check below instead pins one
# named shape from the reference, is written with the rule, and proves it can fire: the fixture
# section feeds it the defect it exists for, and a check that stays silent on its own defect fails
# the suite. Pseudo-code lines (`for each … :`, `record …`, `<placeholder>`) pass through
# untouched; no check keys on them. The gates themselves are pinned harder, by running the real
# blocks: promote-gate, promote-branches-gate and to-test-gate.test.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# One awk pass per file. Shell blocks are fences with no language, `bash` or `sh`, indented or
# not; json/jsonc/markdown blocks are skipped. Each finding prints as rule⇥file:line⇥text; each
# promotion site (rule 3) also prints as site⇥file:line, so the test can hold the stated count.
# `.gitattributes` gives *.md native line endings, so the MSYS leg reads CRLF: the \r goes first.
# shellcheck disable=SC2016 # the program is awk, and its $ are awk's
CHECK='
function code(s) {   # the shell on a line: whole-line and " # " comments go
	if (s ~ /^[ \t]*#/) return ""
	sub(/[ \t]#([ \t].*)?$/, "", s)
	return s
}
function report(rule, line, text) { printf "%s\t%s:%d\t%s\n", rule, F, line, text }
function arm(   k) { k = ++arms[d]; S[d, k] = 0; M[d, k] = 0; A[d, k] = 0 }
function account(c, raw, line,   t) {   # one body line of the innermost if-arm
	if (raw ~ /STOP|[Hh]alt/) { S[d, arms[d]] = 1; SL[d, arms[d]] = line; ST[d, arms[d]] = raw }
	if (c ~ /(^|[ \t;])(exit|return|continue|break)([ \t;]|$)/) M[d, arms[d]] = 1
	t = c; sub(/^[ \t]+/, "", t); sub(/^then[ \t]*/, "", t)
	if (t != "" && t !~ /^(echo|printf|record|:)([ \t]|$)/ && t !~ /^(then|do|done)$/) A[d, arms[d]] = 1
}
function judge(   k, j, other) {   # rule 2, at the fi: a STOP arm needs a mechanism, or the
	for (k = 1; k <= arms[d]; k++) {   # guarded work has to sit in another arm of this if
		if (!S[d, k] || M[d, k]) continue
		other = 0
		for (j = 1; j <= arms[d]; j++) if (j != k && A[d, j]) other = 1
		if (!other) report("stop", SL[d, k], ST[d, k])
	}
}
function flush(   i, j, m, w, c, raw, loop, gated, incond, ingrp, gs, gm, gl, gt) {
	loop = 0; gated = 0; d = 0; incond = 0; ingrp = 0
	for (i = 1; i <= n; i++) if (code(L[i]) ~ /(^|[ \t;])(for|while|until)[ \t]/) loop = 1
	for (i = 1; i <= n; i++) {
		raw = L[i]; c = code(raw)
		# Rule 1: a file name built from a ref name. A word that names a file (under $SCRATCH,
		# a redirect target, a worktree path, a log/json/md/txt) may not carry a ref-valued
		# variable whole; ${B#feature/} is the flattened form and passes.
		m = split(c, w, /[ \t]+/)
		for (j = 1; j <= m; j++)
			if (w[j] ~ /SCRATCH|^>|\.worktrees\/|\.(log|json|md|txt)/ \
			    && w[j] ~ /\$\{?(B|BRANCH|INT|BASE)\}?([^A-Za-z0-9_#}]|$)/)
				report("flatten", N[i], raw)
		# Rule 4: continue/break with no loop in the same block falls through to the next line.
		if (!loop && c ~ /(^|[ \t;])(continue|break)([ \t;]|$)/) report("loop", N[i], raw)
		# Rule 5: a command hidden in a string.
		if (c ~ /(^|[ \t;|&(])(ba)?sh -c "\$/ || c ~ /(^|[ \t;])eval[ \t]/) report("string", N[i], raw)
		# Rule 6: bash 4 features; the BSD and MSYS legs run bash 3.2.
		if (c ~ /declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}|&>>|\|&/) report("bash32", N[i], raw)
		# Rule 3: in a promoting skill, every push and every `pr open` comes after the gate.
		if (promo && c != "") {
			if (c ~ /preflight (run|check)/) gated = 1
			if (c ~ /pr open/ || c ~ /git[ \t].*[ \t]push([ \t]|$)/) {
				printf "site\t%s:%d\n", F, N[i]
				if (!gated) report("guard", N[i], raw)
			}
		}
		# Rule 2, `||` arms: the rest of the line, or a { … } group to its closing brace.
		if (ingrp || c ~ /\|\|/) {
			if (!ingrp) {
				gt = raw; sub(/^.*\|\|/, "", gt); gl = N[i]; gs = 0; gm = 0
				ingrp = (gt ~ /^[ \t]*\{/ && gt !~ /\}/)
			} else gt = raw
			if (gt ~ /STOP|[Hh]alt/) gs = 1
			if (code(gt) ~ /(^|[ \t;{])(exit|return|continue|break)([ \t;}]|$)/) gm = 1
			if (ingrp && code(gt) ~ /\}/) ingrp = 0
			if (!ingrp && gs && !gm) report("stop", gl, raw)
			if (!ingrp) gs = 0
		}
		# Rule 2, if-arms. Condition lines run up to `then` and are not part of any arm.
		if (c ~ /^[ \t]*if[ \t]/) {
			if (d > 0 && !incond) A[d, arms[d]] = 1
			d++; arms[d] = 0; arm(); incond = (c !~ /(^|[ \t;])then([ \t]|$)/)
		} else if (d > 0 && c ~ /^[ \t]*elif[ \t]/) {
			arm(); incond = (c !~ /(^|[ \t;])then([ \t]|$)/)
		} else if (d > 0 && c ~ /^[ \t]*else([ \t]|$)/) {
			arm(); sub(/^[ \t]*else/, "", c); sub(/^[ \t]*else/, "", raw); account(c, raw, N[i])
		} else if (d > 0 && c ~ /^[ \t]*fi([ \t;)]|$)/) {
			judge(); d--
		} else if (d > 0 && incond) {
			if (c ~ /(^|[ \t;])then([ \t]|$)/) incond = 0
		} else if (d > 0) account(c, raw, N[i])
	}
}
FNR == 1 { promo = (F ~ /promoting-/) }
/^[ \t]*```/ {
	if (!inb) {
		lang = $0; sub(/^[ \t]*```/, "", lang); gsub(/[ \t]/, "", lang)
		inb = 1; sh = (lang == "" || lang == "bash" || lang == "sh"); n = 0
	} else { inb = 0; if (sh) flush() }
	next
}
inb { L[++n] = $0; N[n] = FNR }
'

# check ROOT FILE… → findings and sites for the given files, paths shown relative to ROOT.
check() {
	local root="$1" f; shift
	for f in "$@"; do
		tr -d '\r' < "$f" | awk -v F="${f#"$root"/}" "$CHECK"
	done
}

fail=0
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

# --- Every check fires on the shape it exists for -----------------------------------------
# Each fixture is one defect from the reference (most are the #209 / #223 / FJ-231 originals),
# written as a skill would carry it. A check that misses its own fixture is a check that would
# have passed the defect, so it fails here rather than going green over a broken skill.
FIX="$SANDBOX/fix"
mkdir -p "$FIX/promoting-x"
fixture() {   # NAME RULE: the fenced block on stdin must draw a RULE finding and no other
	local file="$FIX/$1.md"
	[ "$2" = guard ] && file="$FIX/promoting-x/$1.md"
	{ printf '```bash\n'; cat; printf '```\n'; } >"$file"
	local got
	got="$(check "$FIX" "$file" | grep -v '^site' | cut -f1 | sort -u | tr '\n' ' ')"
	[ "$got" = "$2 " ] || bad "fixture $1: expected a '$2' finding, got '${got:-none}'"
}

# Rule 1 (#223): the log file named from a branch with a slash in it.
fixture flatten-log flatten <<'MD'
if ( cd "$WT" && flight preflight run ) >"$SCRATCH/preflight-$BRANCH.log" 2>&1; then
	echo ok
fi
MD
fixture flatten-flag flatten <<'MD'
flight ci watch --pr 7 --status-file "$SCRATCH/ls-ci-${BRANCH}.json"
MD
# Rule 2 (#209): the issue's own example, a STOP comment in the else and the merge after the fi.
fixture stop-else stop <<'MD'
if flight preflight check --worktree "$WT" --verdict "$V"; then
	echo ok
else
	echo bad
	# STOP. Do not merge.
fi
git merge --no-ff "$BRANCH"
MD
# Rule 2: a guard alone in its block, with the guarded command in the next one (the old
# promoting-a-branch source guard).
fixture stop-if stop <<'MD'
if [ "$(git -C "$WT" rev-parse HEAD)" != "$(git -C "$WT" rev-parse "origin/$BRANCH")" ]; then
	# STOP — local is ahead of origin. Push first.
	echo "local differs from origin — push first" >&2
fi
MD
# Rule 2: an || arm that only prints (the old promoting-branches pre-push re-check).
fixture stop-or stop <<'MD'
[ "$(git rev-parse origin/develop)" = "$(git merge-base develop origin/develop)" ] || {
	echo "origin moved during the batch — STOP and report" >&2; }
git push
MD
# Rule 3: a push in a promoting skill that no gate verdict stands in front of.
fixture guard-push guard <<'MD'
git -C "$MAIN" merge --no-ff "$BRANCH" &&
	git -C "$MAIN" push
MD
# Rule 4 (FJ-231): a continue with no loop around it falls through to the push.
fixture loop-continue loop <<'MD'
if ! flight preflight check --worktree "$WT" --verdict "$V"; then
	echo "group skipped" >&2
	continue
fi
git push -u origin "$INT"
MD
# Rule 5 (FJ-307): the gate run as a string.
fixture string-gate string <<'MD'
GATE="$(flight config '.code.preflight')"
sh -c "$GATE"
MD
# Rule 6: a bash 4 feature.
fixture bash32 bash32 <<'MD'
mapfile -t BRANCHES < <(git branch --format='%(refname:short)')
MD

# The compliant forms of the same shapes draw nothing: a check that fires on them would teach
# authors to route around it.
mkdir -p "$FIX/good/promoting-y"
cat >"$FIX/good/promoting-y/SKILL.md" <<'MD'
```bash
SAFE_BRANCH="$(printf '%s' "$BRANCH" | tr '/' '-')"
flight preflight run --worktree "$WT" --log "$SCRATCH/preflight-$SAFE_BRANCH.log"
git -C "$MAIN" worktree remove ".worktrees/${B#feature/}"
if flight preflight check --worktree "$WT" --verdict "$SCRATCH/preflight-verdict-$SAFE_BRANCH"; then
	git -C "$MAIN" merge --no-ff "$BRANCH" && git -C "$MAIN" push
else
	echo "not merging, not pushing — STOP and report" >&2
fi
for B in $(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads/feature); do
	[ -n "$B" ] || continue
done
if [ "$T" -ge 1800 ]; then
	# STOP waiting: a lock nobody released.
	exit 0
fi
```

```json
{ "note": "STOP — json is not shell", "continue": true }
```
MD
out="$(check "$FIX/good" "$FIX/good/promoting-y/SKILL.md" | grep -v '^site' || true)"
[ -z "$out" ] || bad "compliant shapes drew findings:
$out"

# --- The plugin's own markdown ----------------------------------------------------------------
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(find "$REPO_ROOT/flight" -name '*.md' | sort)
[ "${#FILES[@]}" -gt 10 ] || bad "found only ${#FILES[@]} markdown files under flight/"
check "$REPO_ROOT" "${FILES[@]}" >"$SANDBOX/real"

if grep -v '^site' "$SANDBOX/real" >"$SANDBOX/findings"; then
	bad "skill shell breaks a rule in flight/references/skill-shell-blocks.md:"
	sed 's/^/    /' "$SANDBOX/findings"
fi

# Rule 3 states its count. These are the places a promotion leaves the machine: promoting-a-
# branch's two direct-hop merges and its `pr open`, promoting-branches' direct-hop push and its
# group `pr open` with the push in front of it. A site added or removed changes the number, and
# the change should be a decision someone made, with the guard checked by hand at the new site.
sites="$(grep -c '^site' "$SANDBOX/real" || true)"
[ "$sites" = 6 ] || { bad "expected 6 promotion sites (push / pr open), found $sites:"; grep '^site' "$SANDBOX/real" | sed 's/^/    /'; }

# Every rule the reference states has a check above; every check names a rule it states.
REF="$REPO_ROOT/flight/references/skill-shell-blocks.md"
for rule in flatten stop guard loop string bash32; do
	grep -q "^### .*(\`$rule\`)" "$REF" || bad "the reference has no rule headed (\`$rule\`)"
done
[ "$(grep -c '^### ' "$REF")" = 6 ] || bad "the reference states a rule this test does not check"

[ "$fail" = 0 ] || exit 1
printf 'skill shell block contract tests passed\n'
