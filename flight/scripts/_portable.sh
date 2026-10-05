#!/usr/bin/env bash
#
# Cross-platform shims — sourced by every entrypoint and every adapter, and a
# no-op everywhere except Windows (MSYS / Git Bash / Cygwin).
#
# Sourced, never executed: it defines things and sets nothing, so the caller
# keeps ownership of `set -euo pipefail`.
# shellcheck shell=bash

# `$OSTYPE` is set by bash itself, so the platform test costs no subprocess —
# this file is sourced once per adapter invocation and those add up.
case "${OSTYPE:-}" in
	msys* | cygwin* | win32)

		# A native jq.exe (what winget, scoop and choco all install) opens stdout
		# in TEXT mode, so every "\n" it writes becomes "\r\n". `read -r` keeps the
		# CR, and `$(…)` strips trailing newlines but not carriage returns, so every
		# comparison against jq output silently fails against an invisible byte:
		#
		#     --from 'qa' is not a configured stage (have: develop qa main)
		#
		# `qa` is in that list. It is "qa\r". Wrapping the command rather than the
		# ~266 call sites keeps the fix in one place and leaves them all untouched.
		# Every caller runs with `set -o pipefail`, so jq's own exit status still
		# governs the pipeline — dropping that is how this breaks `auth check`,
		# which depends on a non-zero jq.
		#
		# jq's own `-b` (`--binary`, jq 1.6+) writes LF on Windows, which removes the
		# pipe: one process per call instead of three (a subshell, jq, tr). This leg is
		# where every spawn is dearest, and there are ~50 jq calls in one set-status
		# (FJ-301). Probed once per process tree: the result is exported, so every child
		# script inherits it instead of re-probing. A jq without -b keeps the pipe.
		# The probe runs in a subshell: bash 3.2 under `set -e` exits on a failing
		# `command …` even inside an `if` condition, killing the caller silently.
		if [ -z "${FLIGHT_JQ_BINARY:-}" ]; then
			if (command jq -b -n 1) >/dev/null 2>&1; then FLIGHT_JQ_BINARY=1; else FLIGHT_JQ_BINARY=0; fi
			export FLIGHT_JQ_BINARY
		fi
		if [ "$FLIGHT_JQ_BINARY" = 1 ]; then
			jq() { command jq -b "$@"; }
		else
			jq() { command jq "$@" | tr -d '\r'; }
		fi
		;;
esac

# urlenc <string> — percent-encode one caller-supplied value for a URL query
# parameter or path segment. THE encoder: every adapter sources this file, so
# there is one implementation rather than one per backend.
#
# Defined after the shim above on purpose — the `jq` here resolves at call time,
# so on Windows it is the CRLF-stripping wrapper and not the raw jq.exe.
#
# `@uri` leaves only the RFC 3986 unreserved set alone (A-Z a-z 0-9 - _ . ~) and
# encodes everything else, non-ASCII included, as UTF-8 bytes. Label names carry
# spaces and '/' (`status/to test`) and curl rejects a raw space outright
# ("Malformed input to a URL function") rather than sending a broken filter.
# Encode the VALUE, never the whole URL: the '?', '&' and '=' that separate the
# parameters, and any fixed path prefix, are assembled around what this returns.
urlenc() { printf '%s' "$1" | jq -sRr @uri; }

# flight_path_norm <path> — the form git prints, on every platform.
#
# Git for Windows reports Windows-native paths ("C:/src/repo") while MSYS bash
# produces POSIX ones ("/c/src/repo"). Anything that string-compares a shell path
# against `git worktree list` output has to put both through this first, or the
# two spellings of one path never match. Identity off Windows.
flight_path_norm() {
	case "${OSTYPE:-}" in
		msys* | cygwin* | win32) cygpath -m -- "$1" 2>/dev/null || printf '%s\n' "$1" ;;
		*) printf '%s\n' "$1" ;;
	esac
}

# flight_path_key <path> — a form safe to STRING-COMPARE two paths with.
#
# Windows filesystems are case-insensitive but shell string compares are not, and
# the two sources disagree in practice: git may print C:/Windows/Temp/... while
# cygpath resolves the same directory to C:/WINDOWS/Temp/... . Compare keys, not
# the paths themselves, and keep the original for anything shown to the user.
# Identity off Windows, where case is significant and must stay so.
flight_path_key() {
	case "${OSTYPE:-}" in
		msys* | cygwin* | win32) flight_path_norm "$1" | tr '[:upper:]' '[:lower:]' ;;
		*) printf '%s\n' "$1" ;;
	esac
}
