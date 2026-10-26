#!/bin/bash
# Type a one-line message into another agent's terminal (Codex, Claude Code,
# any TUI inside cmux), submit it, and VERIFY that it was submitted.
#
# Usage: cmux-deliver.sh <workspace>[/<surface>] [<surface>] <text...>
#   e.g. cmux-deliver.sh workspace:43 "[coordinator] reply waiting ..."
#        cmux-deliver.sh workspace:43/surface:187 "..."
#        cmux-deliver.sh workspace:43 surface:187 "..."
# Exit 0: submitted (the input box no longer holds the text, or the text shows
#         above it as a sent message).
# Exit 1: still unsent after the timeout; prints the screen tail. Follow up by
#         hand or on another channel.
#
# Why: a TUI treats fast-typed text as a paste. An Enter that lands while the
# paste is settling becomes a newline, so the message sits unsent. A busy Codex
# shows "tab to queue" and needs Tab instead. So: send, wait, press Enter, then
# poll read-screen and press Enter or Tab again until the text has left the
# input box.
# Env: CMUX_DELIVER_TIMEOUT (seconds, default 10).
set -uo pipefail
[ $# -ge 2 ] || { sed -n '2,12p' "$0" >&2; exit 2; }
WS=$1; shift
SF=""
case "$WS" in */*) SF=${WS#*/}; WS=${WS%%/*};; esac
if [ -z "$SF" ] && [ $# -ge 2 ] && [[ $1 =~ ^(surface:[0-9]+|[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27})$ ]]; then
  SF=$1; shift
fi
# one line only: a newline would submit early; cmux send also turns the
# two-character sequences \n \r \t into keys, so neutralise those too
TEXT=$(printf '%s' "$*" | tr '\r\n' '  ' | sed -E 's/\\([nrt])/\/\1/g')
[ -n "$TEXT" ] || { echo "cmux-deliver: empty text" >&2; exit 2; }
TIMEOUT=${CMUX_DELIVER_TIMEOUT:-10}

T=(--workspace "$WS"); [ -n "$SF" ] && T+=(--surface "$SF")
export CMUX_QUIET=1
screen() { cmux read-screen "${T[@]}" 2>/dev/null; }
key() { cmux send-key "${T[@]}" "$1" >/dev/null 2>&1; }
squash() { tr -d '[:space:]'; }

# The probe is the END of the text (ids and paths live there), whitespace
# removed so terminal line-wrapping can't hide it.
FLAT=$(printf '%s' "$TEXT" | squash)
PROBE=$FLAT; [ "${#FLAT}" -gt 24 ] && PROBE=${FLAT: -24}

# Split the screen into the input box (from the last prompt line down) and
# what's above it. Prompts: "›" (Codex), "❯" (Claude Code). No prompt found:
# treat the last 4 non-empty lines as the input area.
split_screen() {
  local s=$1 n
  n=$(printf '%s\n' "$s" | grep -nE '^[[:space:]│|]*(›|❯)' | tail -1 | cut -d: -f1)
  if [ -z "$n" ]; then
    n=$(printf '%s\n' "$s" | grep -n '[^[:space:]]' | tail -4 | head -1 | cut -d: -f1)
    n=${n:-1}
  fi
  ABOVE=$(printf '%s\n' "$s" | head -n $((n - 1)))
  INPUT=$(printf '%s\n' "$s" | tail -n +"$n")
}
in_input() {  # is our text (or a paste placeholder) still in the input box?
  printf '%s' "$INPUT" | grep -q '\[Pasted' && return 0
  printf '%s' "$INPUT" | squash | grep -qF -- "$PROBE"
}
seen_above() { printf '%s' "$ABOVE" | squash | grep -qF -- "$PROBE"; }

cmux send "${T[@]}" -- "$TEXT" >/dev/null || { echo "cmux-deliver: cmux send failed for $WS${SF:+/$SF}" >&2; exit 1; }
# let the paste settle: 1 s + length/800 s, max 4 s
perl -e '$n=shift; $d=1.0+$n/800; $d=4 if $d>4; select(undef,undef,undef,$d)' "${#TEXT}"
split_screen "$(screen)"
PRESEEN=0; in_input && PRESEEN=1
key enter

END=$(( $(date +%s) + TIMEOUT )); LASTKEY=$(date +%s)
while :; do
  sleep 1
  S=$(screen); split_screen "$S"
  if in_input; then
    if [ $(( $(date +%s) - LASTKEY )) -ge 2 ]; then
      if printf '%s' "$S" | grep -qi 'tab to queue'; then key tab; else key enter; fi
      LASTKEY=$(date +%s)
    fi
  elif seen_above; then
    echo "delivered to $WS${SF:+/$SF} (shows as sent)"; exit 0
  elif [ "$PRESEEN" = 1 ]; then
    echo "delivered to $WS${SF:+/$SF} (input box cleared)"; exit 0
  fi
  [ "$(date +%s)" -lt "$END" ] || break
done
echo "cmux-deliver: NOT CONFIRMED for $WS${SF:+/$SF} after ${TIMEOUT}s; screen tail:" >&2
printf '%s\n' "$S" | grep -v '^[[:space:]]*$' | tail -12 >&2
exit 1
