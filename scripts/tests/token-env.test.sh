#!/usr/bin/env bash
# Unit tests for the dispatcher's token resolution: the backend-neutral
# FLIGHT_TOKEN env override, the legacy FORGEJO_TOKEN name, LS_TOKEN taking
# precedence over both, and the secrets file as the fallback. The network is
# stubbed with a fake `curl` on PATH that records the Authorization header.
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
	sed -n 's/^Authorization: token //p' "$HDRS" | head -1
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
