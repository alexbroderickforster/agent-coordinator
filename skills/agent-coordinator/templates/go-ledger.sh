#!/bin/bash
# Coordinator side: GO/HOLD ledger. A GO counts as RECEIVED only when the peer
# answers "ACK <go-id>". Sent is not received. Received is not authorised
# either: a gate asks `check`, which passes only a typed, fully scoped, live GO.
#
# Usage:
#   go-ledger.sh add <go-id> <to> [--kind GO|HOLD] [--service S] [--action A]
#                [--artifact X] [--expires WHEN] [--] <summary...>
#                                                log a GO/HOLD you just sent.
#                                                Old form `add <id> <to> <summary>`
#                                                still works: kind GO (HOLD when
#                                                the id starts with HOLD), scope
#                                                "unspecified" (such an entry is
#                                                tracked but never passes check)
#                                                WHEN: 90m | 2h | 1d | 30s |
#                                                @<epoch> | 2030-01-31T18:00:00Z
#                                                S/A/X may be comma lists (stage,promote)
#   go-ledger.sh ack <go-id> [note]              mark it acknowledged
#   go-ledger.sh cancel <go-id> [reason]         withdrawn / superseded (PENDING only)
#   go-ledger.sh revoke <go-id> <reason>         withdraw a PENDING or ACKED entry
#   go-ledger.sh check <go-id> --service S --action A --artifact X [--consume]
#                                                exit 0 only for an ACKED GO whose
#                                                service, action AND artifact are
#                                                all set and all match, not
#                                                expired, consumed or revoked.
#                                                A HOLD never passes; neither does
#                                                an unscoped or legacy entry.
#                                                --consume claims it in the same
#                                                locked step.
#   go-ledger.sh consume <go-id>                 mark an ACKED GO used (single use)
#   go-ledger.sh show <go-id>                    every field of one entry
#   go-ledger.sh pending [--older-than MIN]      un-ACKed GOs, oldest first
#   go-ledger.sh list [N]                        last N rows (default 20)
#   go-ledger.sh list --typed [N]                same, with kind/scope/expiry columns
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
#          kind service action artifact expires_epoch closed_utc note
# Rows written before the typed ledger have only the first 8 columns; they read
# as kind GO (HOLD if the id starts with HOLD), scope "unspecified", no expiry.
# The file is never bulk-rewritten to add them.
# An entry with no explicit --expires fails `check` 120 minutes after it was
# sent. Fixed on purpose: the caller's environment cannot lengthen it.
# Statuses: PENDING ACKED CANCELLED CONSUMED REVOKED
# Lock: mail/.go-ledger.lock (a directory holding an owner token). A lock is
# only ever broken when its owner process is gone, by renaming it away, and
# breakers take turns under a kernel flock; a live holder (even a suspended
# one) is never robbed. Waiters give up after COORD_LOCK_WAIT_SEC (20) and
# change nothing.
# GO ids: letters, digits and . _ # : / -  (e.g. GO-api-promote, HOLD-db-migrate)
set -euo pipefail
DIR=${COORD_DIR:-$(cd "$(dirname "$0")" && pwd)}
LEDGER="$DIR/mail/go-ledger.tsv"
HEADER=$'id\tto\tstatus\tsent_utc\tsent_epoch\tdone_utc\tnagged_epoch\tsummary\tkind\tservice\taction\tartifact\texpires_epoch\tclosed_utc\tnote'
ID_RE='^[A-Za-z0-9._#:/-]+$'
UNSPEC=unspecified
HOLD_RE='^HOLD([-_.:/#]|$)'
HEX_RE='^[0-9a-f]{7,40}$'
NUM_RE='^[0-9]+$'
TTL_MIN=120

die() { echo "go-ledger: $*" >&2; exit 1; }
warn() { echo "go-ledger: WARNING: $*" >&2; }
now_epoch() { date -u +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# one line, no tabs, valid UTF-8 (macOS `column` drops a row with a broken byte)
clean() {
  local s
  s=$(printf '%s' "$*" | LC_ALL=C tr '\t\r\n' '   ' | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null) || true
  printf '%s' "$s"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
iso_of() {  # epoch -> ISO UTC
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}
[ -z "${COORD_GO_TTL_MIN:-}" ] || warn "COORD_GO_TTL_MIN is ignored; the default expiry is fixed at ${TTL_MIN}m (use add --expires)"

# ---- lock -------------------------------------------------------------------
LOCK="$DIR/mail/.go-ledger.lock"
BREAKER="$DIR/mail/.go-ledger.breaker"
LOCKED=0
TOKEN=""
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }
# Break the lock iff it still holds exactly <owner> and that owner is gone.
# Runs under an exclusive flock on $BREAKER, so two breakers never interleave;
# the rename means a half-finished break can't leave a half-removed lock.
break_if_dead() {  # <owner line as read>
  perl -MFcntl=:flock -e '
    my ($lock, $breaker, $seen, $grave) = @ARGV;
    open(my $b, ">>", $breaker) or exit 3;
    local $SIG{ALRM} = sub { exit 4 }; alarm 5;
    flock($b, LOCK_EX) or exit 3; alarm 0;
    open(my $o, "<", "$lock/owner") or exit 1;      # ownerless: never break
    my $cur = <$o>; close $o; chomp $cur;
    exit 1 unless $cur eq $seen;                     # changed since we looked
    my ($pid, $tok, $start) = split /\t/, $cur;
    exit 1 unless defined $pid && $pid =~ /^\d+$/;
    if (kill(0, $pid) || !$!{ESRCH}) {               # pid exists: same process?
      my $now = `ps -o lstart= -p $pid 2>/dev/null`; $now =~ s/\s+/ /g; $now =~ s/^ | $//g;
      exit 1 if !defined $start || $start eq "" || $now eq $start;
    }
    rename($lock, $grave) or exit 1;                 # only one rename can win
    exit 0;' "$LOCK" "$BREAKER" "$1" "$2"
}
lock() {
  mkdir -p "$DIR/mail"
  local wait=${COORD_LOCK_WAIT_SEC:-20} i=0 owner pid grave start
  start=$(proc_start $$)
  TOKEN="$$.$(date +%s).$RANDOM$RANDOM"
  # Traps go in BEFORE the lock is taken: EXIT always runs
  # unlock (a no-op until we hold the lock), and INT/TERM/HUP are only noted
  # while we acquire, so no signal can land between mkdir and the owner file
  # and leave an ownerless lock (which is never broken). We act on a deferred
  # signal once the lock is fully ours, and EXIT releases it.
  PENDING_SIG=""
  trap 'unlock' EXIT
  trap 'PENDING_SIG=130' INT; trap 'PENDING_SIG=143' TERM; trap 'PENDING_SIG=129' HUP
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    owner=$(head -1 "$LOCK/owner" 2>/dev/null || true)
    pid=${owner%%$'\t'*}
    # candidate only if the owner pid is gone, or now belongs to another
    # process (different start time); the breaker re-checks under its flock
    if [ -n "$owner" ] && [[ $pid =~ $NUM_RE ]] \
       && { ! kill -0 "$pid" 2>/dev/null || [ "$(proc_start "$pid")" != "$(printf '%s' "$owner" | cut -f3)" ]; }; then
      grave="$LOCK.dead.$TOKEN.$i"
      if break_if_dead "$owner" "$grave"; then
        rm -rf "$grave"; echo "go-ledger: broke a lock left by dead pid $pid" >&2; continue
      fi
    fi
    [ "$i" -lt $((wait * 20)) ] || die "ledger lock held by ${owner:-an unknown owner (no owner file)}; waited ${wait}s, changed nothing. A holder that is alive (even stopped) is never robbed; if no go-ledger runs, inspect $LOCK by hand."
    sleep 0.05
  done
  LOCKED=1          # from here on, unlock removes our own (possibly ownerless) lock
  if [ -n "${COORD_LOCK_TEST_ACQUIRE_PAUSE:-}" ]; then sleep "$COORD_LOCK_TEST_ACQUIRE_PAUSE"; fi  # tests only: widen the mkdir->owner window
  # owner file appears atomically (temp + rename inside the lock dir)
  printf '%s\t%s\t%s\n' "$$" "$TOKEN" "$start" > "$LOCK/.owner.$TOKEN"
  mv "$LOCK/.owner.$TOKEN" "$LOCK/owner"
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
  if [ -n "$PENDING_SIG" ]; then exit "$PENDING_SIG"; fi
  if [ -n "${COORD_LOCK_TEST_HOLD_SEC:-}" ]; then sleep "$COORD_LOCK_TEST_HOLD_SEC"; fi  # tests only
}
unlock() {
  [ "$LOCKED" = 1 ] || return 0
  LOCKED=0
  local cur; cur=$(head -1 "$LOCK/owner" 2>/dev/null || true)
  if [ "$(printf '%s' "$cur" | cut -f2)" = "$TOKEN" ]; then
    mv "$LOCK" "$LOCK.released.$TOKEN" 2>/dev/null && rm -rf "$LOCK.released.$TOKEN"
  elif [ -z "$cur" ] && [ -d "$LOCK" ]; then
    # we created it (mkdir succeeded) but never wrote the owner file; nobody
    # else ever touches an ownerless lock, so it is ours to remove
    rm -f "$LOCK/.owner.$TOKEN" 2>/dev/null; rmdir "$LOCK" 2>/dev/null || true
  else
    echo "go-ledger: WARNING: the lock no longer carries my token ($TOKEN); left it alone" >&2
  fi
}

# ---- file helpers -----------------------------------------------------------
# create the ledger (header only) atomically; call with the lock held
ensure_ledger() {
  [ -s "$LEDGER" ] && return 0
  local tmp="$LEDGER.tmp.$$"
  printf '%s\n' "$HEADER" > "$tmp"; mv "$tmp" "$LEDGER"
}
# readers never create the file; an absent ledger reads as header only.
# Every consumer reads to the end (awk), so no SIGPIPE under pipefail.
ledger_cat() { if [ -s "$LEDGER" ]; then cat "$LEDGER"; else printf '%s\n' "$HEADER"; fi; }

status_of() {  # prints the status of an id, or nothing
  ledger_cat | awk -F'\t' -v id="$1" 'NR>1 && $1==id {s=$3} END {if (s!="") print s}'
}

# update_row <id> <allowed statuses, |-separated> <new status> [<f6|-> <f14> <f15>]
# Rewrites the file to a temp copy and mv's it over (lock must be held).
update_row() {
  local tmp="$LEDGER.tmp.$$"
  awk -F'\t' -v OFS='\t' -v id="$1" -v from="|$2|" -v st="$3" -v t="$(now_iso)" \
      -v f6="${4:-}" -v f14="${5:-}" -v f15="${6:-}" '
    NR>1 && $1==id && index(from, "|" $3 "|") {
      $3 = st
      if (f6 == "t") $6 = t
      if (f14 != "") $14 = f14
      if (f15 != "") $15 = f15
    } {print}' "$LEDGER" > "$tmp"
  mv "$tmp" "$LEDGER"
}
set_status() { update_row "$1" PENDING "$2" t; }  # id status (only PENDING rows change)

# Print one entry as 15 US-separated fields, legacy defaults filled in.
# Empty output: unknown id.
US=$'\037'
row_of() {
  ledger_cat | awk -F'\t' -v OFS="$US" -v id="$1" -v un="$UNSPEC" '
    NR>1 && $1==id { r = $0 }
    END {
      if (r == "") exit
      n = split(r, f, "\t")
      for (i = n + 1; i <= 15; i++) f[i] = ""
      if (f[9] == "") { k = toupper(f[1]); f[9] = (k ~ /^HOLD([-_.:\/#]|$)/) ? "HOLD" : "GO" }
      for (i = 10; i <= 12; i++) if (f[i] == "") f[i] = un
      legacy = (n <= 8) ? "legacy" : "typed"
      for (i = 1; i <= 15; i++) if (f[i] == "") f[i] = "-"
      print f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15], legacy
    }'
}
load_row() {  # sets R_* from row_of; returns 1 when unknown
  local line; line=$(row_of "$1")
  [ -n "$line" ] || return 1
  IFS="$US" read -r R_ID R_TO R_STATUS R_SENT R_SENT_EPOCH R_DONE _R_NAG R_SUM R_KIND \
    R_SERVICE R_ACTION R_ARTIFACT R_EXPIRES R_CLOSED R_NOTE R_FORMAT <<< "$line"
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

parse_expiry() {  # WHEN -> epoch (empty for none)
  local w=$1 n
  case "$w" in
    ""|none) return 0;;
    @*) n=${w#@}; [[ $n =~ $NUM_RE ]] || die "bad --expires '$w'"; echo "$n";;
    *[0-9][smhd])
      n=${w%?}; [[ $n =~ $NUM_RE ]] || die "bad --expires '$w'"
      case "$w" in
        *s) echo $(( $(now_epoch) + n ));;
        *m) echo $(( $(now_epoch) + n * 60 ));;
        *h) echo $(( $(now_epoch) + n * 3600 ));;
        *d) echo $(( $(now_epoch) + n * 86400 ));;
      esac;;
    [0-9][0-9][0-9][0-9]-*T*Z)
      date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$w" +%s 2>/dev/null \
        || date -u -d "$w" +%s 2>/dev/null || die "bad --expires '$w' (use 2030-01-31T18:00:00Z)";;
    *) die "bad --expires '$w' (90m, 2h, 1d, @epoch or ISO UTC)";;
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

deny() { echo "go-ledger: DENY $GID: $*" >&2; exit 1; }

# scope_match <field name> <entry value> <wanted value>: both must be set.
# Entry value may be a comma list; hex artifacts (SHAs, >= 7 chars) match by
# prefix either way. No globbing anywhere.
scope_match() {
  local name=$1 have want item items
  have=$(lower "$2"); want=$(lower "$3")
  if [ "$have" = "$UNSPEC" ] || [ "$have" = "-" ] || [ -z "$have" ]; then
    deny "has no $name scope (legacy or unscoped entry); only a GO with service, action and artifact all set can authorise"
  fi
  IFS=, read -r -a items <<< "$have"
  [ "${#items[@]}" -gt 0 ] || deny "has an empty $name scope"
  for item in "${items[@]}"; do
    item=${item// /}
    [ -n "$item" ] || continue
    [ "$item" = "$want" ] && return 0
    if [ "$name" = artifact ] && [[ $item =~ $HEX_RE ]] && [[ $want =~ $HEX_RE ]]; then
      case "$item" in "$want"*) return 0;; esac
      case "$want" in "$item"*) return 0;; esac
    fi
  done
  deny "$name is '$2', not '$3'"
}

# the whole decision; caller holds the lock when it will also consume
check_entry() {  # uses GID C_SERVICE C_ACTION C_ARTIFACT
  load_row "$GID" || deny "unknown id"
  [ "$R_KIND" = GO ] || deny "kind is $R_KIND; a HOLD never authorises anything"
  case "$R_STATUS" in
    ACKED) ;;
    PENDING) deny "not acknowledged yet (sent is not received)";;
    CONSUMED) deny "already consumed at $R_CLOSED (single use; ask for a new GO)";;
    REVOKED) deny "revoked at $R_CLOSED: $R_NOTE";;
    *) deny "status is $R_STATUS";;
  esac
  local now; now=$(now_epoch)
  if [ "$R_EXPIRES" != "-" ]; then
    [ "$now" -lt "$R_EXPIRES" ] || deny "expired at $(iso_of "$R_EXPIRES")"
  else
    [ $(( now - R_SENT_EPOCH )) -lt $(( TTL_MIN * 60 )) ] \
      || deny "no --expires and older than the fixed ${TTL_MIN}m default (sent $R_SENT)"
  fi
  scope_match service "$R_SERVICE" "$C_SERVICE"
  scope_match action "$R_ACTION" "$C_ACTION"
  scope_match artifact "$R_ARTIFACT" "$C_ARTIFACT"
}

CMD=${1:-}
[ $# -gt 0 ] && shift
case "$CMD" in
  add)
    [ $# -ge 3 ] || die "usage: go-ledger.sh add <go-id> <to> [--kind GO|HOLD] [--service S] [--action A] [--artifact X] [--expires WHEN] [--] <summary...>"
    GID=$1; TO=$(clean "$2"); shift 2
    KIND=""; SERVICE=$UNSPEC; ACTION=$UNSPEC; ARTIFACT=$UNSPEC; EXPIRES=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) KIND=$(printf '%s' "${2:?--kind GO|HOLD}" | tr '[:lower:]' '[:upper:]'); shift 2;;
        --service) SERVICE=$(clean "${2:?--service value}"); shift 2;;
        --action) ACTION=$(clean "${2:?--action value}"); shift 2;;
        --artifact) ARTIFACT=$(clean "${2:?--artifact value}"); shift 2;;
        --expires) EXPIRES=$(parse_expiry "${2:?--expires value}") || exit 1; shift 2;;
        --) shift; break;;
        *) break;;
      esac
    done
    [ $# -ge 1 ] || die "summary required"
    SUM=$(clean "$*")
    [[ $GID =~ $ID_RE ]] || die "bad GO id '$GID' (letters, digits, . _ # : / - only)"
    UPID=$(printf '%s' "$GID" | tr '[:lower:]' '[:upper:]')
    if [ -z "$KIND" ]; then
      if [[ $UPID =~ $HOLD_RE ]]; then KIND=HOLD; else KIND=GO; fi
    fi
    case "$KIND" in GO|HOLD) ;; *) die "--kind must be GO or HOLD, not '$KIND'";; esac
    if [ "$KIND" = GO ] && [[ $UPID =~ $HOLD_RE ]]; then warn "$GID looks like a HOLD id but is logged as kind GO"; fi
    for v in "$SERVICE" "$ACTION" "$ARTIFACT"; do [ -n "$v" ] || die "empty scope value"; done
    lock; ensure_ledger
    [ -z "$(status_of "$GID")" ] || die "GO id $GID already in the ledger; pick a new id"
    tmp="$LEDGER.tmp.$$"
    cp "$LEDGER" "$tmp"
    printf '%s\t%s\tPENDING\t%s\t%s\t\t0\t%s\t%s\t%s\t%s\t%s\t%s\t\t\n' "$GID" "$TO" "$(now_iso)" "$(now_epoch)" "$SUM" \
      "$KIND" "$SERVICE" "$ACTION" "$ARTIFACT" "$EXPIRES" >> "$tmp"
    mv "$tmp" "$LEDGER"
    echo "logged $GID -> $TO; waiting for \"ACK $GID\""
    if [ "$KIND" = GO ] && { [ "$SERVICE" = "$UNSPEC" ] || [ "$ACTION" = "$UNSPEC" ] || [ "$ARTIFACT" = "$UNSPEC" ]; }; then
      warn "$GID has no full scope (--service, --action, --artifact); it is tracked but can never pass check"
    fi
    ;;
  ack)
    [ $# -ge 1 ] || die "usage: go-ledger.sh ack <go-id> [note]"
    lock; ensure_ledger; do_ack "$1"
    ;;
  cancel)
    [ $# -ge 1 ] || die "usage: go-ledger.sh cancel <go-id> [reason]"
    lock; ensure_ledger
    [ "$(status_of "$1")" = PENDING ] || die "$1 is not pending"
    set_status "$1" CANCELLED; echo "cancelled $1"
    ;;
  revoke)
    [ $# -ge 2 ] || die "usage: go-ledger.sh revoke <go-id> <reason>"
    GID=$1; shift; REASON=$(clean "$*")
    lock; ensure_ledger
    S=$(status_of "$GID")
    case "$S" in
      PENDING|ACKED) update_row "$GID" "PENDING|ACKED" REVOKED - "$(now_iso)" "$REASON"; echo "revoked $GID (was $S): $REASON";;
      "") die "unknown GO id: $GID";;
      *) die "$GID is $S; only PENDING or ACKED entries can be revoked";;
    esac
    ;;
  consume)
    [ $# -ge 1 ] || die "usage: go-ledger.sh consume <go-id>"
    GID=$1
    lock; ensure_ledger
    load_row "$GID" || die "unknown GO id: $GID"
    [ "$R_KIND" = GO ] || die "$GID is a $R_KIND; only a GO can be consumed"
    [ "$R_STATUS" = ACKED ] || die "$GID is $R_STATUS; only an ACKED GO can be consumed"
    update_row "$GID" ACKED CONSUMED - "$(now_iso)" "consumed"
    echo "consumed $GID"
    ;;
  check)
    [ $# -ge 1 ] || die "usage: go-ledger.sh check <go-id> --service S --action A --artifact X [--consume]"
    GID=$1; shift
    C_SERVICE=""; C_ACTION=""; C_ARTIFACT=""; CONSUME=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --service) C_SERVICE=${2:?--service value}; shift 2;;
        --action) C_ACTION=${2:?--action value}; shift 2;;
        --artifact) C_ARTIFACT=${2:?--artifact value}; shift 2;;
        --consume) CONSUME=1; shift;;
        *) die "unknown option: $1";;
      esac
    done
    [ -n "$C_SERVICE" ] && [ -n "$C_ACTION" ] && [ -n "$C_ARTIFACT" ] \
      || die "check needs --service, --action and --artifact (the exact SHA/revision/PR being acted on)"
    if [ "$CONSUME" = 1 ]; then lock; ensure_ledger; fi
    check_entry
    if [ "$CONSUME" = 1 ]; then
      update_row "$GID" ACKED CONSUMED - "$(now_iso)" "consumed by check: $(clean "$C_SERVICE/$C_ACTION/$C_ARTIFACT")"
      echo "GO $GID OK and CONSUMED: service=$C_SERVICE action=$C_ACTION artifact=$C_ARTIFACT (to $R_TO)"
    else
      echo "GO $GID OK: service=$C_SERVICE action=$C_ACTION artifact=$C_ARTIFACT (to $R_TO)"
    fi
    ;;
  show)
    [ $# -ge 1 ] || die "usage: go-ledger.sh show <go-id>"
    load_row "$1" || die "unknown GO id: $1"
    EXP=-; [ "$R_EXPIRES" = "-" ] || EXP="$(iso_of "$R_EXPIRES") ($R_EXPIRES)"
    printf 'id: %s\nto: %s\nstatus: %s\nkind: %s\nservice: %s\naction: %s\nartifact: %s\nexpires: %s\nsent: %s\nacked/done: %s\nclosed: %s\nnote: %s\nsummary: %s\nformat: %s\n' \
      "$R_ID" "$R_TO" "$R_STATUS" "$R_KIND" "$R_SERVICE" "$R_ACTION" "$R_ARTIFACT" "$EXP" "$R_SENT" "$R_DONE" "$R_CLOSED" "$R_NOTE" "$R_SUM" "$R_FORMAT"
    ;;
  pending)
    OLDER=0; RENAG=0; older_than_arg "$@"
    ledger_cat | awk -F'\t' -v now="$(now_epoch)" -v min="$OLDER" \
      'NR>1 && $3=="PENDING" && (now-$5) >= min*60 {
         printf "PENDING %s to=%s age=%dm sent=%s: %s\n", $1, $2, int((now-$5)/60), $4, $8 }'
    ;;
  stale)
    OLDER=${COORD_STALE_MIN:-10}; RENAG=${COORD_RENAG_MIN:-30}; older_than_arg "$@"
    lock; ensure_ledger
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
    if [ "${1:-}" = --typed ]; then
      shift
      N=${1:-20}; [[ $N =~ $NUM_RE ]] || die "usage: go-ledger.sh list --typed [N]  (N must be a number, got '$N')"
      ledger_cat | awk -F'\t' -v OFS='\t' -v un="$UNSPEC" -v m="$N" '
        NR==1 { print "id", "to", "status", "kind", "service", "action", "artifact", "expires_epoch", "sent_utc", "summary"; next }
        { k = $9; if (k == "") { u = toupper($1); k = (u ~ /^HOLD([-_.:\/#]|$)/) ? "HOLD" : "GO" }
          s = ($10 == "" ? un : $10); a = ($11 == "" ? un : $11); x = ($12 == "" ? un : $12); e = ($13 == "" ? "-" : $13)
          rows[++n] = $1 OFS $2 OFS $3 OFS k OFS s OFS a OFS x OFS e OFS $4 OFS $8 }
        END { for (i = (n > m + 0 ? n - m + 1 : 1); i <= n; i++) print rows[i] }' | column -t -s $'\t'
    elif [ -s "$LEDGER" ]; then
      # header read straight from the file (a `cat | head -1` dies of SIGPIPE
      # under pipefail on a big ledger)
      { head -1 "$LEDGER" | cut -f1-8; tail -n +2 "$LEDGER" | tail -n "${1:-20}" | cut -f1-8; } | column -t -s $'\t'
    else
      printf '%s\n' "$HEADER" | cut -f1-8 | column -t -s $'\t'
    fi
    ;;
  scan)
    SRC=${1:--}
    BODY=$(cat -- "$SRC" 2>/dev/null) || exit 0
    IDS=$(printf '%s\n' "$BODY" | grep -oE '(^|[^A-Za-z])ACK[: ]+[A-Za-z0-9._#:/-]+' \
          | sed -E 's|^[^A]*ACK[: ]+||; s|[.:,;#/-]+$||' | sort -u) || true
    [ -n "$IDS" ] || exit 0
    lock; ensure_ledger
    # shellcheck disable=SC2086  # one id per word, ids never contain spaces
    for GID in $IDS; do do_ack "$GID" quiet; done
    ;;
  ""|-h|--help|help)
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
    ;;
  *) die "unknown command: $CMD (try --help)";;
esac
