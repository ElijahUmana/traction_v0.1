#!/usr/bin/env bash
# Re-sync becky_ui/ to the current head of Becky's frontend branch.
#
#   ops/sync_ui.sh            # sync to origin/codex/agentic-workflow-ui
#   ops/sync_ui.sh <ref>      # sync to a specific ref
#
# Becky is still pushing while we integrate. Anyone who copied her files by
# hand is working against a snapshot that goes stale the moment she pushes
# again, and a stale snapshot is invisible - the code compiles, the UI renders,
# and it is simply not what she shipped. This script makes "am I current?"
# a command rather than a memory.
#
# It only ever writes inside becky_ui/. It never touches the integrated copies
# at the repo root, because those carry OUR edits - the node-collision split,
# the jac.toml merge, the bridge wiring. Reconciling her new commits into those
# is a judgement call, so this prints the diff and stops rather than guessing.
set -euo pipefail
cd "$(dirname "$0")/.."

REF="${1:-origin/codex/agentic-workflow-ui}"

git fetch origin --prune >/dev/null 2>&1 || true

if ! git rev-parse --verify --quiet "$REF^{commit}" >/dev/null; then
  echo "!! no such ref: $REF"
  echo "   available:"
  git for-each-ref --format='     %(refname:short)' refs/remotes/origin
  exit 1
fi

NEW="$(git rev-parse --short "$REF")"
# What we last synced, recorded rather than inferred - the working tree cannot
# tell you which commit it came from once files have been copied out of it.
STAMP="becky_ui/.synced-from"
OLD="$(cat "$STAMP" 2>/dev/null || echo "290f3c9")"

echo "==> $REF is at $NEW (last synced: $OLD)"
if [ "$NEW" = "$OLD" ]; then
  echo "    already current - nothing to do"
  exit 0
fi

echo "==> her commits since $OLD"
git log --oneline "$OLD..$REF" | sed 's/^/    /'
echo "==> files she changed"
git diff --stat "$OLD" "$REF" | sed 's/^/    /'

echo "==> replacing becky_ui/ wholesale from $NEW"
# Wholesale, not a merge: becky_ui/ is a mirror with no edits of ours in it, so
# a delete-and-recopy can never leave a file she removed lying around. A
# selective copy would.
rm -rf becky_ui
mkdir -p becky_ui
while IFS= read -r f; do
  mkdir -p "becky_ui/$(dirname "$f")"
  git show "$REF:$f" > "becky_ui/$f"
done < <(git ls-tree -r --name-only "$REF")
echo "$NEW" > "$STAMP"

echo "==> becky_ui/ now mirrors $NEW"

# The part a script must not decide for you. If her new commits touch a file we
# have already moved to the root and edited, someone has to reconcile it.
echo "==> files she changed that we have ALREADY integrated at the root:"
CONFLICTS=0
while IFS= read -r f; do
  base="$(basename "$f")"
  if [ -f "./$base" ] && [ "$f" != "$base" -o -f "./$f" ]; then
    echo "    !! $f  -> also exists at ./$base - RECONCILE BY HAND"
    CONFLICTS=1
  fi
done < <(git diff --name-only "$OLD" "$REF")
[ "$CONFLICTS" = "0" ] && echo "    none - a straight copy is sufficient"

echo
echo "Review, then: git add -A becky_ui && git commit"
