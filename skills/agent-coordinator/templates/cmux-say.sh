#!/bin/zsh
# Usage: cmux-say.sh <workspace-ref> <surface-ref> <message>
#        cmux-say.sh <workspace-ref> <surface-ref> - <<'EOF'
#        <message: any characters>
#        EOF
# Types a message into another agent's terminal and submits it.
# "-" reads the message from stdin, byte for byte (NUL refused; one trailing newline is
# dropped, since it would be an extra Enter). Use it whenever the text holds
# backticks, $( ), quotes or several lines, and quote the heredoc word ('EOF'):
# with an unquoted EOF the shell still runs `...` and $(...) inside it.
# The key name must be lowercase "enter". Wait before pressing it: TUIs (Codex
# especially) treat fast typed text as a paste, and an Enter that arrives while
# the "paste" is still settling becomes a newline instead of a submit. Longer
# messages need a longer pause, so the wait scales with message length.
[ $# -ge 3 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
ws=$1; sf=$2; shift 2
if [ $# -eq 1 ] && [ "$1" = "-" ]; then
  [ ! -t 0 ] || { echo "cmux-say: '-' reads the message from stdin; use a quoted <<'EOF' heredoc" >&2; exit 2; }
  sin=$(mktemp "${TMPDIR:-/tmp}/coord-say.XXXXXX") || { echo "cmux-say: cannot create a temp file" >&2; exit 2; }
  cat > "$sin"
  if ! LC_ALL=C tr -d '\000' < "$sin" | cmp -s - "$sin"; then
    rm -f "$sin"; echo "cmux-say: stdin holds a NUL byte; refusing" >&2; exit 2
  fi
  msg=$(cat "$sin"; printf x); msg=${msg%x}; rm -f "$sin"   # byte-exact read
  msg=${msg%$'\n'}                        # drop the heredoc's final newline
  [ -n "$msg" ] || { echo "cmux-say: empty message on stdin" >&2; exit 2; }
else
  msg="$*"
fi
CMUX_QUIET=1 cmux send --workspace "$ws" --surface "$sf" -- "$msg" || exit 1
perl -e '$n=shift; $d=1.0+$n/800; $d=4 if $d>4; select(undef,undef,undef,$d)' ${#msg}
CMUX_QUIET=1 cmux send-key --workspace "$ws" --surface "$sf" enter
