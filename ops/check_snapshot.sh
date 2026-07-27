#!/usr/bin/env bash
# Verify a graph snapshot is safe to put on screen, BEFORE you restore it.
#
#   ops/check_snapshot.sh evidence/graph_backup/anchor_store.CLEANCHAIN.db
#
# WHY: one snapshot (POSTCHAIN-1727) was taken before the LinkedIn sidebar fix.
# Its About evidence carries SIX OTHER PEOPLE - "More profiles for you Emma Wu
# ... Kijoo Song ... Zufan Wu" - scraped out of LinkedIn's recommendations
# rail. The dashboard renders that field and ComposeOutreach cites it, so
# restoring it puts strangers' names on screen during the demo.
#
# Snapshots are opaque .db files. A label is not evidence. Check before you
# restore.
set -uo pipefail
SNAP="${1:-}"
[ -f "$SNAP" ] || { echo "usage: ops/check_snapshot.sh <anchor_store.db>"; exit 2; }

echo "checking $SNAP"
echo "  size: $(wc -c < "$SNAP" | tr -d ' ') bytes"

# Names/markers that should never appear in a prospect's own evidence.
CONTAM='More profiles for you|Emma Wu|Emma Teng|Aaron Teng|Kijoo Song|Zufan Wu|Victor C\.'
hits=$(strings "$SNAP" 2>/dev/null | grep -ciE "$CONTAM" || true)

# Sanity: does it actually contain a chain?
anchors=$(strings "$SNAP" 2>/dev/null | grep -c 'NodeAnchor' || true)
echo "  node anchors: $anchors"

if [ "${hits:-0}" -gt 0 ]; then
  echo
  echo "!! CONTAMINATED - $hits hit(s) for other people's names in the evidence."
  echo "   DO NOT RESTORE THIS FOR THE DEMO. The dashboard renders linkedin_quote"
  echo "   and ComposeOutreach cites it."
  echo "   Use evidence/graph_backup/anchor_store.CLEANCHAIN.db instead."
  exit 1
fi
echo
echo "CLEAN - no foreign names found. Safe to restore."
