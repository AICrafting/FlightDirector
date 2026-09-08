#!/usr/bin/env bash
#
# Shared helpers for the `auth check` adapters — sourced by <backend>/auth.
#
# `auth check` is the one verb that must NOT die on an HTTP error: a 401/403/404
# *is* the finding it reports. So it does not use each backend's `_api` (which
# exits on >= 400); it uses `probe`, which records the status and keeps going,
# and every backend's auth adapter emits the same line shape:
#
#   ✓ <label>   <detail>      a check that passed
#   ✗ <label>   <detail>      a check that failed  → exit 1 at the end
#   - <label>   <detail>      informational (not tested / not exposed)
#
# Read-only by contract: adapters here probe GET endpoints only.
# shellcheck shell=bash

command -v curl >/dev/null 2>&1 || { echo "auth adapter: curl is required" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "auth adapter: jq is required" >&2; exit 1; }

die() { echo "${ADAPTER_NAME:-auth}: $*" >&2; exit 1; }

# need VAR… — every name must be set and non-empty in the environment.
need() {
	local v
	for v in "$@"; do
		[ -n "${!v:-}" ] || case "$v" in
			LS_TOKEN) die "no token resolved for this axis (set it in the secrets file, pass --secrets <file>, or export LS_TOKEN)" ;;
			*) die "$v not set (the dispatcher must export it — is the axis configured?)" ;;
		esac
	done
}

# mask <token> — first 8 characters only; a token must never be printed whole.
mask() { printf '%.8s…' "$1"; }

_FAILS=0
_PROBE_BODY=""; _PROBE_HDR=""; PROBE_CODE=""

_cleanup() { rm -f "$_PROBE_BODY" "$_PROBE_HDR"; }
trap _cleanup EXIT

# probe METHOD URL — GET-only by contract. Records PROBE_CODE and the response
# body/headers; returns 0 for HTTP < 400, 1 otherwise (never exits).
# The calling adapter supplies its auth in the HDRS array.
probe() {
	local method="$1" url="$2"
	[ "$method" = GET ] || die "probe: auth check is read-only (refusing $method)"
	[ -n "$_PROBE_BODY" ] || { _PROBE_BODY="$(mktemp)"; _PROBE_HDR="$(mktemp)"; }
	PROBE_CODE="$(curl -sS -L -o "$_PROBE_BODY" -D "$_PROBE_HDR" -w '%{http_code}' \
		"${HDRS[@]}" -H "Accept: application/json" "$url" 2>/dev/null)" || { PROBE_CODE=000; }
	[ "$PROBE_CODE" -lt 400 ] 2>/dev/null
}

# body_field <jq filter> — project the last response body; empty if it isn't JSON.
body_field() { jq -r "$1" "$_PROBE_BODY" 2>/dev/null || printf ''; }

# hdr <name> — the last response's header value (case-insensitive), or empty.
hdr() {
	tr -d '\r' <"$_PROBE_HDR" \
		| awk -v n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" \
			'BEGIN{IGNORECASE=1} tolower($0) ~ "^" n ":" { sub(/^[^:]*: */, ""); print; exit }'
}

# why — the last probe's failure as one line, carrying the BACKEND'S OWN wording
# (GitLab names the missing fine-grained permission there, GitHub the resource).
why() {
	local msg
	[ "$PROBE_CODE" != "000" ] || { printf 'request failed (network, TLS, or a bad api base in config.json)'; return; }
	msg="$(jq -r '
		[(.message? // empty), (.error? // empty), (.error_description? // empty),
		 ((.errorMessages? // []) | join("; ")),
		 ((.errors? // {}) | if type == "object" then (to_entries | map("\(.key): \(.value)") | join("; ")) else "" end)]
		| map(select(type == "string" and . != "")) | first // empty' "$_PROBE_BODY" 2>/dev/null || true)"
	printf 'HTTP %s%s' "$PROBE_CODE" "${msg:+: $msg}"
}

_line() { printf '%s %-18s %s\n' "$1" "$2" "$3"; }
pass() { _line '✓' "$1" "$2"; }
fail() { _FAILS=$((_FAILS + 1)); _line '✗' "$1" "$2"; }
note() { _line '-' "$1" "$2"; }
# hint — an indented follow-up under the line above; never a check of its own.
hint() { printf '  ↳ %s\n' "$1"; }

# probe_row LABEL REQUIREMENT METHOD URL — one read probe, reported as one line.
# REQUIREMENT is the backend's own name for the scope/permission it needs, so a
# failure says what to grant (kept in step with references/backends.md).
probe_row() {
	local label="$1" req="$2" method="$3" url="$4"
	if probe "$method" "$url"; then
		pass "$label" "ok${req:+ ($req)}"
	else
		fail "$label" "$(why)${req:+ — needs $req}"
	fi
}

# finish — exit non-zero if any check failed.
finish() {
	if [ "$_FAILS" -gt 0 ]; then
		printf '\n%d check(s) failed.\n' "$_FAILS" >&2
		exit 1
	fi
	exit 0
}
