#!/bin/bash
# Coordinator side: answer a mailbox message by its id.
# Usage: coordinator-reply.sh <id> "<reply text>"
set -euo pipefail
DIR=${COORD_DIR:-$(cd "$(dirname "$0")" && pwd)}
ID=${1:?id required}; TEXT=${2:?reply required}
mkdir -p "$DIR/mail/replies"
TMP="$DIR/mail/replies/.$ID.tmp"
{ echo "from: coordinator"; echo "re: $ID"; echo "sent: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo; echo "$TEXT"; } > "$TMP"
mv "$TMP" "$DIR/mail/replies/$ID.md"
echo "replied $ID"
