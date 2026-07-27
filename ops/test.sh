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
# THIS SCRIPT NEVER RUNS jac IN THE PRIMARY CHECKOUT. It copies itself out.
#
# Two separate reasons, both of which bit us today:
#
#  1. `jac test` HOLDS .jac/data OPEN for the whole run. Three of my test runs
#     (47, 27 and 7 minutes) kept the store locked and BLOCKED THE API SERVER
#     FROM STARTING - server down, tunnel 502, every mid-call Vapi tool failing.
#     That is the demo's critical path. Running tests is not worth that risk.
#  2. It calls `jac clean --all --force`, which DELETES .jac/data. That wiped
#     the demo graph at 17:18 - 702 anchors, saved only by a snapshot taken a
#     minute earlier.
#
# THE REPO ROOT BELONGS TO THE SERVER. Nothing else runs jac in it.
#
# So: this script rsyncs the checkout to a scratch dir and runs there. Set
# TEST_DIR to choose the location. IN_PLACE=1 forces the old behaviour and you
# should not use it while anyone needs the server.
# ---------------------------------------------------------------------------
PRIMARY="/Users/elijahumana/jachacks-traction"
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="${TEST_DIR:-/tmp/traction-verify}"

if [ "$HERE" = "$PRIMARY" ] && [ "${IN_PLACE:-0}" != "1" ]; then
  echo "==> not running jac in the primary checkout (the server owns it)"
  echo "    copying to $TEST_DIR"
  mkdir -p "$TEST_DIR"
  # -a preserves modes; exclude the graph store and caches so we never touch
  # the server's data and never inherit a stale one.
  rsync -a --delete \
    --exclude '.jac/' --exclude '.git/' --exclude '__pycache__/' \
    --exclude 'node_modules/' \
    "$HERE"/ "$TEST_DIR"/ 2>/dev/null || {
      echo "!! rsync failed - is $TEST_DIR writable?"; exit 1; }
  echo "    running suite there"
  echo
  cd "$TEST_DIR"
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
