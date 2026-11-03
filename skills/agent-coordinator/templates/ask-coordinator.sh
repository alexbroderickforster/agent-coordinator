#!/bin/bash
# Send the agent coordinator a message from ANY agent or terminal on this
# machine (Codex, Claude Code, Ghostty, iTerm, VS Code...), no multiplexer needed.
# Optionally wait for the reply.
#
# Usage: ask-coordinator.sh --from "<your name/session id>" [--wait SECONDS] "<message>"
#        ask-coordinator.sh --from "<you>" [--wait SECONDS] - <<'EOF'
#        <message: any characters, any number of lines>
#        EOF
# "-" reads the message from stdin, byte for byte (a NUL byte is refused). Use it for anything longer
# than a short line, and ALWAYS when the text holds backticks, $( ), quotes or
# several lines. Quote the heredoc word ('EOF'): with an unquoted EOF the shell
# still runs `...` and $(...) inside it. Short texts ("ACK GO-x") can stay argv.
# Prints the request id. With --wait, blocks until the coordinator replies
# (prints the reply) or the time runs out (exit 2).
# If you don't wait (or the wait runs out), the reply still lands in
# mail/replies/<id>.md, and the coordinator may also type a one-line notice
# into your terminal. Check that file before acting on anything.
# Acknowledge every GO/HOLD you receive: ask-coordinator.sh --from "<you>" "ACK <go-id>"
# (that marks it received in the coordinator's GO ledger).
# Mailbox: $COORD_DIR (default: the folder this script lives in) /mail/
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${COORD_DIR:-$HERE}
FROM=""; WAIT=0
while [ $# -gt 1 ]; do
  case "$1" in
    --from) FROM=$2; shift 2;;
    --wait) WAIT=$2; shift 2;;
    *) break;;
  esac
done
MSG=${1:?message required}
[ $# -le 1 ] || { echo "ask-coordinator: too many arguments; quote the message, or pass - and a quoted <<'EOF' heredoc" >&2; exit 1; }
if [ "$MSG" = "-" ]; then
  [ ! -t 0 ] || { echo "ask-coordinator: '-' reads the message from stdin; use a quoted <<'EOF' heredoc" >&2; exit 1; }
  # byte-exact via a temp file; a NUL byte is refused, never silently cut
  SIN=$(mktemp "${TMPDIR:-/tmp}/coord-ask.XXXXXX") || { echo "ask-coordinator: cannot create a temp file" >&2; exit 1; }
  cat > "$SIN"
  if ! LC_ALL=C tr -d '\000' < "$SIN" | cmp -s - "$SIN"; then
    rm -f "$SIN"; echo "ask-coordinator: stdin holds a NUL byte; refusing (shell text cannot carry it)" >&2; exit 1
  fi
  MSG=$(cat "$SIN"; printf x); MSG=${MSG%x}; rm -f "$SIN"
  [ -n "$MSG" ] || { echo "ask-coordinator: empty message on stdin" >&2; exit 1; }
fi
[ -n "$FROM" ] || { echo "--from is required (who you are, so the coordinator can reply)" >&2; exit 1; }
mkdir -p "$DIR/mail/inbox" "$DIR/mail/replies"
ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TMP="$DIR/mail/inbox/.$ID.tmp"
{ echo "from: $FROM"; echo "id: $ID"; echo "sent: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo
  printf '%s' "$MSG"; case "$MSG" in *$'\n') ;; *) printf '\n';; esac; } > "$TMP"
# "ACK <go-id>" marks the GO received right away (the watcher does it too)
if [ -x "$HERE/go-ledger.sh" ]; then COORD_DIR="$DIR" "$HERE/go-ledger.sh" scan "$TMP" || true; fi
if [ "$WAIT" -gt 0 ]; then   # tell coordinator-reply.sh someone is blocked on this id
  mkdir -p "$DIR/mail/waiting"; echo $$ > "$DIR/mail/waiting/$ID.pid"
  trap 'rm -f "$DIR/mail/waiting/$ID.pid"' EXIT
fi
mv "$TMP" "$DIR/mail/inbox/$ID.md"   # atomic, so the watcher never reads half a message
echo "sent $ID"
[ "$WAIT" -gt 0 ] || exit 0
END=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$END" ]; do
  if [ -f "$DIR/mail/replies/$ID.md" ]; then cat "$DIR/mail/replies/$ID.md"; exit 0; fi
  sleep 5
done
echo "no reply yet for $ID; check later with: cat $DIR/mail/replies/$ID.md" >&2
exit 2
