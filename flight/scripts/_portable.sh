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
		jq() { command jq "$@" | tr -d '\r'; }
		;;
esac

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
