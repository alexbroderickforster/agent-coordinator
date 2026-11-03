#!/bin/bash
# Coordinator side: answer a mailbox message by its id, then make sure the
# asker actually SEES it. Writing mail/replies/<id>.md alone only reaches an
# asker that is still blocked in `ask-coordinator.sh --wait`.
#
# Usage: coordinator-reply.sh [--go <go-id> [GO options]] [--no-push] <id> "<reply text>"
#        coordinator-reply.sh [options] <id> - <<'EOF'
#        <reply text: any characters, any number of lines>
#        EOF
#   -             read the reply from stdin. Use this for anything longer than a
#                 few words, and ALWAYS when the text holds backticks, $( ),
#                 quotes or several lines. Quote the heredoc word ('EOF'): with
#                 an unquoted EOF the shell still runs `...` and $(...) in it.
#   --go <go-id>  this reply is a GO/HOLD: log it in the GO ledger
#                 (go-ledger.sh) and ask the peer to answer "ACK <go-id>"
#   GO options (passed to go-ledger.sh add): --kind GO|HOLD --service S
#                 --action A --artifact X --expires WHEN
#   --no-push     only write the reply file
# A second reply to the same id keeps the earlier one(s) below the new one.
# With --go the ledger entry is written FIRST; if that fails, nothing is
# written or sent and the exit code is 1. If the reply then can't be written,
# the GO is revoked (exit 1); if that revoke fails too, exit 3 with
# "GO <id> NOT REVOKED: still PENDING". A NUL byte on stdin is refused.
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
GO=""; PUSH=1; GOARGS=()
while [ $# -gt 2 ]; do
  case "$1" in
    --go) GO=$2; shift 2;;
    --kind|--service|--action|--artifact|--expires) GOARGS+=("$1" "$2"); shift 2;;
    --no-push) PUSH=0; shift;;
    *) break;;
  esac
done
ID=${1:?id required}; TEXT=${2:?reply required}
[ $# -le 2 ] || { echo "coordinator-reply: too many arguments; quote the reply, or pass - and a quoted <<'EOF' heredoc" >&2; exit 1; }
if [ "${#GOARGS[@]}" -gt 0 ] && [ -z "$GO" ]; then echo "coordinator-reply: --kind/--service/--action/--artifact/--expires need --go <go-id>" >&2; exit 1; fi
if [ "$TEXT" = "-" ]; then
  [ ! -t 0 ] || { echo "coordinator-reply: '-' reads the reply from stdin; use a quoted <<'EOF' heredoc" >&2; exit 1; }
  # byte-exact via a temp file; a NUL byte is refused, never silently cut
  SIN=$(mktemp "${TMPDIR:-/tmp}/coord-reply.XXXXXX") || { echo "coordinator-reply: cannot create a temp file" >&2; exit 1; }
  cat > "$SIN"
  if ! LC_ALL=C tr -d '\000' < "$SIN" | cmp -s - "$SIN"; then
    rm -f "$SIN"; echo "coordinator-reply: stdin holds a NUL byte; refusing (shell text cannot carry it)" >&2; exit 1
  fi
  TEXT=$(cat "$SIN"; printf x); TEXT=${TEXT%x}; rm -f "$SIN"
  [ -n "$TEXT" ] || { echo "coordinator-reply: empty reply on stdin" >&2; exit 1; }
fi
BODY=$TEXT
MAP=${COORD_SESSIONS_MAP:-$DIR/sessions.map}

FROM=""
for f in "$DIR/mail/inbox/$ID.md" "$DIR/mail/inbox/read/$ID.md"; do
  if [ -f "$f" ]; then FROM=$(sed -n 's/^from: //p' "$f" | head -1); break; fi
done

# A GO is recorded in the ledger BEFORE anything is written or sent: if the
# ledger refuses (duplicate id, bad --expires ...), nothing reaches the peer.
if [ -n "$GO" ]; then
  FLAT=$(printf '%s' "$BODY" | LC_ALL=C tr '\r\n\t' '   ')
  SUMMARY=$(LC_ALL=en_US.UTF-8 bash -c 'printf "%s" "${1:0:120}"' _ "$FLAT" 2>/dev/null) || SUMMARY=${FLAT:0:120}
  if ! COORD_DIR="$DIR" "$HERE/go-ledger.sh" add "$GO" "${FROM:-unknown ($ID)}" ${GOARGS[@]+"${GOARGS[@]}"} -- "$SUMMARY"; then
    echo "coordinator-reply: GO $GO was NOT recorded in the ledger (see above); the reply was NOT written or sent" >&2
    exit 1
  fi
  while [ "${TEXT%$'\n'}" != "$TEXT" ]; do TEXT=${TEXT%$'\n'}; done
  TEXT="$TEXT

ACK REQUIRED: reply \"ACK $GO\" before acting, e.g.
  $HERE/ask-coordinator.sh --from \"${FROM:-<you>}\" \"ACK $GO\""
fi

# A second reply to the same id must not overwrite the first (a GO reply was
# once replaced by a later verdict reply to the same id). Keep the earlier
# reply(ies) below the new one, newest first.
PREV="$DIR/mail/replies/$ID.md"
TMP="$DIR/mail/replies/.$ID.tmp"
# Every write is checked on its own: write_reply runs inside `if !`, where
# bash ignores errexit, so a failed printf/cat would otherwise be skipped and a
# truncated reply published.
write_reply() {
  mkdir -p "$DIR/mail/replies" || return 1
  printf 'from: coordinator\nre: %s\nsent: %s\n\n' "$ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP" || return 1
  printf '%s' "$TEXT" >> "$TMP" || return 1
  case "$TEXT" in *$'\n') ;; *) printf '\n' >> "$TMP" || return 1;; esac
  if [ -f "$PREV" ]; then
    printf '\n----- earlier reply to %s (still in force) -----\n' "$ID" >> "$TMP" || return 1
    cat "$PREV" >> "$TMP" || return 1
  fi
  mv "$TMP" "$DIR/mail/replies/$ID.md" || return 1
}
if ! write_reply 2>/dev/null; then
  rm -f "$TMP" 2>/dev/null || true
  if [ -n "$GO" ]; then
    if COORD_DIR="$DIR" "$HERE/go-ledger.sh" revoke "$GO" "reply to $ID could not be written; never sent" >&2; then
      echo "coordinator-reply: could not write $DIR/mail/replies/$ID.md; nothing sent, GO $GO revoked" >&2
      exit 1
    fi
    echo "coordinator-reply: could not write $DIR/mail/replies/$ID.md; nothing sent. GO $GO NOT REVOKED: still PENDING in the ledger. Revoke it by hand: go-ledger.sh revoke $GO <reason>" >&2
    exit 3
  fi
  echo "coordinator-reply: could not write $DIR/mail/replies/$ID.md; nothing sent" >&2
  exit 1
fi
echo "replied $ID"
REPLY="$DIR/mail/replies/$ID.md"

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
