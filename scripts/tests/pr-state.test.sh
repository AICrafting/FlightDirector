#!/usr/bin/env bash
# Unit tests for the `state` column of `pr get` and `pr list`: both verbs report
# one vocabulary — `open` | `closed` | `merged` — on every backend with a `pr`
# adapter, so a caller can compare the field without knowing which forge
# answered. The wire values disagree (GitLab spells an open MR `opened` and has
# a first-class `merged`; Forgejo and GitHub call a merged PR `closed` and set
# `merged_at`), and that normalization is the whole point of the field.
# See flight/references/adapter-contract.md, `pr` → `get` / `list`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADAPTERS="$REPO_ROOT/flight/scripts/adapters"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# A fake forge. A single-PR GET answers with $PR_JSON; a list GET answers with
# $PR_JSON on the first page and an empty array afterwards, because _paged_get
# pages until a page comes back empty.
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-D) : >"$2"; shift 2 ;;
		--data-binary) shift 2 ;;
		-w|-X|-H|-u) shift 2 ;;
		-sS|-L) shift ;;
		*) url="$1"; shift ;;
	esac
done
# Bash pattern matching, not grep: BRE `\|` alternation is a GNU extension and
# this repo also runs on the BSD and MSYS legs.
case "$url" in
	*page=1\&*|*page=1) printf '%s' "${PR_JSON:?}" >"$out" ;;
	*page=*)            printf '[]' >"$out" ;;
	*)                  printf '%s' "${PR_JSON:?}" >"$out" ;;
esac
printf '200'
SH
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export LS_API=https://forge.invalid/api/v1 LS_OWNER=o LS_REPO=r LS_TOKEN=t

pass=0; fail=0
check() { # check <label> <got> <want>
	if [ "$2" = "$3" ]; then
		printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; pass=$((pass + 1))
	else
		printf '\033[0;31m  ✗ %s\n      got:  %s\n      want: %s\033[0m\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

# get_state <adapter> <json> — field 3 of `pr get`.
get_state() {
	PR_JSON="$2" "$ADAPTERS/$1/pr" get --number 1 2>/dev/null | cut -f3
}
# list_state <adapter> <json-array> [--state S] — field 2 of the first `pr list` row.
list_state() {
	adapter="$1"; json="$2"; shift 2
	PR_JSON="$json" "$ADAPTERS/$adapter/pr" list "$@" 2>/dev/null | head -1 | cut -f2
}

# --- fixtures, in each backend's own wire spelling ----------------------------
# Forgejo and GitHub have no `merged` state: a merged PR is a closed one with
# `merged_at` set, which is why the field cannot just be passed through.
FJ_OPEN='{"number":1,"title":"t","state":"open","merged_at":null,"html_url":"u","head":{"ref":"f"},"base":{"ref":"d"}}'
FJ_SHUT='{"number":1,"title":"t","state":"closed","merged_at":null,"html_url":"u","head":{"ref":"f"},"base":{"ref":"d"}}'
FJ_MERGED='{"number":1,"title":"t","state":"closed","merged_at":"2026-09-20T00:00:00Z","html_url":"u","head":{"ref":"f"},"base":{"ref":"d"}}'
# GitLab: an open MR is `opened`, and `merged` / `locked` are states of their own.
GL_OPEN='{"iid":1,"title":"t","state":"opened","web_url":"u","source_branch":"f","target_branch":"d"}'
GL_SHUT='{"iid":1,"title":"t","state":"closed","web_url":"u","source_branch":"f","target_branch":"d"}'
GL_MERGED='{"iid":1,"title":"t","state":"merged","web_url":"u","source_branch":"f","target_branch":"d"}'
GL_LOCKED='{"iid":1,"title":"t","state":"locked","web_url":"u","source_branch":"f","target_branch":"d"}'

printf '\033[1m── pr get emits a normalized state ──\033[0m\n'

check "forgejo: an open PR reports open"      "$(get_state forgejo "$FJ_OPEN")" open
check "forgejo: a closed PR reports closed"   "$(get_state forgejo "$FJ_SHUT")" closed
check "forgejo: merged_at makes it merged"    "$(get_state forgejo "$FJ_MERGED")" merged
check "github: an open PR reports open"       "$(get_state github "$FJ_OPEN")" open
check "github: a closed PR reports closed"    "$(get_state github "$FJ_SHUT")" closed
check "github: merged_at makes it merged"     "$(get_state github "$FJ_MERGED")" merged

# The case the issue is named for: a caller comparing the raw wire value against
# `open` reads every open GitLab MR as not-open.
check "gitlab: 'opened' is normalized to open" "$(get_state gitlab "$GL_OPEN")" open
check "gitlab: 'closed' stays closed"          "$(get_state gitlab "$GL_SHUT")" closed
check "gitlab: 'merged' stays merged"          "$(get_state gitlab "$GL_MERGED")" merged
# `locked` is transient and GitLab-only. It passes through rather than being
# folded into another value, which is what the contract row promises.
check "gitlab: 'locked' passes through"        "$(get_state gitlab "$GL_LOCKED")" locked

printf '\033[1m── the pr get line shape stays pinned ──\033[0m\n'

check "forgejo: number⇥title⇥state⇥url" \
	"$(PR_JSON="$FJ_OPEN" "$ADAPTERS/forgejo/pr" get --number 1 2>/dev/null)" \
	"$(printf '1\tt\topen\tu')"
check "gitlab: iid⇥title⇥state⇥url" \
	"$(PR_JSON="$GL_OPEN" "$ADAPTERS/gitlab/pr" get --number 1 2>/dev/null)" \
	"$(printf '1\tt\topen\tu')"

printf '\033[1m── pr list speaks the same vocabulary ──\033[0m\n'

check "forgejo: an open PR lists as open"    "$(list_state forgejo "[$FJ_OPEN]")" open
check "forgejo: a merged PR lists as merged" "$(list_state forgejo "[$FJ_MERGED]" --state merged)" merged
check "github: an open PR lists as open"     "$(list_state github "[$FJ_OPEN]")" open
check "github: a merged PR lists as merged"  "$(list_state github "[$FJ_MERGED]" --state merged)" merged
check "gitlab: 'opened' lists as open"       "$(list_state gitlab "[$GL_OPEN]")" open
check "gitlab: a merged MR lists as merged"  "$(list_state gitlab "[$GL_MERGED]" --state merged)" merged
check "gitlab: 'locked' lists unchanged"     "$(list_state gitlab "[$GL_LOCKED]" --state all)" locked

printf '\n'
if [ "$fail" -gt 0 ]; then
	printf '\033[0;31mpr-state: %d passed, %d failed\033[0m\n' "$pass" "$fail"
	exit 1
fi
printf '\033[0;32mpr-state: all %d checks passed\033[0m\n' "$pass"
