#!/bin/bash
# Claude Code PreToolUse hook for Bash: refuse a few commands that broke hard
# rules before. Reads the hook JSON on stdin; exit 2 (reason on stderr, which
# Claude sees) to deny, exit 0 to allow.
#
# THREAT MODEL: this is a tripwire for HONEST agent mistakes, not a sandbox
# against an adversarial agent. Every plausible accident path should trip it
# (wrappers, pipes into a shell, loops, remote shells, flag spellings). For
# deliberate obfuscation there is exactly one catch-all row (obfuscated): when
# a command hides what it runs (eval, a substituted command word or sh -c
# payload, $( ) inside $(( )) or ${ }), the text of THAT expression (its $( )
# re-inlined; never sibling commands or comments) is searched for the dangerous
# verbs. Anyone determined to get past a regex hook can; the real
# controls are the GO ledger, a burst runner that only accepts preview URLs,
# and deploy wrappers.
#
# The rule table and all matching live in hooks/guard_parse.py (one python
# process, compiled regexes, a 6 s budget: past it the answer is GUARD NOT
# APPLIED, never a silent hook timeout). This script is the thin wrapper.
#
# Project specifics come from coordinator.conf ($GUARD_CONF, else the
# coordinator.conf one folder up from hooks/; see coordinator.conf.example):
# GUARD_LIVE_HOSTS (hosts that must never be burst or crawled) and the
# GUARD_SECRET_* patterns (commands whose output can hold secrets). Nothing
# project-specific is hard-coded; with no config those rows never match.
#
# How it decides: hooks/guard_parse.py (python3, stdlib only) splits the
# command into simple commands (on ; && || | & newlines), strips wrappers
# (sudo, doas, env, VAR=x, nohup, time, timeout/gtimeout, nice, arch, xargs ...)
# and treats as DATA what the shell never executes: quoted heredoc bodies fed
# to cat/tee/etc., quoted arguments, comments. It parses as CODE what does
# execute: $( ), backticks, bash/sh/zsh -c '...', eval, su -c, find -exec, and
# anything a shell reads as a script: a heredoc or here-string attached to
# bash/sh/zsh/sudo -s/su, a literal (echo, printf, cat <<EOF, a { } or ( )
# group, passed through tee or cat) piped into bash/sh/zsh/source/.,
# bash -s / sh -s (with or without $1 $2 ...), bash /dev/stdin, bash <(...),
# source <(...). The remote command of ssh / gcloud compute ssh /
# docker|kubectl exec gets context "remote". Each row is then checked per
# command, so a harmless fragment can't exempt a dangerous one.
#
# Rows (defined in guard_parse.py RULES_SRC; name: what is denied):
#   kill-pattern    pkill / killall (any wrapper), fuser -k, find -exec pkill,
#                   and kill together with lsof -t / pgrep / pidof / ps in one
#                   call ($( ), pipes, loops)
#   remote-argv     REMOTE context only: ps that prints arguments (aux, axww,
#                   -ef, -Af, -eF, -o args|command|cmd), pgrep -a / -fl, top -c,
#                   /proc/*/cmdline|environ
#   secret-describe GUARD_SECRET_DESCRIBE_RE unless EVERY --format is a safe
#                   field list (CLIs honour the last --format)
#   secret-fields   GUARD_SECRET_CLI_RE naming a GUARD_SECRET_FIELDS_RE field
#   secret-debug    debug / HTTP-log flags on GUARD_SECRET_CLI_RE, and curl/wget
#                   -v / --trace to GUARD_SECRET_API_HOST_RE (they dump the
#                   full response); never literal text in git, grep or echo
#   secret-rest     curl/wget to GUARD_SECRET_REST_RE
#   live-burst      a fetch of a GUARD_LIVE_HOSTS host plus a load marker:
#                   xargs -P, hey/oha/k6/wrk/ab/siege/vegeta/autocannon/
#                   bombardier/parallel, curl -Z / --parallel, a curl URL glob
#                   ([1-40], {a,b}), the fetch run with &, wget -r / -m /
#                   --mirror, lychee / muffet / httrack / linkchecker;
#                   and any crawl: the call names a live host and curl/wget
#                   runs in a loop body or under xargs. Allowed: a polling loop
#                   (while/until, not while-read) with ONE fetch per iteration
#                   and a FOREGROUND sleep of at least 5 s on every iteration
#                   path (not after && / ||, not inside an if, not with &).
#   watcher-bg      inbox-watch.sh started with & (use run_in_background)
#   coord-expand    a coordinator script whose MESSAGE holds a $( ) or backtick
#                   the shell would run (a substitution in a flag value such as
#                   --artifact "$(git rev-parse HEAD)" is fine)
#   env-clobber     gcloud [flags] run ... --set-env-vars / --set-secrets /
#                   --clear-env-vars / --clear-secrets / --env-vars-file, and
#                   gcloud run services|jobs replace
#   obfuscated      catch-all (see THREAT MODEL)
#
# Fail-open by design: if python3 or guard_parse.py is missing, the config has
# a bad regex, or the input can't be parsed, the command is ALLOWED with a loud
# "GUARD NOT APPLIED" warning (exit 1, a non-blocking hook error), so a broken
# guard can't stop every session at once. This script uses no heredocs or temp
# files (a read-only sandbox can't break it silently). Check it with:
#   hooks/guard.sh --selftest      (asserts the exact number of cases ran, on a
#                                   built-in example config, then prints what
#                                   the project's own config turns on)
#
# Scope: Claude Code sessions only. Codex sessions never run this hook; for them
# the quoted-heredoc rule in AGENT-COORDINATION.md is the only protection.
#
# Install (see references/guard-hook.md), while no go-ledger.sh is running:
#   C=/path/to/.coordinator
#   test ! -e $C/mail/.go-ledger.lock \
#     || { echo "a ledger lock exists: wait for it, or remove it by hand if no go-ledger runs"; false; }
#   (go-ledger.sh never breaks an ownerless lock, and a pre-0.9 script's lock
#    has no owner file; a stale one would stall every writer)
#   cp ~/.claude/settings.json ~/.claude/settings.json.bak-$(date +%Y%m%d%H%M%S)
#   jq --slurpfile s $C/hooks/settings-snippet.json --arg cmd "$C/hooks/guard.sh" \
#     '.hooks.PreToolUse += ($s[0].hooks.PreToolUse | map(.hooks[0].command = $cmd))' \
#     ~/.claude/settings.json > ~/.claude/settings.json.new \
#     && mv ~/.claude/settings.json.new ~/.claude/settings.json
#   $C/hooks/guard.sh --selftest
# APPEND to the existing PreToolUse array (.hooks.PreToolUse += $s[0].hooks.PreToolUse),
# never replace it: other tools keep their own hooks there.
# Debug one command (add --parse to see the commands the parser found):
#   jq -n --arg c 'pkill -f x' '{tool_name:"Bash",tool_input:{command:$c}}' | hooks/guard.sh [--parse]
set -u
SELF="$0"
HOOKDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PARSER="$HOOKDIR/guard_parse.py"

loud() {
  {
    echo "guard.sh: ################ GUARD NOT APPLIED ################"
    echo "guard.sh: $*"
    echo "guard.sh: This command was ALLOWED without the safety rows (fail-open by design)."
    echo "guard.sh: Check the guard with: $SELF --selftest"
  } >&2
}

# ---- selftest ---------------------------------------------------------------
# "expect@@row@@command"   (⏎ stands for a newline). EXPECTED_CASES must equal
# the number of entries; the selftest fails if the count differs or is 0.
SELFTEST_CASES=(
  "deny@@kill-pattern@@pkill -f node"
  "deny@@kill-pattern@@sudo -n pkill -f java"
  "deny@@kill-pattern@@kill \$(pgrep -f node)"
  "deny@@kill-pattern@@for p in \$(lsof -ti:3000); do kill \$p; done"
  "deny@@kill-pattern@@cat <<'EOF' | bash⏎pkill -f x⏎EOF"
  "deny@@kill-pattern@@printf 'pkill -f x\\n' | sh"
  "deny@@kill-pattern@@find . -name x -exec pkill -f {} \\;"
  "allow@@kill-pattern@@lsof -nP -iTCP:3000 -sTCP:LISTEN"
  "allow@@kill-pattern@@grep -rn \"pkill -f\" notes.md"
  "allow@@kill-pattern@@cat > notes.md <<'EOF'⏎pkill -f java is banned⏎EOF"
  "deny@@remote-argv@@ssh host ps axww"
  "deny@@remote-argv@@docker exec web ps aux"
  "allow@@remote-argv@@ps aux | grep node"
  "allow@@remote-argv@@ssh host 'ps -o pid,comm'"
  "deny@@secret-describe@@idpctl config describe --format=json; printf '%s' \"--format=value(name)\""
  "deny@@secret-describe@@idpctl config describe --format='value(name)' --format=json"
  "deny@@secret-fields@@idpctl config describe --format='value(signIn)'"
  "deny@@secret-debug@@idpctl config describe --format='value(name)' --log-http"
  "deny@@secret-rest@@curl -s https://idp.example.com/admin/v2/projects/p/config"
  "allow@@secret-describe@@idpctl config describe --format='value(authorizedDomains)'"
  "deny@@live-burst@@curl -Z https://app.example.com/[1-40]"
  "deny@@live-burst@@seq 1 50 | xargs -P 20 -I{} curl -s https://app.example.com/"
  "deny@@live-burst@@curl -s https://app.example.com/sitemap.xml | grep -o '<loc>[^<]*' | sed 's/<loc>//' | while read u; do curl -s -o /dev/null \"\$u\"; done"
  "deny@@live-burst@@while true; do curl -s https://app.example.com/healthz; done"
  "allow@@live-burst@@while true; do curl -s https://app.example.com/healthz; sleep 30; done"
  "allow@@live-burst@@curl -s https://app.example.com/"
  "deny@@coord-expand@@coordinator-reply.sh 1 \"see \`date\`\""
  "allow@@coord-expand@@coordinator-reply.sh --go GO-x --artifact \"\$(git rev-parse HEAD)\" --no-push 1 \"GO for this head\""
  "allow@@coord-expand@@coordinator-reply.sh 1 - <<'EOF'⏎literal \`date\` and \$(id)⏎EOF"
  "deny@@env-clobber@@gcloud --project p run services update s --clear-env-vars"
  "deny@@env-clobber@@gcloud run services replace svc.yaml"
  "allow@@env-clobber@@gcloud run services update s --update-env-vars A=1"
  "deny@@obfuscated@@eval \"\$(echo pkill -f x)\""
  "deny@@obfuscated@@\$(printf pkill) -f x"
  "deny@@kill-pattern@@echo \${x:=\$(pkill -f x)}"
  "deny@@live-burst@@while true; do curl -sf https://app.example.com/healthz; (sleep 30) & done"
  "allow@@kill-pattern@@grep -F pkill <<< 'Never run \$(pkill -f node)'"
  "deny@@kill-pattern@@kill \$(lsof -nP -iTCP:3000 -sTCP:LISTEN | awk 'NR>1{print \$2}')"
  "deny@@watcher-bg@@.coordinator/inbox-watch.sh &"
)
EXPECTED_CASES=39

selftest() {
  local pass=0 fail=0 ran=0 line want rowname cmd out rc
  [ -r "$PARSER" ] || { echo "selftest: FAIL parser $PARSER missing; the guard is NOT active" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "selftest: FAIL python3 not found; the guard is NOT active" >&2; return 1; }
  for line in "${SELFTEST_CASES[@]}"; do
    ran=$((ran + 1))
    want=${line%%@@*}; line=${line#*@@}; rowname=${line%%@@*}; cmd=${line#*@@}
    out=$(python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1].replace("⏎","\n")}}))' "$cmd" | "$SELF" --selftest-config 2>&1); rc=$?
    if { [ "$want" = deny ] && [ "$rc" = 2 ] && case "$out" in *"($rowname)"*) true;; *) false;; esac; } \
       || { [ "$want" = allow ] && [ "$rc" = 0 ]; }; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); echo "selftest: FAIL want $want ($rowname), got rc $rc: $cmd :: $out" >&2
    fi
  done
  if [ "$ran" -ne "$EXPECTED_CASES" ] || [ "$ran" -eq 0 ]; then
    echo "selftest: FAIL ran $ran cases, expected $EXPECTED_CASES; the case table did not load" >&2
    fail=$((fail + 1))
  fi
  echo "guard selftest: $pass passed, $fail failed ($ran of $EXPECTED_CASES cases ran)"
  # the cases above run on a built-in example config; now the project's own
  local sum; sum=$(python3 -I "$PARSER" --config-summary </dev/null 2>/dev/null)
  case "$sum" in
    *@@ok) printf '%s\n' "${sum%$'\n'@@ok}";;
    *) echo "selftest: FAIL project config: ${sum##*@@err }; the guard is NOT applied" >&2; fail=$((fail + 1));;
  esac
  [ "$fail" = 0 ]
}
if [ "${1:-}" = --selftest ]; then selftest; exit $?; fi

# ---- evaluate ---------------------------------------------------------------
# One python process parses the command AND evaluates every row (compiled
# regexes): ~0.1 s for thousands of commands. No here-strings, heredocs or temp
# files anywhere in this script, so an unwritable TMPDIR can't break it.
if ! command -v python3 >/dev/null 2>&1; then cat >/dev/null; loud "python3 not found"; exit 1; fi
if [ ! -r "$PARSER" ]; then cat >/dev/null; loud "parser $PARSER missing or unreadable"; exit 1; fi
if [ "${1:-}" = --parse ]; then                     # debug: one line per command
  RES=$(python3 -I "$PARSER" --parse 2>/dev/null); rc=$?
  case "$RES" in *@@ok) printf '%s\n' "${RES%@@ok}"; exit 0;; esac
  loud "could not parse (${RES##*@@err })"; exit 1
fi
MODE=(); [ "${1:-}" = --selftest-config ] && MODE=(--selftest-config)   # selftest only: built-in example config
RES=$(python3 -I "$PARSER" ${MODE[@]+"${MODE[@]}"} 2>/dev/null); rc=$?
case "$RES" in
  "@@allow")
    exit 0;;
  "@@deny"$'\t'*)
    rest=${RES#@@deny$'\t'}; row=${rest%%$'\t'*}; msg=${rest#*$'\t'}
    echo "guard.sh BLOCKED ($row): $msg" >&2
    exit 2;;
  *)
    case "$RES" in *@@err*) why=${RES##*@@err };; *) why="parser exit $rc, unexpected output";; esac
    loud "could not evaluate the command ($why)"
    exit 1;;
esac
