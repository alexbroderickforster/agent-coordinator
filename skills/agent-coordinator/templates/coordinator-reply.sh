#!/bin/bash
# Coordinator side: answer a mailbox message by its id, then make sure the
# asker actually SEES it. Writing mail/replies/<id>.md alone only reaches an
# asker that is still blocked in `ask-coordinator.sh --wait`.
#
# Usage: coordinator-reply.sh [--go <go-id>] [--no-push] <id> "<reply text>"
#   --go <go-id>  this reply is a GO/HOLD: log it in the GO ledger
#                 (go-ledger.sh) and ask the peer to answer "ACK <go-id>"
#   --no-push     only write the reply file
#
# Push: if the asker isn't waiting, look up its `from:` name in sessions.map
# (name<TAB>workspace:N[/surface:M]; same folder) and type a one-line notice
# into that terminal with cmux-deliver.sh, which verifies submission. No entry,
# or delivery not confirmed: prints a WARNING. Then reach the asker another way
# (SendMessage for Claude Code sessions).
# Your name in notices: $COORD_NAME, else a "@coordinator<TAB>name" line in
# sessions.map, else "coordinator".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${COORD_DIR:-$HERE}
GO=""; PUSH=1
while [ $# -gt 2 ]; do
  case "$1" in
    --go) GO=$2; shift 2;;
    --no-push) PUSH=0; shift;;
    *) break;;
  esac
done
ID=${1:?id required}; TEXT=${2:?reply required}
MAP=${COORD_SESSIONS_MAP:-$DIR/sessions.map}

FROM=""
for f in "$DIR/mail/inbox/$ID.md" "$DIR/mail/inbox/read/$ID.md"; do
  if [ -f "$f" ]; then FROM=$(sed -n 's/^from: //p' "$f" | head -1); break; fi
done

if [ -n "$GO" ]; then
  TEXT="$TEXT

ACK REQUIRED: reply \"ACK $GO\" before acting, e.g.
  $HERE/ask-coordinator.sh --from \"${FROM:-<you>}\" \"ACK $GO\""
fi

mkdir -p "$DIR/mail/replies"
TMP="$DIR/mail/replies/.$ID.tmp"
{ echo "from: coordinator"; echo "re: $ID"; echo "sent: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo; echo "$TEXT"; } > "$TMP"
mv "$TMP" "$DIR/mail/replies/$ID.md"
echo "replied $ID"
REPLY="$DIR/mail/replies/$ID.md"

if [ -n "$GO" ]; then
  COORD_DIR="$DIR" "$HERE/go-ledger.sh" add "$GO" "${FROM:-unknown ($ID)}" "$(printf '%s' "$2" | head -c 120)" \
    || echo "WARNING: GO ledger entry for $GO not written (see above)" >&2
fi
[ "$PUSH" = 1 ] || exit 0

PIDF="$DIR/mail/waiting/$ID.pid"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "asker is blocked in ask-coordinator.sh --wait on $ID; it will print the reply"
  exit 0
fi

NAME=${COORD_NAME:-}
if [ -z "$NAME" ] && [ -f "$MAP" ]; then
  NAME=$(awk -F'\t' '$1=="@coordinator" {print $2; exit}' "$MAP")
fi
NAME=${NAME:-coordinator}

TARGET=""
if [ -n "$FROM" ] && [ -f "$MAP" ]; then
  # exact name (case-insensitive) wins; else the longest entry that is a
  # prefix of the name, followed by a space or "(" (e.g. "Foo" ~ "Foo (abc123)")
  TARGET=$(awk -F'\t' -v from="$FROM" '
    BEGIN { f = tolower(from) }
    /^[[:space:]]*(#|@|$)/ || NF < 2 { next }
    { k = tolower($1); t = $2; gsub(/[[:space:]]/, "", t) }
    k == f { exact = t }
    index(f, k) == 1 && length(k) > best && (length(f) == length(k) || substr(f, length(k) + 1, 1) ~ /[ (]/) { best = length(k); pre = t }
    END { print (exact != "" ? exact : pre) }' "$MAP")
fi

if [ -z "$TARGET" ]; then
  echo "WARNING: no sessions.map entry for '${FROM:-unknown sender}'. The reply is only a file; the asker sees it only if it checks. Also send it via SendMessage (Claude Code) or cmux-say/cmux-deliver, and add the session to $MAP." >&2
  exit 0
fi
RC=0; "$HERE/cmux-deliver.sh" "$TARGET" "[$NAME] reply waiting for $ID: cat $REPLY" || RC=$?
case "$RC" in
  0) echo "notified '$FROM' at $TARGET";;
  3) echo "WARNING: NOT delivered: $TARGET (mapped for '$FROM') is a bare shell, not the agent. The reply file is written; reach the asker another way (SendMessage for Claude Code) and fix $MAP." >&2;;
  *) echo "WARNING: notice to '$FROM' at $TARGET NOT confirmed. The reply file is written; reach the asker another way (SendMessage for Claude Code) and check the map entry." >&2;;
esac
