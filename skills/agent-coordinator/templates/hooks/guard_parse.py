#!/usr/bin/env python3
"""Shell-command parser for guard.sh (stdlib only, run with python3 -I).

Reads the Claude Code PreToolUse hook JSON on stdin, parses the command and
evaluates the rule table (below), all inside one python process with compiled
regexes (round 4: the bash per-command loop was too slow). Output, one line:
    @@deny<TAB><row><TAB><message> | @@allow | @@err <why> (exit 3)
Evaluation has a time budget (6 s, GUARD_BUDGET_SEC may only lower it); past
it the answer is @@err, which guard.sh turns into GUARD NOT APPLIED instead of
a silent hook timeout.
With --parse it prints instead one TSV line per simple command, then @@ok:

    ctx  bg  subst  fmt  iter  eff  full

  ctx    local | remote (inside ssh / gcloud compute ssh / docker|kubectl exec)
         | obf (one line per OBSCURED expression only: an eval or substituted
         command word / sh -c payload with its $( ) re-inlined, or the raw
         $(( )) / ${ } text holding a $( ); never sibling commands or comments)
  bg     1 if run in the background (&)
  subst  1 if it holds a $( ) / backtick the shell will run; for the coordinator
         scripts only substitutions in the MESSAGE count (flag values are fine)
  fmt    none | unsafe | ok: ok when every --format is a safe field list
         (GUARD_SAFE_FORMAT_RE, default value(...) / yaml(...))
  iter   "<tags> <eff>": L = inside a loop body that is not an allowed polling
         loop, X = run by xargs, - = neither
  eff    the command after wrappers (sudo, env, VAR=x, nohup, timeout ...),
         command name basename'd
  full   the command as typed (words joined)

On any failure the output is "@@err <why>" and the exit code is 3.

Threat model: a tripwire for honest agent mistakes, not a sandbox against a
deliberately adversarial agent (see guard.sh).

Project specifics (live hosts, secret-bearing commands) come from
coordinator.conf: $GUARD_CONF, else ../coordinator.conf next to this hooks/
folder. It is read as KEY='value' lines, never executed. Rows whose setting is
empty never match. --selftest-config swaps in a fixed example config (used by
guard.sh --selftest, so the selftest checks the mechanism whatever the project
config says); --config-summary prints what the active config turns on.
"""
import json
import os
import re
import signal
import sys

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SOURCES = {"source", "."}
FETCHERS = {"curl", "wget", "http", "https", "xh"}
LEAD_DROP = {"then", "do", "else", "elif", "if", "while", "until", "!", "{", "(", "time"}
ALONE_DROP = {"done", "fi", "esac", "}", ")", ";;", "in"}
LOOP_WORDS = {"while", "until", "for", "select"}
STDIN_PATHS = {"/dev/stdin", "-", "/dev/fd/0"}
SUB = "$(...)"
PSUB = "<(...)"
COORD = {"coordinator-reply.sh", "ask-coordinator.sh", "cmux-say.sh", "cmux-deliver.sh"}

STATE = {"obf_texts": [], "loops": {}, "next_loop": 0}

NEVER = r"(?!)"                    # a regex that matches nothing: an unconfigured row
SELFTEST_CONF = {
    "GUARD_LIVE_HOSTS": "app.example.com www.example.com",
    "GUARD_SECRET_CLI_RE": r"^idpctl( |$)",
    "GUARD_SECRET_DESCRIBE_RE": r"^idpctl( .*)? config( .*)? describe( |$)",
    "GUARD_SECRET_FIELDS_RE": r"([sS]ign_?[iI]n|[hH]ash_?[cC]onfig|[sS]igner_?[kK]ey|[sS]alt_?[sS]eparator)",
    "GUARD_SECRET_API_HOST_RE": r"idp\.example\.com",
    "GUARD_SECRET_REST_RE": r"idp\.example\.com/[^ ]*[cC]onfig",
}


def conf_path():
    p = os.environ.get("GUARD_CONF")
    if p:
        return p
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "coordinator.conf")


def load_conf(path):
    """KEY='value' lines (last one wins, one layer of quotes removed). Never
    executed. A missing file is an empty config."""
    conf = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return conf, False
    for line in lines:
        m = re.match(r"^\s*([A-Z_][A-Z0-9_]*)=(.*)$", line)
        if not m:
            continue
        v = m.group(2).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        conf[m.group(1)] = v
    return conf, True


SELFTEST = "--selftest-config" in sys.argv[1:]
CONF, CONF_FOUND = (SELFTEST_CONF, True) if SELFTEST else load_conf(conf_path())
LIVE_HOSTS = CONF.get("GUARD_LIVE_HOSTS", "").replace(",", " ").split()
HOSTS = "(" + "|".join(re.escape(h) for h in LIVE_HOSTS) + ")" if LIVE_HOSTS else NEVER
HOSTS_SHOWN = ", ".join(LIVE_HOSTS) if LIVE_HOSTS else "none configured"


def conf_re(key, default=""):
    v = CONF.get(key, default)
    return v if v else NEVER


SECRET_CLI = conf_re("GUARD_SECRET_CLI_RE")
SECRET_DESCRIBE = conf_re("GUARD_SECRET_DESCRIBE_RE")
SECRET_FIELDS = conf_re("GUARD_SECRET_FIELDS_RE")
SECRET_API_HOST = conf_re("GUARD_SECRET_API_HOST_RE")
SECRET_REST = conf_re("GUARD_SECRET_REST_RE")
SECRET_DEBUG = conf_re("GUARD_SECRET_DEBUG_RE", r"(--log-http|--verbosity[= ]debug|--debug)")
SAFE_FORMAT_SRC = conf_re("GUARD_SAFE_FORMAT_RE", r"(value|yaml)\([^)]+\)")


class Rec:
    def __init__(self, ctx, loop_id=None):
        self.ctx = ctx
        self.words, self.wsubst = [], []
        self.subst, self.bg = False, False
        self.loop_id = loop_id
        self.codes, self.procsubs = [], []
        self.bodies = []          # (text, quoted) heredocs / here-strings on stdin
        self.pipe_from = None     # the command whose stdout feeds this one
        self.subs = []            # code of each $( ) placeholder, in order (to rebuild the text)
        self.group = None         # for a closing } or ): the commands inside the group
        self.cond_prev = False    # runs only after && / || (conditional)
        self.ifdepth = 0          # if/case nesting on this level


def find_close(s, i):
    """s[i:] follows '$(' ; index of the matching ')'."""
    depth, n = 1, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                if s[i] == "\\":
                    i += 1
                elif s.startswith("$(", i):
                    i = find_close(s, i + 2)
                i += 1
            i += 1
            continue
        if c == "`":
            i = backtick_end(s, i + 1) + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def backtick_end(s, i):
    while i < len(s) and s[i] != "`":
        i += 2 if s[i] == "\\" else 1
    return i


def extract_substs(text):
    """$( ) and backtick code inside text the shell expands."""
    codes, i, n = [], 0, len(text)
    while i < n:
        if text[i] == "\\":
            i += 2
            continue
        if text.startswith("$((", i):
            j = find_close(text, i + 2)
            codes += extract_substs(text[i + 3:j])
            i = j + 1
            continue
        if text.startswith("$(", i):
            j = find_close(text, i + 2)
            codes.append(text[i + 2:j])
            i = j + 1
            continue
        if text[i] == "`":
            j = backtick_end(text, i + 1)
            codes.append(text[i + 1:j].replace("\\`", "`"))
            i = j + 1
            continue
        i += 1
    return codes


def expansion(raw, rec):
    """$(( )) / ${ } copied raw: any $( ) or backtick inside runs, so parse
    it as code, and flag the command as obfuscated for the catch-all row."""
    inner = extract_substs(raw[2:])
    if inner:
        STATE["obf_texts"].append((rec.ctx, raw))   # the obscured expression itself
        rec.codes += inner
        rec.subst = True
    return raw


def parse(src, ctx, inloop=None):
    """Split src into simple commands (Rec), without analysing them."""
    recs, cur = [], Rec(ctx, inloop)
    loops = []                 # open loop ids on this level
    pending = []               # heredocs waiting for the end of the line
    pipe_next = [False]
    groups = []                # indexes where an open { or ( group starts
    gcond = []                 # was that group entered behind && / || ?
    lvl = {"if": 0}
    n = len(src)
    i = 0

    def end_cmd(cond=None):
        """Close the current command. cond: True after && / ||, False after
        ; & newline, None (keep the pipeline's) after |."""
        nonlocal cur
        if cur.words or cur.codes or cur.bodies:
            w0 = cur.words[0] if cur.words else ""
            if w0 in ("fi", "esac"):
                lvl["if"] = max(0, lvl["if"] - 1)
            cur.ifdepth = lvl["if"]
            if w0 in ("if", "case"):
                lvl["if"] += 1
            if w0 in LOOP_WORDS:
                lid = STATE["next_loop"]
                STATE["next_loop"] += 1
                STATE["loops"][lid] = {"kind": w0, "header": cur, "ifdepth": cur.ifdepth}
                loops.append(lid)
            cur.loop_id = loops[-1] if loops else inloop
            if w0 == "done" and loops:
                loops.pop()
            if any(gcond):
                cur.cond_prev = True     # inside a group entered behind && / ||
            if w0 == "{":
                groups.append(len(recs))
                gcond.append(cur.cond_prev)
            if w0 == "}" and groups:
                cur.group = recs[groups.pop():]
                gcond.pop()
            if pipe_next[0] and recs:
                cur.pipe_from = recs[-1]
            recs.append(cur)
        empty = not (cur.words or cur.codes or cur.bodies)
        carried = cur.cond_prev
        prev = recs[-1] if recs else None
        pipe_next[0] = False
        cur = Rec(ctx, inloop)
        if cond is None and empty:
            cur.cond_prev = carried      # nothing closed (e.g. `&& (`): keep the pending condition
        else:
            cur.cond_prev = (prev.cond_prev if (cond is None and prev is not None) else bool(cond))

    def read_word(i, rec):
        buf, before = [], len(rec.codes)
        while i < n:
            c = src[i]
            if c in " \t\n;&|()<>":
                break
            if c == "\\":
                if i + 1 < n and src[i + 1] == "\n":
                    i += 2
                    continue
                buf.append(src[i + 1:i + 2])
                i += 2
                continue
            if c == "'":
                j = src.find("'", i + 1)
                j = n if j < 0 else j
                buf.append(src[i + 1:j])
                i = j + 1
                continue
            if src.startswith("$'", i):
                j = i + 2
                while j < n and src[j] != "'":
                    j += 2 if src[j] == "\\" else 1
                buf.append(src[i + 2:j])
                i = j + 1
                continue
            if c == '"':
                i += 1
                while i < n and src[i] != '"':
                    if src[i] == "\\" and i + 1 < n:
                        buf.append(src[i + 1])
                        i += 2
                        continue
                    if src.startswith("$((", i):
                        j = find_close(src, i + 2)
                        buf.append(expansion(src[i:j + 1], rec))
                        i = j + 1
                        continue
                    if src.startswith("$(", i):
                        j = find_close(src, i + 2)
                        rec.codes.append(src[i + 2:j])
                        rec.subs.append(src[i + 2:j])
                        rec.subst = True
                        buf.append(SUB)
                        i = j + 1
                        continue
                    if src[i] == "`":
                        j = backtick_end(src, i + 1)
                        rec.codes.append(src[i + 1:j].replace("\\`", "`"))
                        rec.subs.append(rec.codes[-1])
                        rec.subst = True
                        buf.append(SUB)
                        i = j + 1
                        continue
                    if src.startswith("${", i):
                        j = src.find("}", i)
                        j = n if j < 0 else j
                        buf.append(expansion(src[i:j + 1], rec))
                        i = j + 1
                        continue
                    buf.append(src[i])
                    i += 1
                i += 1
                continue
            if src.startswith("$((", i):
                j = find_close(src, i + 2)
                buf.append(expansion(src[i:j + 1], rec))
                i = j + 1
                continue
            if src.startswith("$(", i):
                j = find_close(src, i + 2)
                rec.codes.append(src[i + 2:j])
                rec.subs.append(src[i + 2:j])
                rec.subst = True
                buf.append(SUB)
                i = j + 1
                continue
            if c == "`":
                j = backtick_end(src, i + 1)
                rec.codes.append(src[i + 1:j].replace("\\`", "`"))
                rec.subs.append(rec.codes[-1])
                rec.subst = True
                buf.append(SUB)
                i = j + 1
                continue
            if src.startswith("${", i):
                j = src.find("}", i)
                j = n if j < 0 else j
                buf.append(expansion(src[i:j + 1], rec))
                i = j + 1
                continue
            buf.append(c)
            i += 1
        return "".join(buf), i, len(rec.codes) > before

    while i < n:
        c = src[i]
        if c in " \t":
            i += 1
            continue
        if c == "#" and (i == 0 or src[i - 1] in " \t\n;&|()"):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "\n":
            end_cmd(False)
            i += 1
            for rec, delim, quoted, strip in pending:
                body = []
                while i < n:
                    j = src.find("\n", i)
                    line = src[i:] if j < 0 else src[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
                    body.append(line)
                text = "\n".join(body)
                rec.bodies.append((text, quoted))
                if not quoted and extract_substs(text):
                    rec.subst = True
            pending = []
            continue
        if src.startswith("&&", i) or src.startswith("||", i):
            end_cmd(True)
            i += 2
            continue
        if c == "&" and not src.startswith("&>", i):
            end_cmd(False)
            # background the last pipeline
            k = len(recs) - 1
            while k >= 0:
                mark_bg(recs[k])
                if recs[k].pipe_from is None:
                    break
                k -= 1
            i += 1
            continue
        if c == ";":
            end_cmd(False)
            i += 2 if src.startswith(";;", i) else 1
            continue
        if c == "|":
            end_cmd(None)
            pipe_next[0] = True
            i += 2 if src.startswith("|&", i) else 1
            continue
        if c == "(":
            keep = pipe_next[0]
            end_cmd(None)
            pipe_next[0] = keep
            groups.append(len(recs))
            gcond.append(cur.cond_prev)
            i += 1
            continue
        if c == ")":
            end_cmd(None)
            if groups:
                g = Rec(ctx, inloop)
                g.words = [")"]
                g.group = recs[groups.pop():]
                g.cond_prev = gcond.pop()
                recs.append(g)           # so `( ... ) | bash` pipes the group's output
            i += 1
            continue
        if c in "<>" and i + 1 < n and src[i + 1] == "(":
            j = find_close(src, i + 2)
            code = src[i + 2:j]
            cur.codes.append(code)
            cur.procsubs.append(code)
            cur.subst = True
            cur.words.append(PSUB)
            cur.wsubst.append(True)
            i = j + 1
            continue
        m = re.match(r"\d*(<<<|<<-|<<|&>>|&>|>>|>&|<&|<>|>\||>|<)", src[i:])
        if m and (not m.group(0)[0].isdigit() or src[i - 1:i] in ("", " ", "\t", "\n", ";", "&", "|", "(")):
            op = m.group(1)
            i += len(m.group(0))
            while i < n and src[i] in " \t":
                i += 1
            if op in ("<<", "<<-"):
                j, raw = i, []
                while j < n and src[j] not in " \t\n;&|<>()":
                    raw.append(src[j])
                    j += 1
                raw = "".join(raw)
                delim = re.sub(r"[\"'\\]", "", raw)
                pending.append((cur, delim, raw != delim, op == "<<-"))
                i = j
                continue
            text, i, _ = read_word(i, cur)
            if op == "<<<":
                # read_word already parsed the substitutions the shell really
                # expands in this word; the text itself is literal from here on
                # ('Never run $(pkill -f node)' stays text)
                cur.bodies.append((text, True))
            continue
        text, i2, had = read_word(i, cur)
        if i2 == i:
            i += 1
            continue
        i = i2
        cur.words.append(text)
        cur.wsubst.append(had)
    end_cmd()
    return recs


def mark_bg(r):
    """`&` backgrounds the whole command, including everything in a { } or ( )
    group it closes: `(sleep 30) &` paces nothing."""
    r.bg = True
    for g in (r.group or []):
        mark_bg(g)


def scan(src, ctx, depth, out, inloop=None):
    if depth > 8:
        STATE["obf_texts"].append((ctx, src))       # nested too deep to follow: catch-all
        return
    for rec in parse(src, ctx, inloop):
        analyze(rec, depth, out)


def skip_opts(a, short_arg="", long_arg=(), assign=False):
    i = 0
    while i < len(a):
        t = a[i]
        if t == "--":
            return a[i + 1:]
        if assign and ASSIGN.match(t):
            i += 1
            continue
        if t.startswith("--"):
            i += 2 if ("=" not in t and t in long_arg) else 1
            continue
        if t.startswith("-") and len(t) > 1:
            nxt = False
            for k in range(1, len(t)):
                if t[k] in short_arg:
                    nxt = (k == len(t) - 1)
                    break
            i += 2 if nxt else 1
            continue
        break
    return a[i:]


def strip_wrappers(w, via):
    while w:
        if ASSIGN.match(w[0]):
            w = w[1:]
            continue
        if w[0] in LEAD_DROP:
            w = w[1:]
            continue
        name = os.path.basename(w[0])
        if name in ("sudo", "doas"):
            opts = []
            rest = w[1:]
            while rest and rest[0].startswith("-") and rest[0] != "--":
                opts.append(rest[0])
                rest = rest[1:] if not any(ch in "ugCDhprtTU" for ch in rest[0][-1:]) else rest[2:]
            if rest and rest[0] == "--":
                rest = rest[1:]
            if not rest and any(("s" in o[1:] or "i" in o[1:]) for o in opts if not o.startswith("--")):
                via.add("stdin-shell")   # sudo -s / sudo -i with no command: stdin is a shell
            w = rest
            continue
        if name == "env":
            w = skip_opts(w[1:], "uCPS", ("--unset", "--chdir", "--split-string"), assign=True)
            continue
        if name in ("nohup", "builtin", "setsid", "chronic", "unbuffer"):
            w = w[1:]
            continue
        if name == "exec":
            w = skip_opts(w[1:], "a")
            continue
        if name == "command":
            if len(w) > 1 and w[1] in ("-v", "-V"):
                return []
            w = skip_opts(w[1:])
            continue
        if name == "time":
            w = skip_opts(w[1:], "fo")
            continue
        if name == "nice":
            w = skip_opts(w[1:], "n")
            continue
        if name == "ionice":
            w = skip_opts(w[1:], "cnp")
            continue
        if name == "stdbuf":
            w = skip_opts(w[1:], "ioe")
            continue
        if name == "caffeinate":
            w = skip_opts(w[1:], "tw")
            continue
        if name == "arch":
            a = w[1:]
            while a and a[0].startswith("-"):
                a = a[2:] if a[0] == "-e" else a[1:]
            w = a
            continue
        if name in ("timeout", "gtimeout"):
            w = skip_opts(w[1:], "sk", ("--signal", "--kill-after"))
            w = w[1:]
            continue
        if name == "xargs":
            via.add("xargs")
            w = skip_opts(w[1:], "aEeIiLlnPsd", ("--max-procs", "--max-args", "--replace", "--arg-file",
                                                 "--delimiter", "--max-chars", "--eof", "--max-lines"))
            continue
        break
    return w


def opt_value(w, flag):
    for k, t in enumerate(w):
        if t == flag and k + 1 < len(w):
            return w[k + 1]
        if t.startswith(flag + "="):
            return t[len(flag) + 1:]
    return None


def format_kind(eff):
    vals = []
    for k, t in enumerate(eff):
        if t == "--format" and k + 1 < len(eff):
            vals.append(eff[k + 1])
        elif t.startswith("--format="):
            vals.append(t[len("--format="):])
    if not vals:
        return "none"
    if all(SAFE_FORMAT.fullmatch(v) for v in vals):
        return "ok"
    return "unsafe"


def printf_text(args):
    if not args:
        return ""
    fmt, rest = args[0], list(args[1:])
    fmt = fmt.replace("\\n", "\n").replace("\\t", "\t")
    def sub(_m):
        return rest.pop(0) if rest else ""
    text = re.sub(r"%[-0-9.]*[sdbq]", sub, fmt)
    return text + ("\n" + " ".join(rest) if rest else "")


def payload_of(rec, depth=0):
    """What a command writes to stdout, when that is knowable from the text:
    echo/printf arguments, heredoc bodies, a { } or ( ) group's output, and
    whatever tee / plain cat pass through from further up the pipeline."""
    if depth > 12:
        return []
    if rec.group is not None:
        texts = []
        for r in rec.group:
            texts += payload_of(r, depth + 1)
        return texts
    texts = [t for t, _q in rec.bodies]
    via = set()
    eff = strip_wrappers(list(rec.words), via)
    if eff:
        name = os.path.basename(eff[0])
        args = eff[1:]
        if name in ("tee", "cat") and rec.pipe_from is not None:
            if name == "tee" or all(a.startswith("-") for a in args):
                texts += payload_of(rec.pipe_from, depth + 1)
        if name == "echo":
            while args and re.fullmatch(r"-[neE]+", args[0]):
                args = args[1:]
            texts.append(" ".join(args).replace("\\n", "\n"))
        elif name == "printf":
            if args and args[0] == "--":
                args = args[1:]
            texts.append(printf_text(args))
    return texts


def run_as_code(texts, ctx, depth, out, loop_id):
    for t in texts:
        if t:
            scan(t, ctx, depth + 1, out, loop_id)


def coord_message_subst(name, eff, wsubst, rec):
    """Substitutions in the message words of a coordinator script."""
    ws = wsubst[-len(eff):] if len(eff) <= len(wsubst) else [False] * len(eff)
    args = list(zip(eff[1:], ws[1:]))
    flagged = {"coordinator-reply.sh": {"--go", "--kind", "--service", "--action", "--artifact", "--expires"},
               "ask-coordinator.sh": {"--from", "--wait"}}.get(name, set())
    k, msg = 0, []
    if name in ("coordinator-reply.sh", "ask-coordinator.sh"):
        while k < len(args) and args[k][0] in flagged | {"--no-push"}:
            k += 1 if args[k][0] == "--no-push" else 2
        if name == "coordinator-reply.sh":
            k += 1                                    # the reply id
        msg = args[k:]
    elif name == "cmux-say.sh":
        msg = args[2:]
    else:  # cmux-deliver.sh
        k = 1
        if k < len(args) and re.match(r"^(surface:\d+|[0-9A-Fa-f-]{36})$", args[k][0]):
            k += 1
        msg = args[k:]
    if any(s for _w, s in msg):
        return True
    return any(not q and extract_substs(t) for t, q in rec.bodies)


def analyze(rec, depth, out):
    for code in rec.codes:
        scan(code, rec.ctx, depth + 1, out, rec.loop_id)
    words = list(rec.words)
    if words and all(w in ALONE_DROP for w in words):
        words = []
    via = set()
    eff = strip_wrappers(words, via)
    stdin_code, stdin_ctx = False, rec.ctx
    if not eff:
        if words:
            out.append(entry(rec, "-", "-", " ".join(rec.words), "0", "-", via))
        if "stdin-shell" in via:
            stdin_code = True
        if stdin_code:
            run_as_code([t for t, _q in rec.bodies], stdin_ctx, depth, out, rec.loop_id)
            if rec.pipe_from:
                run_as_code(payload_of(rec.pipe_from), stdin_ctx, depth, out, rec.loop_id)
        else:
            for text, quoted in rec.bodies:
                if not quoted:
                    run_as_code(extract_substs(text), rec.ctx, depth, out, rec.loop_id)
        return
    if eff[0].startswith(SUB) or eff[0].startswith("`"):
        obscured(rec)                                     # command word is a substitution
    name = os.path.basename(eff[0])
    subst = "1" if rec.subst else "0"
    if name in COORD:
        subst = "1" if coord_message_subst(name, eff, rec.wsubst, rec) else "0"
    fmt = format_kind(eff)
    out.append(entry(rec, name, " ".join([name] + eff[1:]), " ".join(rec.words), subst, fmt, via, [name] + eff[1:]))

    if name in SHELLS:
        found_c, found_s, code, script = False, False, None, None
        args = eff[1:]
        k = 0
        while k < len(args):
            t = args[k]
            if t.startswith("-") and t != "-" and not t.startswith("--"):
                if "c" in t[1:]:
                    found_c = True
                if "s" in t[1:]:
                    found_s = True
                if "o" in t[1:]:
                    k += 1
                k += 1
                continue
            if t == "--":
                k += 1
                if found_s:
                    break
                continue
            if t.startswith("--"):
                k += 1
                continue
            if found_c:
                code = t
            elif not found_s:
                script = t                                # -s: the rest are $1 $2 ..., stdin is the script
            break
        if code is not None:
            if SUB in code:
                obscured(rec)                             # sh -c "$(...)"
            mark = len(out)
            scan(code, rec.ctx, depth + 1, out, rec.loop_id)
            if rec.bg:                                    # `bash -c '...' &`: its commands run in the background
                for e in out[mark:]:
                    e["bg"] = "1"
        elif script is None or script in STDIN_PATHS:
            stdin_code = True
        elif script == PSUB:
            for p in rec.procsubs:
                for prec in parse(p, rec.ctx):
                    run_as_code(payload_of(prec), rec.ctx, depth, out, rec.loop_id)
    elif name in SOURCES:
        arg = eff[1] if len(eff) > 1 else None
        if arg in STDIN_PATHS:
            stdin_code = True
        elif arg == PSUB:
            for p in rec.procsubs:
                for prec in parse(p, rec.ctx):
                    run_as_code(payload_of(prec), rec.ctx, depth, out, rec.loop_id)
    elif name == "eval":
        obscured(rec)
        scan(" ".join(eff[1:]), rec.ctx, depth + 1, out, rec.loop_id)
    elif name == "su":
        c = opt_value(eff, "-c") or opt_value(eff, "--command")
        if c is not None:
            scan(c, rec.ctx, depth + 1, out, rec.loop_id)
        else:
            stdin_code = True
    elif name == "watch":
        scan(" ".join(skip_opts(eff[1:], "nd", ("--interval",))), rec.ctx, depth + 1, out, rec.loop_id)
    elif name == "find":
        k = 0
        while k < len(eff):
            if eff[k] in ("-exec", "-execdir", "-ok", "-okdir"):
                j = k + 1
                while j < len(eff) and eff[j] not in (";", "+"):
                    j += 1
                r = Rec(rec.ctx, rec.loop_id)
                r.words = eff[k + 1:j]
                r.wsubst = [False] * len(r.words)
                analyze(r, depth + 1, out)
                k = j
            k += 1
    elif name == "ssh":
        rest = skip_opts(eff[1:], "bcDEeFIiJLlmOopQRSWw")
        if rest:
            remote = rest[1:]
            if remote:
                scan(" ".join(remote), "remote", depth + 1, out, rec.loop_id)
            stdin_code, stdin_ctx = True, "remote"   # stdin feeds the remote command
    elif name == "gcloud" and "compute" in eff and "ssh" in eff[eff.index("compute"):]:
        cmd = opt_value(eff, "--command")
        if cmd is not None:
            scan(cmd, "remote", depth + 1, out, rec.loop_id)
        elif "--" in eff:
            scan(" ".join(eff[eff.index("--") + 1:]), "remote", depth + 1, out, rec.loop_id)
        stdin_code, stdin_ctx = True, "remote"
    elif name in ("docker", "podman", "kubectl", "oc"):
        a = eff[1:]
        while a and a[0] in ("compose", "container"):
            a = a[1:]
        if a and a[0] == "exec":
            a = a[1:]
            if name in ("kubectl", "oc"):
                cmdw = a[a.index("--") + 1:] if "--" in a else skip_opts(a, "cnf", ("--container", "--namespace"))[1:]
            else:
                cmdw = skip_opts(a, "euw", ("--env", "--user", "--workdir", "--env-file", "--detach-keys"))[1:]
            if cmdw:
                r = Rec("remote", rec.loop_id)
                r.words = cmdw
                r.wsubst = [False] * len(cmdw)
                r.subst = rec.subst
                analyze(r, depth + 1, out)

    if stdin_code:
        run_as_code([t for t, _q in rec.bodies], stdin_ctx, depth, out, rec.loop_id)
        if rec.pipe_from:
            run_as_code(payload_of(rec.pipe_from), stdin_ctx, depth, out, rec.loop_id)
    else:
        for text, quoted in rec.bodies:
            if not quoted:
                run_as_code(extract_substs(text), rec.ctx, depth, out, rec.loop_id)


LOOKUP = re.compile(r"(^|[^A-Za-z0-9_.-])(lsof|pgrep|pidof|ps)([^A-Za-z0-9_.-]|$)")
LIVE = re.compile(r"(^|[^A-Za-z0-9.-])" + HOSTS + r"([^A-Za-z0-9.-]|$)")


def fed_by_lookup(rec):
    """kill whose pids come from lsof/pgrep/pidof/ps: inside its own $( ),
    from further up its pipeline (... | xargs kill), or from its loop header
    (for p in $(lsof ...); do kill $p; done)."""
    if any(LOOKUP.search(c) for c in rec.subs):
        return True
    r, n = rec.pipe_from, 0
    while r is not None and n < 20:
        w = strip_wrappers(list(r.words), set())
        if (w and os.path.basename(w[0]) in ("lsof", "pgrep", "pidof", "ps")) or any(LOOKUP.search(c) for c in r.subs):
            return True
        r, n = r.pipe_from, n + 1
    info = STATE["loops"].get(rec.loop_id)
    if not info:
        return False
    h = info["header"]
    if any(LOOKUP.search(c) for c in h.subs):
        return True
    # `lsof ... | awk ... | while read -r pid; do kill "$pid"; done`
    r, n = h.pipe_from, 0
    while r is not None and n < 20:
        w = strip_wrappers(list(r.words), set())
        if (w and os.path.basename(w[0]) in ("lsof", "pgrep", "pidof", "ps")) or any(LOOKUP.search(c) for c in r.subs):
            return True
        r, n = r.pipe_from, n + 1
    return False


# options whose next word (or =value / glued value) is NOT a URL
VALUE_OPTS = {
    "curl": ("oHdeuAXwFbcTxrCmKEDYyzQt", {
        "--output", "--header", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--data-ascii",
        "--user", "--user-agent", "--referer", "--request", "--write-out", "--form", "--form-string",
        "--cookie", "--cookie-jar", "--upload-file", "--proxy", "--resolve", "--connect-to", "--max-time",
        "--connect-timeout", "--retry", "--retry-delay", "--retry-max-time", "--config", "--cacert", "--capath",
        "--cert", "--key", "--range", "--continue-at", "--dump-header", "--trace", "--trace-ascii", "--stderr",
        "--interface", "--limit-rate", "--max-filesize", "--oauth2-bearer", "--json", "--variable", "--expand-url"}),
    "wget": ("OoaPUeTtwlADIRQB", {
        "--output-document", "--output-file", "--append-output", "--directory-prefix", "--user-agent",
        "--header", "--post-data", "--post-file", "--body-data", "--body-file", "--method", "--execute",
        "--timeout", "--tries", "--wait", "--level", "--accept", "--reject", "--domains", "--include-directories",
        "--exclude-directories", "--quota", "--user", "--password", "--http-user", "--http-password",
        "--load-cookies", "--save-cookies", "--referer", "--base", "--ca-certificate", "--certificate"}),
}
URL_OPTS = {"--url"}


def url_operands(name, args):
    """The words of a curl/wget command that name a destination: operands and
    --url values; option values (-o FILE, -H HEADER, ...) are skipped."""
    short, long_ = VALUE_OPTS.get(name, ("", set()))
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            out += args[i + 1:]
            break
        if a.startswith("--"):
            key = a.split("=", 1)[0]
            if key in URL_OPTS:
                if "=" in a:
                    out.append(a.split("=", 1)[1])
                elif i + 1 < len(args):
                    out.append(args[i + 1]); i += 1
            elif "=" not in a and key in long_:
                i += 1
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            for k in range(1, len(a)):
                if a[k] in short:
                    if k == len(a) - 1:
                        i += 1             # the value is the next word
                    break                  # else the rest of this word is the value
            i += 1
            continue
        out.append(a)
        i += 1
    return out


def destination(name, args, via_xargs=False):
    """For a fetch: live (a literal URL on the live host), var (a URL whose host
    is unresolved: "$u", "$BASE/x", $( ), an xargs {} or a URL read from stdin
    by xargs), other, or - for non-fetches. Only URL operands and --url values
    count, never option values such as -o "$p.out" or -H 'Host: ...'."""
    if name not in FETCHERS:
        return "-"
    dest = "other"
    saw_url = False
    for a in url_operands(name, args):
        if not a:
            continue
        if "://" in a:
            saw_url = True
            host = a.split("://", 1)[1].split("/", 1)[0]
            if "$" in host or "{" in host:
                dest = "var" if dest != "live" else dest
            elif LIVE.search(host):
                return "live"
        elif a.startswith("$"):
            dest = "var" if dest != "live" else dest
        elif LIVE.search(a):
            return "live"
    if via_xargs and not saw_url and dest == "other":
        dest = "var"                       # xargs appends the URLs it reads from stdin
    return dest


def entry(rec, name, eff, full, subst, fmt, via, effw=None):
    args = list(effw[1:]) if effw else (eff.split(" ")[1:] if eff != "-" else [])
    info = STATE["loops"].get(rec.loop_id)
    return {"ctx": rec.ctx, "bg": "1" if rec.bg else "0", "subst": subst, "fmt": fmt,
            "loop": rec.loop_id, "xargs": "xargs" in via, "name": name, "eff": eff, "full": full,
            "args": args, "cond": rec.cond_prev, "ifdepth": rec.ifdepth,
            "header": bool(info and info["header"] is rec),
            "lookup": "1" if name == "kill" and fed_by_lookup(rec) else "0",
            "dest": destination(name, args, "xargs" in via)}


def rebuilt(rec):
    """The command's own text with each $( ) placeholder re-inlined: what an
    obscured command actually spells (comments and sibling commands excluded)."""
    subs = list(rec.subs)
    psubs = list(rec.procsubs)
    words = []
    for w in rec.words:
        while SUB in w and subs:
            w = w.replace(SUB, "$(" + subs.pop(0) + ")", 1)
        if w == PSUB and psubs:
            w = "<(" + psubs.pop(0) + ")"
        words.append(w)
    return " ".join(words)


def obscured(rec):
    STATE["obf_texts"].append((rec.ctx, rebuilt(rec)))


def sleep_seconds(args):
    total = 0.0
    for a in args:
        m = re.fullmatch(r"(\d+(?:\.\d+)?)([smhd]?)", a)
        if not m:
            return 0
        total += float(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
    return total


def polling_loops(out):
    """Loop ids that are an allowed polling loop: while/until (not while-read),
    exactly one fetch per iteration and a sleep of at least 5 s."""
    ok = set()
    for lid, info in STATE["loops"].items():
        if info["kind"] not in ("while", "until"):
            continue
        cond = [w for w in info["header"].words[1:] if w != "!"]
        if cond and os.path.basename(cond[0]) == "read":
            continue
        mine = [e for e in out if e["loop"] == lid]
        fetches = [e for e in mine if e["name"] in FETCHERS]
        # the sleep must run on EVERY iteration: foreground (also not inside a
        # backgrounded group), not after && / ||, not inside an if/case of the
        # loop body. A `continue` anywhere in the body can skip a body sleep,
        # so then only a sleep in the loop condition counts
        # only a `continue` that comes BEFORE the sleep can skip it; `sleep 30;
        # continue` paces every iteration
        cont = [k for k, e in enumerate(mine) if e["name"] == "continue"]
        first_cont = cont[0] if cont else None
        sleeps = [e for k, e in enumerate(mine) if e["name"] == "sleep" and sleep_seconds(e["args"]) >= 5
                  and e["bg"] == "0" and not e["cond"] and e["ifdepth"] == info["ifdepth"]
                  and (e["header"] or first_cont is None or k < first_cont)]
        if len(fetches) == 1 and sleeps and not any(e["xargs"] or e["bg"] == "1" for e in fetches):
            ok.add(lid)
    return ok


def flat(s):
    return s.replace("\t", " ").replace("\n", " ").replace("\r", " ")


# ---- the rule table ---------------------------------------------------------
# (name, scope, where, match_field, match, and_field, and, not_field, not, message)
#   scope cmd : MATCH, AND and NOT are tested on the SAME simple command
#   scope call: some command matches MATCH and some (maybe other) command AND
#   where any (local or remote) | remote | obf (the obscured expressions)
#   fields: eff, full, bg, subst, fmt, iter (see the module docstring)
KILL_MSG = ("No pkill / killall / fuser -k / kill-by-lookup (lsof -t, pgrep, pidof, ps): on a machine shared by "
            "several agents, a pattern or port kill takes down other agents' dev servers. Run "
            "lsof -nP -iTCP:<port> -sTCP:LISTEN, confirm the pid is one YOU started, then run kill <that pid> as its "
            "own command.")
ARGV_MSG = ("Remote process listings print full argv/env, and secrets ride in flags (a token passed on a command line "
            "showed up in ps). Over ssh/exec use ps -o pid,comm or pgrep -l (no arguments).")
SECRET_MSG = ("This command can print a secret-bearing config (GUARD_SECRET_* in coordinator.conf). Give every --format "
              "a field list that leaves out the secret fields, e.g. --format='value(name)'; no debug/HTTP-log flags "
              "(they dump the full response, as does curl -v to the API host); never the REST config endpoint.")
BURST_MSG = ("Never burst, load-test or crawl a live host (" + HOSTS_SHOWN + "; GUARD_LIVE_HOSTS in coordinator.conf). "
             "Point load at a NEW revision/preview URL or localhost only; one plain curl is fine (several URLs in ONE "
             "curl, e.g. curl -s url1 url2, also fine).")
CRAWL_MSG = ("Crawling a live host (" + HOSTS_SHOWN + ") with curl/wget in a while-read or for loop, or via xargs, is a "
             "burst (an agent once fetched every URL in the live sitemap, one after another). Crawl a NEW "
             "revision/preview URL or localhost. For a smoke test use ONE curl with several URLs (curl -s url1 url2); "
             "for polling, a while/until loop with one curl and a foreground sleep >= 5 on every iteration is allowed.")
COORD_MSG = ("The shell runs backticks and $( ) in the message before the script sees the text (a backtick in a reply "
             "once ran a real command). Put the message in a quoted heredoc: coordinator-reply.sh <id> - <<'EOF' "
             "(newline) text (newline) EOF. A $( ) in a flag value (--artifact \"$(git rev-parse HEAD)\") is fine.")
ENV_MSG = ("--set-env-vars / --set-secrets / --clear-* / --env-vars-file / services replace REPLACE the whole env or "
           "secret set, wiping every variable you didn't list. Use --update-env-vars / --update-secrets / "
           "--remove-env-vars, with the coordinator's GO.")
OBF_MSG = ("This command hides what it runs (eval, a substituted command word or sh -c payload, $( ) inside $(( )) or "
           "${ }) and that expression names a dangerous verb (pkill, killall, fuser -k, kill by lookup, "
           "--set-env-vars, --set-secrets). Write the command out plainly.")
WATCH_MSG = ("Never start inbox-watch.sh with & (a shell-backgrounded watcher is detached: its wake-ups never reach "
             "you). Start it ONLY with the Bash tool's run_in_background, so its exit re-invokes you.")
LOADTOOLS = "hey|oha|k6|wrk|ab|siege|vegeta|autocannon|bombardier|parallel|lychee|muffet|httrack|linkchecker"
FETCH = r"^(curl|wget|http|https|xh|" + LOADTOOLS + r")( .*)?" + HOSTS
CURLISH = r"^(curl|wget|http|https|xh)( |$)"

RULES_SRC = [
    ("kill-pattern", "cmd", "any", "eff", r"^(pkill|killall)( |$)", None, None, None, None, KILL_MSG),
    ("kill-pattern", "cmd", "any", "eff", r"^fuser( .*)? -[a-zA-Z]*k", None, None, None, None, KILL_MSG),
    ("kill-pattern", "call", "any", "eff", r"^(lsof( .*)? -[a-zA-Z]*t|pgrep( |$)|pidof( |$)|ps( |$))", "eff", r"^kill( |$)", None, None, KILL_MSG),
    ("kill-pattern", "cmd", "any", "eff", r"^kill( |$)", "lookup", r"^1$", None, None, KILL_MSG),

    ("remote-argv", "cmd", "remote", "eff", r"^ps +[a-zA-Z]*[auxw]|^ps( .*)? -[a-zA-Z]*[fFw]|^ps( .*)? (-[a-zA-Z]*[oO]|o|--format)[ =]?[^ ]*(args|command|cmd)", None, None, None, None, ARGV_MSG),
    ("remote-argv", "cmd", "remote", "eff", r"^pgrep( .*)? (-[a-zA-Z]*a[a-zA-Z]*|--list-full)( |$)|^pgrep( .*)? -[a-zA-Z]*(f[a-zA-Z]*l|l[a-zA-Z]*f)|^pgrep( .*)? -[a-zA-Z]*f( .*)? -[a-zA-Z]*l|^pgrep( .*)? -[a-zA-Z]*l( .*)? -[a-zA-Z]*f", None, None, None, None, ARGV_MSG),
    ("remote-argv", "cmd", "remote", "eff", r"^top( .*)? -[a-zA-Z]*c", None, None, None, None, ARGV_MSG),
    ("remote-argv", "cmd", "remote", "full", r"(^| )[^ ]*/proc/[^ ]*/(cmdline|environ)( |$)", None, None, None, None, ARGV_MSG),

    # secret-bearing config (all from coordinator.conf; empty = the row never matches).
    # A CLI honours the LAST --format, so every --format must be a safe field list.
    ("secret-describe", "cmd", "any", "eff", SECRET_DESCRIBE, "fmt", r"^(none|unsafe)$", None, None, SECRET_MSG),
    ("secret-fields", "cmd", "any", "eff", SECRET_CLI, "eff", SECRET_FIELDS, None, None, SECRET_MSG),
    ("secret-debug", "cmd", "any", "eff", SECRET_CLI, "eff", r"(^| )(" + SECRET_DEBUG + r")( |$)", None, None, SECRET_MSG),
    ("secret-debug", "cmd", "any", "eff", CURLISH, "eff", r"^(?=.*" + SECRET_API_HOST + r")(?=.*(^| )(-[a-zA-Z]*v[a-zA-Z]*|--verbose|--trace|--trace-ascii|-d|--debug)( |$))", None, None, SECRET_MSG),
    ("secret-rest", "cmd", "any", "eff", CURLISH, "full", SECRET_REST, None, None, SECRET_MSG),

    # live hosts come from GUARD_LIVE_HOSTS; none configured = these rows never match.
    # markers are judged on the fetch command itself: the xargs record IS the
    # fetch, and a load tool names its own target
    ("live-burst", "cmd", "any", "eff", FETCH, "full", r"(^| )xargs( .*)? (-[a-zA-Z]*P *[0-9]*|--max-procs)", None, None, BURST_MSG),
    ("live-burst", "cmd", "any", "eff", FETCH, "eff", r"^(" + LOADTOOLS + r")( |$)", None, None, BURST_MSG),
    ("live-burst", "cmd", "any", "eff", FETCH, "eff", r"^curl( .*)? (-[a-zA-Z]*Z[a-zA-Z]*|--parallel)( |$)", None, None, BURST_MSG),
    ("live-burst", "cmd", "any", "eff", FETCH, "eff", HOSTS + r"[^ ]*(\[[0-9]+-[0-9]+\]|\{[^ ]*,[^ ]*\})", None, None, BURST_MSG),
    ("live-burst", "cmd", "any", "eff", FETCH, "eff", r"^wget( .*)? (-[a-zA-Z]*[rm][a-zA-Z]*|--recursive|--mirror)( |$)", None, None, BURST_MSG),
    # (seq / for {1..N} no longer need rows of their own: a fetch they drive is
    #  in a loop body or under xargs, and the crawl rows below judge it by its URL)
    ("live-burst", "cmd", "any", "eff", FETCH, "bg", r"^1$", None, None, BURST_MSG),
    # crawls: the call names a live host and curl/wget runs in a loop body that
    # is not an allowed polling loop, or under xargs.
    # each fetch is judged by its own URL: a literal live URL in a
    # loop/xargs fetch is a crawl; an unresolved URL ("$u", "$BASE/x") counts
    # when the call names the live host anywhere; literal localhost URLs never
    ("live-burst", "cmd", "any", "iter", r"^[LX]+ live (curl|wget|http|https|xh)( |$)", None, None, None, None, CRAWL_MSG),
    ("live-burst", "call", "any", "full", HOSTS, "iter", r"^[LX]+ var (curl|wget|http|https|xh)( |$)", None, None, CRAWL_MSG),

    # direct, or as a shell's script operand: `bash [-x] .../inbox-watch.sh &`
    ("watcher-bg", "cmd", "any", "eff", r"^(inbox-watch\.sh|(bash|sh|zsh|dash|ksh)( -[A-Za-z]+)*( --)? ([^ ]*/)?inbox-watch\.sh)( |$)", "bg", r"^1$", None, None, WATCH_MSG),

    ("coord-expand", "cmd", "any", "eff", r"^(coordinator-reply|ask-coordinator|cmux-say|cmux-deliver)\.sh( |$)", "subst", r"^1$", None, None, COORD_MSG),

    ("env-clobber", "cmd", "any", "eff", r"^gcloud( .*)? run( |$)", "eff", r"(^| )--(set-env-vars|set-secrets|clear-env-vars|clear-secrets|env-vars-file)([= ]|$)", None, None, ENV_MSG),
    ("env-clobber", "cmd", "any", "eff", r"^gcloud( .*)? run( .*)? (services|jobs) replace( |$)", None, None, None, None, ENV_MSG),

    ("obfuscated", "cmd", "obf", "eff", r"(^|[^A-Za-z0-9_-])(pkill|killall)([^A-Za-z0-9_-]|$)|fuser[^;&|]*\s-[A-Za-z]*k|kill[^;&|]*(\$\(|`)\s*(pgrep|lsof|pidof)|--set-env-vars|--set-secrets", None, None, None, None, OBF_MSG),
]
CONF_ERROR = None
try:
    SAFE_FORMAT = re.compile(SAFE_FORMAT_SRC)
    RULES = [(n, sc, wh, mf, re.compile(m), af, re.compile(a) if a else None, nf, re.compile(x) if x else None, msg)
             for (n, sc, wh, mf, m, af, a, nf, x, msg) in RULES_SRC]
except re.error as e:                       # a bad regex in coordinator.conf: loud, never a traceback
    RULES, CONF_ERROR = [], f"bad regex in {conf_path()}: {e}"


def config_summary():
    secret = [k for k in ("GUARD_SECRET_CLI_RE", "GUARD_SECRET_DESCRIBE_RE", "GUARD_SECRET_FIELDS_RE",
                          "GUARD_SECRET_API_HOST_RE", "GUARD_SECRET_REST_RE") if CONF.get(k)]
    where = "built-in selftest example" if SELFTEST else conf_path()
    if not CONF_FOUND:
        return (f"config: none at {where}; live-burst and secret rows are INACTIVE "
                "(copy coordinator.conf.example to coordinator.conf and set GUARD_LIVE_HOSTS)")
    return (f"config: {where}; live hosts: {HOSTS_SHOWN}; secret rows: "
            + (", ".join(k[13:-3].lower() for k in secret) if secret else "off"))


def where_ok(where, e):
    if where == "any":
        return e["ctx"] != "obf"
    return e["ctx"] == where


def evaluate(entries):
    """First rule that denies, or None."""
    for rule in RULES:
        name, scope, where, mf, mre, af, are, nf, nre, msg = rule
        cands = [e for e in entries if where_ok(where, e)]
        if scope == "cmd":
            for e in cands:
                if mre.search(e[mf]) and (are is None or are.search(e[af])) and (nre is None or not nre.search(e[nf])):
                    return rule
        else:
            if any(mre.search(e[mf]) for e in cands) and any(are.search(e[af]) for e in cands):
                return rule
    return None


class Budget(Exception):
    pass


def _over_budget(*_a):
    raise Budget()


def main():
    parse_only = "--parse" in sys.argv[1:]
    budget = 6.0                       # the hook timeout is 10 s; stay well inside it
    try:
        budget = min(budget, float(os.environ.get("GUARD_BUDGET_SEC", budget)))
    except ValueError:
        pass
    if CONF_ERROR:
        print(f"@@err {CONF_ERROR}")
        sys.exit(3)
    if "--config-summary" in sys.argv[1:]:
        print(config_summary())
        print("@@ok")
        return
    if len(RULES) < 20:
        print(f"@@err rule table did not load ({len(RULES)} rows)")
        sys.exit(3)
    signal.signal(signal.SIGALRM, _over_budget)
    signal.setitimer(signal.ITIMER_REAL, max(budget, 0.001))
    try:
        raw = sys.stdin.read()
        try:
            d = json.loads(raw)
        except Exception:
            print("@@err hook input is not JSON")
            sys.exit(3)
        if d.get("tool_name") not in (None, "Bash"):
            print("@@allow")
            return
        cmd = (d.get("tool_input") or {}).get("command") or ""
        if not isinstance(cmd, str) or not cmd:
            print("@@allow")
            return
        out = []
        scan(cmd, "local", 0, out)
        poll = polling_loops(out)
        entries = []
        for e in out:
            tags = ("L" if e["loop"] is not None and e["loop"] not in poll else "") + ("X" if e["xargs"] else "")
            entries.append({"ctx": e["ctx"], "bg": e["bg"], "subst": e["subst"], "fmt": e["fmt"],
                            "iter": (tags or "-") + " " + e["dest"] + " " + flat(e["eff"]), "eff": flat(e["eff"]),
                            "full": flat(e["full"]), "lookup": e["lookup"]})
        for ctx, text in STATE["obf_texts"]:
            entries.append({"ctx": "obf", "bg": "0", "subst": "0", "fmt": "-", "iter": "- - " + flat(text),
                            "eff": flat(text), "full": flat(text), "lookup": "0", "inner_ctx": ctx})
        if parse_only:
            for e in entries:
                print("\t".join(e[k] for k in ("ctx", "bg", "subst", "fmt", "iter", "eff", "full")))
            print("@@ok")
            return
        rule = evaluate(entries)
        signal.setitimer(signal.ITIMER_REAL, 0)
        if rule:
            print(f"@@deny\t{rule[0]}\t{rule[9]}")
        else:
            print("@@allow")
    except Budget:
        print(f"@@err evaluation exceeded the {budget:g} s budget (hook timeout is 10 s)")
        sys.exit(3)


try:
    main()
except SystemExit:
    raise
except Exception as e:  # never a traceback: guard.sh reports it loudly
    print(f"@@err parser error: {type(e).__name__}: {e}")
    sys.exit(3)
