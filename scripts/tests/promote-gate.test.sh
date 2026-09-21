#!/usr/bin/env bash
# Behavioural tests for promoting-a-branch's repo preflight gate (#209, #223, #228).
#
# The gate is shell inside fenced blocks of a SKILL.md, which no linter enters (#226), and it
# has now failed three ways that every wording check passed:
#   #223  a PASSING gate read as red (a slash in the log filename).
#   #228  an ABSENT gate read as red (the green default lived in a block the skill said to skip).
#   !232  review: a RED gate read as green (the default moved to Step 1, and restating Step 1 to
#         recover $MAIN in a fresh shell re-bound it over Step 4b's verdict).
# So this does not grep the prose. It lifts the REAL blocks out of the skill and runs them the way
# a fresh-shell harness does: every block in its own shell, with the real Step 1 block restated
# on top, against a fake `flight` and `git`. Only things that survive a tool call may carry the
# verdict (the config, a file under $SCRATCH); anything a variable carries is lost here, and
# anything Step 1 binds is re-bound before every guard.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$REPO_ROOT/flight/skills/promoting-a-branch/SKILL.md"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export SANDBOX   # the fakes below read it
mkdir -p "$SANDBOX/bin" "$SANDBOX/scratch" "$SANDBOX/main/.git" "$SANDBOX/wt"

# The first fenced block containing $2, placeholders made runnable. Line-based on purpose: a
# multi-character RS is not portable awk. `.gitattributes` gives *.md native line endings, so
# the MSYS leg reads CRLF and the \r has to go. awk reads to the END rather than exiting at the
# match: an early exit SIGPIPEs `tr`, which under `pipefail` fails the script.
block() {
	tr -d '\r' < "$SKILL" | awk -v want="$2" '
		found { next }
		/^```/ { if (inb) { if (hit) { printf "%s", buf; found = 1 } inb = 0 }
		         else { inb = 1; buf = ""; hit = 0 }
		         next }
		inb { buf = buf $0 "\n"; if (index($0, want)) hit = 1 }
		END { exit !found }
	' | sed -e 's/<target>/develop/g' -e 's/<your-model-id>/test-model/g' > "$SANDBOX/$1.sh" \
		|| { echo "FAIL: no fenced block containing '$2' in promoting-a-branch/SKILL.md"; exit 1; }
}
block step1 'git rev-parse --git-common-dir'
block step4b 'PFLOG='
block case1 'Merge and push without touching'
block case2 'worktree add --detach'
block pr 'flight pr open --head'

cat >"$SANDBOX/bin/flight" <<'SH'
#!/usr/bin/env bash
[ -f "$SANDBOX/config-unreadable" ] && exit 1
case "$*" in
	"pr open"*) echo "DID-PR" >>"$SANDBOX/actions"; printf '7\thttp://example.invalid/7\n' ;;
	*preflight*) cat "$SANDBOX/gate" ;;
	*) echo '[]' ;;
esac
SH
cat >"$SANDBOX/bin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
	*"rev-parse --show-toplevel"*) echo "$SANDBOX/wt" ;;
	*"rev-parse --git-common-dir"*) echo "$SANDBOX/main/.git" ;;
	*"branch --show-current"*) echo "feature/228-some-slug" ;;
	# Path-dependent on purpose. $MAIN and $WT differ on the commonest hop (feature -> develop
	# with the main checkout on develop), and a new commit on the feature branch leaves $MAIN's
	# tip where it was. A stamp or guard that reads $MAIN would accept an old pass for code the
	# gate never saw, so only the worktree being judged may answer with the branch's sha.
	*"/wt rev-parse HEAD"*) cat "$SANDBOX/sha" ;;
	*"rev-parse HEAD"*) echo "main-tip-never-moves" ;;
	*"merge --no-ff"*) echo "DID-MERGE" >>"$SANDBOX/actions" ;;
esac
exit 0
SH
chmod +x "$SANDBOX/bin/flight" "$SANDBOX/bin/git"

# One tool call: a new shell, Step 1 restated, then the block. $SCRATCH is the session
# scratchpad, which the agent knows rather than derives, so it is given, not carried.
call() {
	# Real newlines between the pieces: $(cat) strips the trailing one, and a space would glue
	# Step 1's last assignment onto the block's first command as an env prefix, so the binding
	# would silently never reach the rest of the block.
	PATH="$SANDBOX/bin:$PATH" bash -c "SCRATCH='$SANDBOX/scratch'
$(cat "$SANDBOX/step1.sh")
$(cat "$SANDBOX/$1.sh")" >>"$SANDBOX/out" 2>&1 || true
}
fresh() {   # $1 = the configured gate command ('' = key absent)
	rm -rf "$SANDBOX/scratch" "$SANDBOX/actions" "$SANDBOX/out" "$SANDBOX/config-unreadable"
	mkdir -p "$SANDBOX/scratch"
	printf '%s' "$1" >"$SANDBOX/gate"
	echo aaa111 >"$SANDBOX/sha"
	: >"$SANDBOX/actions"; : >"$SANDBOX/out"
}
acted()   { [ -s "$SANDBOX/actions" ] || { echo "FAIL: $1: should have promoted"; cat "$SANDBOX/out"; exit 1; }; }
refused() {
	[ ! -s "$SANDBOX/actions" ] || { echo "FAIL: $1: PROMOTED, must refuse"; cat "$SANDBOX/out"; exit 1; }
	# A refusal must say why: silence is indistinguishable from a promotion that did nothing.
	grep -q "$2" "$SANDBOX/out" || { echo "FAIL: $1: refused without saying '$2'"; cat "$SANDBOX/out"; exit 1; }
}

# `pr` is the site that matters (the commoner hop), but every site gets every case: a gate
# honoured at two of three sites is a gate some repos do not have.
for SITE in case1 case2 pr; do
	# #228: the key is absent. Promotes whether Step 4b is skipped, as its prose allows, or run.
	fresh '';      call "$SITE";                               acted   "$SITE ungated, 4b skipped"
	fresh '';      call step4b; call "$SITE";                  acted   "$SITE ungated, 4b run"
	fresh 'true';  call step4b; call "$SITE";                  acted   "$SITE green gate"
	# !232 review: red, and Step 1 is restated before the guard, as it must be to have $MAIN.
	fresh 'false'; call step4b; call "$SITE";                  refused "$SITE red gate" 'not green'
	# A configured gate nobody ran is not a pass.
	fresh 'true';  call "$SITE";                               refused "$SITE gated, 4b never run" 'not green'
	# A pass belongs to the commit it judged, not to the branch.
	fresh 'true';  call step4b; echo bbb222 >"$SANDBOX/sha"
	               call "$SITE";                               refused "$SITE stale pass, new commit" 'not green'
	# "Could not ask" must not read as "no gate configured".
	fresh 'true';  call step4b; touch "$SANDBOX/config-unreadable"
	               call "$SITE";                               refused "$SITE config unreadable" 'could not read'
	# The latest run is the verdict: green, then red on the SAME commit (a flaky suite, a
	# changed environment) must not leave the earlier pass standing. 4b closes this twice over,
	# by clearing the old verdict and by writing `fail`, and this case pins the PAIR: either
	# alone still passes it, only losing both trips it. Keep both; the `rm -f` also covers a
	# run aborted before any verdict is written, which cannot be staged from inside the gate.
	fresh 'true';  call step4b; printf 'false' >"$SANDBOX/gate"
	               call step4b; call "$SITE";                  refused "$SITE green, then red re-run" 'not green'
	# Same session, branch fixed: the earlier red must not block the retry.
	fresh 'false'; call step4b; printf 'true' >"$SANDBOX/gate"
	               call step4b; call "$SITE";                  acted   "$SITE red, fixed, re-run"
done

# #223: the log and the verdict are FILES named from a branch with a slash in it.
fresh 'false'; call step4b
[ -f "$SANDBOX/scratch/preflight-feature-228-some-slug.log" ] || { echo "FAIL: gate log not written"; exit 1; }

printf 'promote gate tests passed\n'
