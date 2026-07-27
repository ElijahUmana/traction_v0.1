#!/usr/bin/env bash
# Run the TRACTION test suite.
#
# PYTEST_XDIST_AUTO_NUM_WORKERS=1 is NOT optional.
#
# `jac test` runs pytest-xdist with ten workers by default and injects `-n`
# unconditionally, so `PYTEST_ADDOPTS="-p no:xdist"` is rejected and there is no
# CLI flag to turn it off. Ten workers mutating the single root anchor produce
# intermittent:
#     WriteConflict: anchor 00000000-0000-0000-0000-000000000000
#                    changed concurrently (expected v0, found v1)
# It is non-deterministic and it looks exactly like a race in the code under
# test. It is not one. Measured on this repo: 5 failures with default workers,
# 0 with one worker.
#
# The suite needs NO API keys - it must stay that way, so ANTHROPIC_API_KEY is
# explicitly unset rather than merely absent. A suite that silently starts
# needing a key is a suite that breaks on a judge's laptop.
set -uo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# DESTRUCTIVE. This script calls `jac clean --all --force`, which DELETES
# .jac/data - the graph.
#
# This is not hypothetical: it wiped the demo graph at 17:18 today. 702 anchors
# gone (29 Prospects, 18 Founders, 73 Lanes, 44 Evidence), recovered only
# because a snapshot happened to be taken one minute earlier. Anyone following
# our own documented test procedure destroyed the demo state.
#
# So it refuses to run against the primary checkout unless you say so out loud.
# Tests belong in a throwaway clone anyway - see docs/RUNBOOK.md.
# ---------------------------------------------------------------------------
PRIMARY="/Users/elijahumana/jachacks-traction"
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "$HERE" = "$PRIMARY" ] && [ "${YES_WIPE:-0}" != "1" ]; then
  echo "REFUSING: this wipes .jac/data (the graph) and you are in the primary checkout:"
  echo "  $HERE"
  echo
  echo "Run it in a throwaway clone instead:"
  echo "  git clone $PRIMARY /tmp/tr-test && cd /tmp/tr-test && ops/$(basename "$0")"
  echo
  echo "Or, if you really mean to wipe the graph here:  YES_WIPE=1 ops/$(basename "$0")"
  exit 2
fi

echo "==> clearing stale cache + persisted graph"
jac clean --all --force >/dev/null 2>&1 || true

echo "==> running suite (1 xdist worker, no API key)"
PYTEST_XDIST_AUTO_NUM_WORKERS=1 env -u ANTHROPIC_API_KEY jac test "$@"
status=$?

echo
if [ $status -eq 0 ]; then
  echo "PASS - and it passed with no ANTHROPIC_API_KEY set."
else
  echo "FAIL (exit $status)"
  echo "If you see WriteConflict on anchor 00000000-..., the env var above was lost."
fi
exit $status
