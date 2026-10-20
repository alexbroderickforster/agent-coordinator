#!/bin/zsh
# Usage: cmux-say.sh <workspace-ref> <surface-ref> <message>
# Types a message into another agent's terminal and submits it.
# The key name must be lowercase "enter". Wait before pressing it: TUIs (Codex
# especially) treat fast typed text as a paste, and an Enter that arrives while
# the "paste" is still settling becomes a newline instead of a submit. Longer
# messages need a longer pause, so the wait scales with message length.
ws=$1; sf=$2; shift 2
msg="$*"
CMUX_QUIET=1 cmux send --workspace "$ws" --surface "$sf" -- "$msg" || exit 1
perl -e '$n=shift; $d=1.0+$n/800; $d=4 if $d>4; select(undef,undef,undef,$d)' ${#msg}
CMUX_QUIET=1 cmux send-key --workspace "$ws" --surface "$sf" enter
