#!/bin/bash
# Coordinator side: GO/HOLD ledger. A GO counts as RECEIVED only when the peer
# answers "ACK <go-id>". Sent is not received.
#
# Usage:
#   go-ledger.sh add <go-id> <to> <summary...>   log a GO/HOLD you just sent
#   go-ledger.sh ack <go-id> [note]              mark it acknowledged
#   go-ledger.sh cancel <go-id> [reason]         withdrawn / superseded
#   go-ledger.sh pending [--older-than MIN]      un-ACKed GOs, oldest first
#   go-ledger.sh list [N]                        last N rows (default 20)
#   go-ledger.sh scan <file|->                   ACK every pending id quoted as
#                                                "ACK <go-id>" in a message
#                                                (inbox-watch.sh and
#                                                ask-coordinator.sh call this)
#   go-ledger.sh stale [--older-than MIN] [--renag MIN]
#                                                print a STALE-GO line for each
#                                                un-ACKed GO older than MIN
#                                                (default 10), at most once per
#                                                --renag minutes (default 30);
#                                                inbox-watch.sh calls this
# Ledger: $COORD_DIR (default: this script's folder) /mail/go-ledger.tsv
# Columns: id to status sent_utc sent_epoch done_utc nagged_epoch summary
# GO ids: letters, digits and . _ # : / -  (e.g. GO-api-promote, HOLD-db-migrate)
set -euo pipefail
DIR=${COORD_DIR:-$(cd "$(dirname "$0")" && pwd)}
LEDGER="$DIR/mail/go-ledger.tsv"
HEADER=$'id\tto\tstatus\tsent_utc\tsent_epoch\tdone_utc\tnagged_epoch\tsummary'
ID_RE='^[A-Za-z0-9._#:/-]+$'

die() { echo "go-ledger: $*" >&2; exit 1; }
now_epoch() { date -u +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
clean() { printf '%s' "$*" | tr '\t\r\n' '   '; }

init() {
  mkdir -p "$DIR/mail"
  [ -s "$LEDGER" ] || printf '%s\n' "$HEADER" > "$LEDGER"
}

LOCK="$DIR/mail/.go-ledger.lock"
lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    # a lock still held after ~5 s is left over from a killed run
    if [ "$i" -gt 50 ]; then rmdir "$LOCK" 2>/dev/null || true; fi
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

status_of() {  # prints the status of an id, or nothing
  awk -F'\t' -v id="$1" 'NR>1 && $1==id {s=$3} END {if (s!="") print s}' "$LEDGER"
}

set_status() {  # id status  (only PENDING rows change)
  local tmp="$LEDGER.tmp.$$"
  awk -F'\t' -v OFS='\t' -v id="$1" -v st="$2" -v t="$(now_iso)" \
    'NR>1 && $1==id && $3=="PENDING" {$3=st; $6=t} {print}' "$LEDGER" > "$tmp"
  mv "$tmp" "$LEDGER"
}

do_ack() {  # id [quiet]
  local s; s=$(status_of "$1")
  case "$s" in
    PENDING) set_status "$1" ACKED; echo "ACK $1 recorded";;
    ACKED)   [ -n "${2:-}" ] || echo "ACK $1: already acknowledged";;
    "")      [ -n "${2:-}" ] || die "unknown GO id: $1";;
    *)       [ -n "${2:-}" ] || echo "ACK $1: status is $s; left unchanged";;
  esac
}

older_than_arg() {  # parses [--older-than MIN] [--renag MIN] into OLDER / RENAG
  while [ $# -gt 0 ]; do
    case "$1" in
      --older-than) OLDER=${2:?minutes}; shift 2;;
      --renag) RENAG=${2:?minutes}; shift 2;;
      *) die "unknown option: $1";;
    esac
  done
}

CMD=${1:-}
[ $# -gt 0 ] && shift
init
case "$CMD" in
  add)
    [ $# -ge 3 ] || die "usage: go-ledger.sh add <go-id> <to> <summary...>"
    GID=$1; TO=$(clean "$2"); shift 2; SUM=$(clean "$*")
    [[ $GID =~ $ID_RE ]] || die "bad GO id '$GID' (letters, digits, . _ # : / - only)"
    lock
    [ -z "$(status_of "$GID")" ] || die "GO id $GID already in the ledger; pick a new id"
    printf '%s\t%s\tPENDING\t%s\t%s\t\t0\t%s\n' "$GID" "$TO" "$(now_iso)" "$(now_epoch)" "$SUM" >> "$LEDGER"
    echo "logged $GID -> $TO; waiting for \"ACK $GID\""
    ;;
  ack)
    [ $# -ge 1 ] || die "usage: go-ledger.sh ack <go-id> [note]"
    lock; do_ack "$1"
    ;;
  cancel)
    [ $# -ge 1 ] || die "usage: go-ledger.sh cancel <go-id> [reason]"
    lock
    [ "$(status_of "$1")" = PENDING ] || die "$1 is not pending"
    set_status "$1" CANCELLED; echo "cancelled $1"
    ;;
  pending)
    OLDER=0; RENAG=0; older_than_arg "$@"
    awk -F'\t' -v now="$(now_epoch)" -v min="$OLDER" \
      'NR>1 && $3=="PENDING" && (now-$5) >= min*60 {
         printf "PENDING %s to=%s age=%dm sent=%s: %s\n", $1, $2, int((now-$5)/60), $4, $8 }' "$LEDGER"
    ;;
  stale)
    OLDER=${COORD_STALE_MIN:-10}; RENAG=${COORD_RENAG_MIN:-30}; older_than_arg "$@"
    lock
    NOW=$(now_epoch); tmp="$LEDGER.tmp.$$"
    awk -F'\t' -v OFS='\t' -v now="$NOW" -v min="$OLDER" -v renag="$RENAG" -v out="$tmp.out" '
      NR>1 && $3=="PENDING" && (now-$5) >= min*60 && (now-$7) >= renag*60 {
        printf "STALE-GO %s to=%s age=%dm (no ACK; verify live state, re-deliver or cancel): %s\n", $1, $2, int((now-$5)/60), $8 > out
        $7 = now
      } {print}' "$LEDGER" > "$tmp"
    mv "$tmp" "$LEDGER"
    if [ -f "$tmp.out" ]; then cat "$tmp.out"; rm -f "$tmp.out"; fi
    ;;
  list)
    { head -1 "$LEDGER"; tail -n +2 "$LEDGER" | tail -n "${1:-20}"; } | column -t -s $'\t'
    ;;
  scan)
    SRC=${1:--}
    BODY=$(cat -- "$SRC" 2>/dev/null) || exit 0
    IDS=$(printf '%s\n' "$BODY" | grep -oE '(^|[^A-Za-z])ACK[: ]+[A-Za-z0-9._#:/-]+' \
          | sed -E 's|^[^A]*ACK[: ]+||; s|[.:,;#/-]+$||' | sort -u) || true
    [ -n "$IDS" ] || exit 0
    lock
    # shellcheck disable=SC2086  # one id per word, ids never contain spaces
    for GID in $IDS; do do_ack "$GID" quiet; done
    ;;
  ""|-h|--help|help)
    sed -n '2,23p' "$0"
    ;;
  *) die "unknown command: $CMD (try --help)";;
esac
