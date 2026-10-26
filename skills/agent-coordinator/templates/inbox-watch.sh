#!/bin/bash
# Coordinator side: run in the BACKGROUND. Exits (so the coordinator is
# re-invoked) as soon as a new message arrives, printing it:
#   - local mailbox: $COORD_DIR/mail/inbox/*.md (from ask-coordinator.sh)
#   - optional GitHub issue: set COORD_GH_ISSUE="owner/repo#123" to also watch
#     new comments there (for agents on OTHER machines). Needs `gh`.
#   - GO ledger (if go-ledger.sh sits next to this script): a message saying
#     "ACK <go-id>" marks that GO received; a GO with no ACK after
#     COORD_STALE_MIN minutes (default 10) prints a STALE-GO line and wakes you
#     (repeated every COORD_RENAG_MIN minutes, default 30, until ACK or cancel).
# Exits quietly after ~100 minutes; re-arm it.
# Usage: inbox-watch.sh [SINCE_ISO]   (SINCE applies to GitHub comments; default now)
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${COORD_DIR:-$HERE}
LEDGER_SH="$HERE/go-ledger.sh"
[ -x "$LEDGER_SH" ] || LEDGER_SH=""
SINCE=${1:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
mkdir -p "$DIR/mail/inbox/read"
DEADLINE=$(( $(date +%s) + 6000 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  FOUND=0
  for f in "$DIR"/mail/inbox/*.md; do
    [ -e "$f" ] || continue
    echo "=== MAILBOX $(basename "$f" .md)"; cat "$f"; echo
    [ -n "$LEDGER_SH" ] && COORD_DIR="$DIR" "$LEDGER_SH" scan "$f"
    mv "$f" "$DIR/mail/inbox/read/"
    FOUND=1
  done
  if [ -n "${COORD_GH_ISSUE:-}" ]; then
    REPO=${COORD_GH_ISSUE%#*}; NUM=${COORD_GH_ISSUE#*#}
    NEW=$(gh api "repos/$REPO/issues/$NUM/comments?since=$SINCE&per_page=50" \
          -q ".[] | select(.created_at > \"$SINCE\") | \"=== GITHUB \(.html_url)\nfrom: \(.user.login)\nsent: \(.created_at)\n\n\(.body)\n\"" 2>/dev/null)
    if [ -n "$NEW" ]; then
      echo "$NEW"
      [ -n "$LEDGER_SH" ] && printf '%s\n' "$NEW" | COORD_DIR="$DIR" "$LEDGER_SH" scan -
      LAST=$(gh api "repos/$REPO/issues/$NUM/comments?since=$SINCE&per_page=50" -q '[.[].created_at] | max' 2>/dev/null)
      echo "RESUME_SINCE=$LAST"
      FOUND=1
    fi
  fi
  if [ -n "$LEDGER_SH" ]; then
    STALE=$(COORD_DIR="$DIR" "$LEDGER_SH" stale 2>/dev/null)
    if [ -n "$STALE" ]; then echo "$STALE"; FOUND=1; fi
  fi
  [ "$FOUND" = 1 ] && exit 0
  sleep 15
done
echo "QUIET: no messages (re-arm: inbox-watch.sh $SINCE)"
