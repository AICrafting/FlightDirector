#!/usr/bin/env bash
# Unit tests for the `branches` group (`flight branches list|prune`) and the
# `pr list` adapter verb it falls back on.
#
# Two sandboxes, no network:
#   * a real throwaway git repo (bare origin + working clone + a linked worktree)
#     exercises ancestry detection, pattern filtering, the protected-ref rules and
#     every prune mode — deletion is real, but only ever inside $SANDBOX;
#   * a fake `curl` on PATH (the ci-watch.test.sh trick) exercises `pr list`
#     against forgejo/github/gitlab without a live backend.
#
# The merged-PR fallback is driven through a stub `FLIGHT_SELF`, which is exactly
# the seam the dispatcher fills — a squash-merged branch is not an ancestor of the
# stage, so only the backend can say it landed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRANCHES="$REPO_ROOT/flight/scripts/branches"
DISPATCH="$REPO_ROOT/flight/scripts/flight"

pass=0; fail=0
check() { if [ "$2" = 1 ]; then printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass+1));
			else printf '\033[0;31m  ✗ %s\033[0m  %s\n' "$1" "${3:-}"; fail=$((fail+1)); fi; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT

# ── a stub dispatcher: answers only `pr list`, from $PR_ROWS ──────────────────
STUB="$SANDBOX/flight-stub"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
# Stand-in for the dispatcher's `pr list` — prints $PR_ROWS when the requested
# --head matches $PR_HEAD, nothing otherwise. Any other group exits non-zero,
# which is what a Jira-style backend with no `pr` adapter does.
[ "$1" = pr ] && [ "$2" = list ] || exit 2
head=""
while [ $# -gt 0 ]; do case "$1" in --head) head="$2"; shift 2 ;; *) shift ;; esac; done
[ "$head" = "${PR_HEAD:-}" ] || exit 0
printf '%s\n' "${PR_ROWS:-}"
EOF
chmod +x "$STUB"

# ── the sandbox repo ─────────────────────────────────────────────────────────
ORIGIN="$SANDBOX/origin.git"; R="$SANDBOX/repo"
git init -q --bare -b develop "$ORIGIN"
git init -q -b develop "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
git -C "$R" remote add origin "$ORIGIN"

seed() { printf '%s\n' "$2" >"$R/$1"; git -C "$R" add "$1"; git -C "$R" commit -qm "$2"; }

seed base "initial"
git -C "$R" push -q -u origin develop
git -C "$R" branch qa develop
git -C "$R" branch main develop
git -C "$R" push -q origin qa main

# branch <name> <file> — fork it from develop and push it.
branch() { git -C "$R" switch -q -c "$1" develop; seed "$2" "$1"; git -C "$R" push -q -u origin "$1"; }

branch feature/1-merged f1          # → merged into develop below
branch feature/2-open   f2          # never merged: must never be a candidate
branch bugfix/3-merged  b3          # → merged into qa below
branch release/0.1.0    r4          # → merged into develop below
branch hotfix/5-merged  h5          # merged, but outside the default patterns
branch feature/6-squashed f6        # "squash merged": PR-only evidence
branch feature/7-worktree f7        # merged, and checked out in a worktree

# archived/* is protected even when a --pattern would otherwise select it.
git -C "$R" switch -q -c archived/feature/8-old develop
seed a8 "archived/feature/8-old"
git -C "$R" push -q -u origin archived/feature/8-old

git -C "$R" switch -q develop
for b in feature/1-merged release/0.1.0 hotfix/5-merged feature/7-worktree; do
	git -C "$R" merge -q --no-ff -m "merge $b" "$b"
done
git -C "$R" push -q origin develop

git -C "$R" switch -q qa
git -C "$R" merge -q --no-ff -m "merge bugfix/3-merged" bugfix/3-merged
git -C "$R" push -q origin qa
git -C "$R" switch -q develop

# feature/6-squashed lands as a fresh commit, so its tip is NOT an ancestor of any
# stage — the exact case the merged-PR fallback exists for.
git -C "$R" merge -q --squash feature/6-squashed
git -C "$R" commit -qm "squash: feature/6-squashed"
git -C "$R" push -q origin develop

# A linked worktree under .worktrees/, plus one outside it (a user's own checkout).
git -C "$R" worktree add -q "$R/.worktrees/7-worktree" feature/7-worktree
git -C "$R" fetch -q origin

mkdir -p "$R/.flightdirector"
cat >"$R/.flightdirector/config.json" <<'EOF'
{
  "code": {
    "backend": "forgejo", "owner": "o", "repo": "r", "api": "http://fake",
    "stages": [ { "name": "develop" }, { "name": "qa" }, { "name": "main" } ]
  }
}
EOF

# run <verb> [args…] — the branches script with the dispatcher's environment.
# --no-fetch throughout: the sandbox origin is already in sync and a real fetch
# would only add latency (the fetch path itself is covered by the offline warning).
run() {
	local verb="$1"; shift
	FLIGHT_REPO_ROOT="$R" FLIGHT_CONFIG="$R/.flightdirector/config.json" FLIGHT_SELF="$STUB" \
		bash "$BRANCHES" "$verb" "$@" --no-fetch 2>&1
}
col1() { cut -f1; }

printf '\033[1m── branches list ──\033[0m\n'

out="$(run list)"
check "lists a branch merged by ancestry into stages[0]" \
	"$(grep -q '^feature/1-merged	' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "an unmerged branch is never a candidate" \
	"$(grep -q '^feature/2-open' <<<"$out" && echo 0 || echo 1)" "out=$out"
check "finds a branch merged into a LATER stage (qa), not just stages[0]" \
	"$(grep -q '^bugfix/3-merged	local+remote	qa	' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "release/* is a default pattern too" \
	"$(grep -q '^release/0.1.0	' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "a merged branch outside the patterns is left alone" \
	"$(grep -q '^hotfix/5-merged' <<<"$out" && echo 0 || echo 1)" "out=$out"
check "no stage branch is ever listed" \
	"$(grep -qE '^(develop|qa|main)	' <<<"$out" && echo 0 || echo 1)" "out=$out"
check "row is branch⇥where⇥stage⇥pr⇥issue⇥worktree" \
	"$(grep -q '^feature/1-merged	local+remote	develop	-	1	-$' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "a branch with a worktree reports its path" \
	"$(grep -q "^feature/7-worktree	local+remote	develop	-	7	$R/.worktrees/7-worktree\$" <<<"$out" && echo 1 || echo 0)" "out=$out"

check "--merged-into narrows to that one stage" \
	"$(out2="$(run list --merged-into develop)"; grep -q '^bugfix/3-merged' <<<"$out2" && echo 0 || echo 1)" \
	"$(run list --merged-into develop)"
out="$(run list --merged-into qa)"
check "--merged-into still finds that stage's own branches" \
	"$(grep -q '^bugfix/3-merged' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "--merged-into rejects a name that is not a stage" \
	"$(run list --merged-into nope >/dev/null 2>&1 && echo 0 || echo 1)"

check "--pattern overrides the defaults" \
	"$(out2="$(run list --pattern 'hotfix/*')"; [ "$(col1 <<<"$out2")" = "hotfix/5-merged" ] && echo 1 || echo 0)" \
	"$(run list --pattern 'hotfix/*')"
out="$(run list --pattern 'archived/*')"
check "archived/* stays protected even when a --pattern selects it" \
	"$(grep -q archived <<<"$out" && echo 0 || echo 1)" "out=$out"
out="$(run list --pattern '*')"
check "a wildcard --pattern still excludes the stage branches" \
	"$(grep -qE '^(develop|qa|main)	' <<<"$out" && echo 0 || echo 1)" "out=$out"

# config-driven patterns
python3 - "$R/.flightdirector/config.json" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p))
c["code"]["branches"]={"patterns":["hotfix/*"]}
json.dump(c,open(p,"w"),indent=2)
PY
check "code.branches.patterns replaces the built-in defaults" \
	"$(out2="$(run list)"; [ "$(col1 <<<"$out2")" = "hotfix/5-merged" ] && echo 1 || echo 0)" "$(run list)"
out="$(run list --pattern 'release/*')"
check "--pattern still wins over code.branches.patterns" \
	"$([ "$(col1 <<<"$out")" = 'release/0.1.0' ] && echo 1 || echo 0)" "out=$out"
python3 - "$R/.flightdirector/config.json" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p))
del c["code"]["branches"]
json.dump(c,open(p,"w"),indent=2)
PY

printf '\033[1m── merged-PR fallback (squash/rebase hops) ──\033[0m\n'

out="$(run list)"
check "a squash-merged branch is invisible to ancestry alone" \
	"$(grep -q '^feature/6-squashed' <<<"$out" && echo 0 || echo 1)" "out=$out"

export PR_HEAD="feature/6-squashed"
PR_ROWS="$(printf '31\tmerged\tfeature/6-squashed\tdevelop\tSquash me')"; export PR_ROWS
out="$(run list)"
check "a merged PR whose head is the branch counts as merged" \
	"$(grep -q '^feature/6-squashed	local+remote	develop	31	6	-$' <<<"$out" && echo 1 || echo 0)" "out=$out"

PR_ROWS="$(printf '31\tmerged\tfeature/6-squashed\tsome-other-branch\tSquash me')"
out="$(run list)"
check "a merged PR into a non-stage base does NOT count" \
	"$(grep -q '^feature/6-squashed' <<<"$out" && echo 0 || echo 1)" "out=$out"

PR_ROWS="$(printf '31\tmerged\tfeature/6-squashed\tqa\tSquash me')"
out="$(run list --merged-into develop)"
check "--merged-into scopes the PR fallback too" \
	"$(grep -q '^feature/6-squashed' <<<"$out" && echo 0 || echo 1)" "out=$out"

# A backend with no `pr` adapter (Jira) exits non-zero — that must degrade to
# "unmerged", never abort the listing.
PR_HEAD=""; PR_ROWS=""
out="$(FLIGHT_REPO_ROOT="$R" FLIGHT_CONFIG="$R/.flightdirector/config.json" FLIGHT_SELF=/bin/false \
		bash "$BRANCHES" list --no-fetch 2>/dev/null)"
check "a backend that cannot answer pr list is not fatal" \
	"$(grep -q '^feature/1-merged' <<<"$out" && echo 1 || echo 0)" "out=$out"

export PR_HEAD="" PR_ROWS=""

printf '\033[1m── branches prune ──\033[0m\n'

out="$(run prune)"
check "bare prune deletes nothing and says so" \
	"$(grep -q 'showing what WOULD be deleted' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "bare prune previews every class (local, remote, worktree)" \
	"$(grep -q '^would-delete-local	feature/1-merged' <<<"$out" &&
	   grep -q '^would-delete-remote	feature/1-merged' <<<"$out" &&
	   grep -q '^would-remove-worktree	feature/7-worktree' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "bare prune really is a no-op (branch still there)" \
	"$(git -C "$R" rev-parse -q --verify refs/heads/feature/1-merged >/dev/null && echo 1 || echo 0)"

out="$(run prune --local --dry-run)"
check "--dry-run with --local previews without deleting" \
	"$(grep -q '^would-delete-local	feature/1-merged' <<<"$out" &&
	   ! grep -q '^delete-local' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "--dry-run --local leaves the remote out of the preview" \
	"$(grep -q 'delete-remote' <<<"$out" && echo 0 || echo 1)" "out=$out"

check "--branch restricts prune to the named branch" \
	"$(out2="$(run prune --branch feature/1-merged)"; grep -q 'release/0.1.0' <<<"$out2" && echo 0 || echo 1)" \
	"$(run prune --branch feature/1-merged)"

out="$(run prune --local --branch feature/1-merged)"
check "--local deletes the local branch" \
	"$(grep -q '^delete-local	feature/1-merged	merged into develop$' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "…and the ref is really gone" \
	"$(git -C "$R" rev-parse -q --verify refs/heads/feature/1-merged >/dev/null && echo 0 || echo 1)"
check "--local alone leaves the remote branch standing" \
	"$(git -C "$R" rev-parse -q --verify refs/remotes/origin/feature/1-merged >/dev/null && echo 1 || echo 0)"

out="$(run prune --remote --branch feature/1-merged)"
check "--remote deletes the branch on origin" \
	"$(grep -q '^delete-remote	feature/1-merged' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "…and origin no longer has it" \
	"$(git -C "$ORIGIN" rev-parse -q --verify refs/heads/feature/1-merged >/dev/null && echo 0 || echo 1)"

printf '\033[1m── worktrees ──\033[0m\n'

out="$(run prune --local --branch feature/7-worktree)"
check "--local alone will not touch a branch that is checked out" \
	"$(grep -q '^skip	feature/7-worktree	worktree .* (pass --worktrees to remove it)$' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "…and the worktree survives" "$([ -d "$R/.worktrees/7-worktree" ] && echo 1 || echo 0)"

# A dirty worktree is someone's unreviewed work: `git worktree remove` (no --force)
# must refuse, and the branch must survive with it.
printf 'scratch\n' >"$R/.worktrees/7-worktree/uncommitted"
out="$(run prune --worktrees --local --branch feature/7-worktree)"
check "a dirty worktree is refused, not forced" \
	"$(grep -q '^skip	feature/7-worktree	worktree .* is dirty or locked' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "a refused worktree exits non-zero" \
	"$(run prune --worktrees --local --branch feature/7-worktree >/dev/null 2>&1 && echo 0 || echo 1)"
check "…and the branch is still there" \
	"$(git -C "$R" rev-parse -q --verify refs/heads/feature/7-worktree >/dev/null && echo 1 || echo 0)"

rm -f "$R/.worktrees/7-worktree/uncommitted"
out="$(run prune --worktrees --local --branch feature/7-worktree)"
check "--worktrees removes a clean worktree, then the branch" \
	"$(grep -q '^remove-worktree	feature/7-worktree' <<<"$out" &&
	   grep -q '^delete-local	feature/7-worktree' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "…the worktree directory is gone" "$([ -d "$R/.worktrees/7-worktree" ] && echo 0 || echo 1)"

# A worktree outside .worktrees/ is a user's own checkout, not flight leftovers —
# and the MAIN checkout's own branch is never a target, whatever flags are passed.
git -C "$R" branch feature/9-current develop            # merged by construction
git -C "$R" worktree add -q "$SANDBOX/mine" feature/9-current

out="$(run prune --local --worktrees --branch develop)"
check "the branch checked out in the main checkout is never pruned" \
	"$(git -C "$R" rev-parse -q --verify refs/heads/develop >/dev/null && echo 1 || echo 0)" "out=$out"

out="$(run prune --local --worktrees --branch feature/9-current)"
check "a worktree outside .worktrees/ is skipped as not-ours" \
	"$(grep -q '^skip	feature/9-current	checked out at .* (not a .worktrees/ entry)$' <<<"$out" && echo 1 || echo 0)" "out=$out"
check "…and that branch survives" \
	"$(git -C "$R" rev-parse -q --verify refs/heads/feature/9-current >/dev/null && echo 1 || echo 0)"
git -C "$R" worktree remove -q "$SANDBOX/mine" 2>/dev/null || git -C "$R" worktree remove --force "$SANDBOX/mine"

printf '\033[1m── dispatcher wiring ──\033[0m\n'

out="$(cd "$R" && bash "$DISPATCH" branches list --no-fetch 2>&1)"
check "flight branches list reaches the branches script" \
	"$(grep -q '^release/0.1.0	' <<<"$out" && echo 1 || echo 0)" "out=$out"
out="$(cd "$R" && bash "$DISPATCH" branches nope 2>&1)"
check "an unknown branches verb is rejected by the dispatcher" \
	"$(grep -q "unknown verb 'nope'" <<<"$out" && echo 1 || echo 0)" "out=$out"
out="$(cd "$R" && bash "$DISPATCH" branches list --local 2>&1)"
check "prune-only flags are rejected on list" \
	"$(grep -q 'prune-only flag' <<<"$out" && echo 1 || echo 0)" "out=$out"

# ── pr list, against a fake curl ──────────────────────────────────────────────
printf '\033[1m── pr list (adapters) ──\033[0m\n'

FAKE_DIR="$SANDBOX/bin"; mkdir -p "$FAKE_DIR"
cat >"$FAKE_DIR/curl" <<'EOF'
#!/usr/bin/env bash
# Serves $FAKE_RESP/pulls.json for any URL; records the URL it was asked for so a
# test can assert the server-side filters the adapter chose to send.
outfile=""; want_code=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$FAKE_RESP/urls.log"
body="$(cat "$FAKE_RESP/pulls.json")"
if [ -n "$outfile" ]; then printf '%s' "$body" >"$outfile"; else printf '%s' "$body"; fi
[ "$want_code" = 1 ] && printf '200'
exit 0
EOF
chmod +x "$FAKE_DIR/curl"

RESP="$SANDBOX/resp"; mkdir -p "$RESP"
export FAKE_RESP="$RESP"
export LS_API="http://fake" LS_OWNER="o" LS_REPO="r" LS_TOKEN="t"

pr_list() {
	local backend="$1"; shift
	: >"$RESP/urls.log"
	PATH="$FAKE_DIR:$PATH" bash "$REPO_ROOT/flight/scripts/adapters/$backend/pr" list "$@" 2>&1
}

# GitHub and Forgejo share the pulls shape; GitLab has its own field names.
cat >"$RESP/pulls.json" <<'EOF'
[ {"number":31,"iid":31,"state":"closed","merged_at":"2026-01-01T00:00:00Z","title":"Squashed",
   "head":{"ref":"feature/6-squashed"},"base":{"ref":"develop"},
   "source_branch":"feature/6-squashed","target_branch":"develop"},
  {"number":32,"iid":32,"state":"closed","merged_at":null,"title":"Abandoned",
   "head":{"ref":"feature/6-squashed"},"base":{"ref":"develop"},
   "source_branch":"feature/6-squashed","target_branch":"develop"},
  {"number":33,"iid":33,"state":"closed","merged_at":"2026-01-02T00:00:00Z","title":"Elsewhere",
   "head":{"ref":"feature/99-other"},"base":{"ref":"develop"},
   "source_branch":"feature/99-other","target_branch":"develop"} ]
EOF

for backend in forgejo github; do
	out="$(pr_list "$backend" --state merged --head feature/6-squashed)"
	check "$backend: pr list --state merged --head → the merged PR only" \
		"$([ "$out" = "$(printf '31\tmerged\tfeature/6-squashed\tdevelop\tSquashed')" ] && echo 1 || echo 0)" "out=$out"

	out="$(pr_list "$backend" --state merged)"
	check "$backend: without --head, every merged PR comes back" \
		"$([ "$(wc -l <<<"$out")" = 2 ] && echo 1 || echo 0)" "out=$out"

	out="$(pr_list "$backend" --state closed --head feature/6-squashed)"
	check "$backend: --state closed keeps the never-merged PR" \
		"$([ "$(wc -l <<<"$out")" = 2 ] && grep -q '^32	closed	' <<<"$out" && echo 1 || echo 0)" "out=$out"

	out="$(pr_list "$backend" --state merged --base nowhere)"
	check "$backend: --base filters by target branch" \
		"$([ -z "$out" ] && echo 1 || echo 0)" "out=$out"

	out="$(pr_list "$backend" --state bogus 2>&1)"
	check "$backend: an unknown --state is rejected" \
		"$(grep -q 'open|closed|merged|all' <<<"$out" && echo 1 || echo 0)" "out=$out"
done

# GitHub is the one backend that can filter server-side; it must actually do so.
pr_list github --state merged --head feature/6-squashed --base develop >/dev/null
check "github: sends head=owner:branch and base= server-side" \
	"$(grep -q 'head=o:feature/6-squashed' "$RESP/urls.log" && grep -q 'base=develop' "$RESP/urls.log" && echo 1 || echo 0)" \
	"$(cat "$RESP/urls.log")"
pr_list forgejo --state merged --head feature/6-squashed >/dev/null
check "forgejo: asks for closed PRs (it has no merged state)" \
	"$(grep -q 'state=closed' "$RESP/urls.log" && echo 1 || echo 0)" "$(cat "$RESP/urls.log")"

# GitLab: `merged` is a real state, so no client-side merged_at filtering.
cat >"$RESP/pulls.json" <<'EOF'
[ {"iid":31,"state":"merged","title":"Squashed",
   "source_branch":"feature/6-squashed","target_branch":"develop"},
  {"iid":33,"state":"merged","title":"Elsewhere",
   "source_branch":"feature/99-other","target_branch":"develop"} ]
EOF
out="$(pr_list gitlab --state merged --head feature/6-squashed)"
check "gitlab: pr list projects iid/source/target into the same TSV" \
	"$([ "$out" = "$(printf '31\tmerged\tfeature/6-squashed\tdevelop\tSquashed')" ] && echo 1 || echo 0)" "out=$out"
check "gitlab: uses the native merged state and source_branch filter" \
	"$(grep -q 'state=merged' "$RESP/urls.log" && grep -q 'source_branch=feature/6-squashed' "$RESP/urls.log" && echo 1 || echo 0)" \
	"$(cat "$RESP/urls.log")"
out="$(pr_list gitlab --state open >/dev/null; grep -o 'state=[a-z]*' "$RESP/urls.log")"
check "gitlab: --state open maps to GitLab's 'opened'" \
	"$([ "$out" = "state=opened" ] && echo 1 || echo 0)" "out=$out"

printf '\033[1m────────────────────────────\033[0m\n'
printf 'Passed: %d  Failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
