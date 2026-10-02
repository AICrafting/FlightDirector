#!/usr/bin/env bash
#
# Shared failure reporting for every backend adapter — sourced by each _common.sh.
# shellcheck shell=bash
#
# A failure always prints one human sentence on stderr, exactly as before. When the
# dispatcher runs a `--json` call it also exports FLIGHT_ERROR_FILE, and the failure
# is recorded there as the `{"error":{"code","message"}}` envelope the dispatcher
# prints on stdout (#251). The code is decided HERE, where the cause is known — HTTP
# status, curl failure, a missing token — and never recovered later by matching the
# message text. Codes (stable; see ../../references/json-output.md):
#
#   not-configured  a coordinate the config should supply is missing
#   auth            no token resolved, or the backend answered 401/403
#   not-found       the backend answered 404/410
#   network         the server could not be reached (curl itself failed)
#   backend         the server answered with any other error
#   usage           bad arguments (the default for a plain `die`)

# fail CODE MESSAGE… — report and exit 1.
fail() {
	local code="$1"; shift
	echo "${ADAPTER_NAME:-adapter}: $*" >&2
	if [ -n "${FLIGHT_ERROR_FILE:-}" ]; then
		jq -cn --arg c "$code" --arg m "${ADAPTER_NAME:-adapter}: $*" '{error:{code:$c, message:$m}}' \
			>"$FLIGHT_ERROR_FILE" 2>/dev/null || true
	fi
	exit 1
}

# die MESSAGE… — a caller error unless the adapter says otherwise.
die() { fail usage "$@"; }

# http_fail HTTP_CODE MESSAGE… — the code for an HTTP error status.
http_fail() {
	local status="$1"; shift
	case "$status" in
		401|403) fail auth "$@" ;;
		404|410) fail not-found "$@" ;;
		*)       fail backend "$@" ;;
	esac
}

# require_env VAR CODE MESSAGE — fail with CODE unless $VAR is set and non-empty.
require_env() {
	[ -n "${!1:-}" ] || fail "$2" "$3"
}
