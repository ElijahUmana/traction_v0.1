#!/usr/bin/env bash
# Scan the working tree for credentials before they reach a PUBLIC repo.
#
#   ops/secret_scan.sh          # scan tracked + untracked files
#   ops/secret_scan.sh --staged # scan only what is staged (use before a commit)
#
# WHY: two committed Vapi call dumps contained a live Twilio Account SID and
# blocked every push for ~20 minutes. They had not reached GitHub, so nothing
# leaked - but this repo is PUBLIC and the next push would have published a real
# credential permanently. Provider call dumps carry provider-side account
# identifiers; redact them at write time or keep them out of the repo.
#
# Exit 0 = clean, 1 = something found.
set -uo pipefail
cd "$(dirname "$0")/.."

# name|regex  - deliberately conservative; false positives are cheap, misses are not
PATTERNS=(
  "Twilio Account SID|\\bAC[0-9a-fA-F]{32}\\b"
  "Twilio API Key|\\bSK[0-9a-fA-F]{32}\\b"
  "Anthropic key|\\bsk-ant-[A-Za-z0-9_-]{20,}"
  "OpenAI key|\\bsk-[A-Za-z0-9]{32,}"
  "AWS access key|\\bAKIA[0-9A-Z]{16}\\b"
  "Google API key|\\bAIza[0-9A-Za-z_-]{35}\\b"
  "Slack token|\\bxox[baprs]-[0-9A-Za-z-]{10,}"
  "GitHub PAT|\\bgh[pousr]_[A-Za-z0-9]{36,}"
  "Private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)

if [ "${1:-}" = "--staged" ]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACM)
  SCOPE="staged files"
else
  # tracked + untracked, minus ignored
  FILES=$(git ls-files; git ls-files --others --exclude-standard)
  SCOPE="tracked + untracked files"
fi
FILES=$(echo "$FILES" | sort -u | grep -v '^$' || true)
[ -z "$FILES" ] && { echo "nothing to scan"; exit 0; }

echo "scanning $(echo "$FILES" | wc -l | tr -d ' ') $SCOPE"
found=0
while IFS='|' read -r name regex; do
  hits=$(echo "$FILES" | tr '\n' '\0' \
    | xargs -0 grep -lE "$regex" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    found=1
    echo
    echo "!! $name"
    echo "$hits" | sed 's/^/     /'
  fi
done < <(printf '%s\n' "${PATTERNS[@]}")

echo
if [ "$found" = "0" ]; then
  echo "CLEAN - no known credential shapes found."
  exit 0
fi
cat <<'MSG'
BLOCKED. Do not commit these.

This repo is PUBLIC. If a secret reaches GitHub it is compromised even after a
force-push, because it is in the push logs and any fork or clone.

Fix:
  1. Redact the value in the file (keep the artifact, lose the credential).
  2. If it is ALREADY committed locally, rewrite before pushing - in a separate
     clone so nobody's working tree is disturbed:
       git clone . /tmp/scrub && cd /tmp/scrub
       git filter-branch -f --tree-filter '<redact script>' origin/main..HEAD
       git push origin main
     Then everyone runs:  git fetch origin && git reset --mixed origin/main
  3. NEVER use GitHub's "allow this secret" link on a public repo.
MSG
exit 1
