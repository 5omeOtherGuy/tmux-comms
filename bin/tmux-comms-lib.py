#!/usr/bin/env python3
"""tmux-comms helper: resolve panes, classify harness prompts, verify typed/delivered text.

Used by tmux-send, tmux-panes and tmux-await. Read-only towards tmux: it only runs
list-panes / display-message / capture-pane. It never sends keys.

Environment:
  TMUX_COMMS_SOCKET  tmux socket name (passed as `tmux -L NAME`); unset = default server.

Subcommands (exit 4 = no such pane / ambiguous, 1 = usage):
  resolve TARGET                 print the pane id (%N) for a pane id, @pane-label, pane_title,
                                 window name or tmux target (sess:win.pane)
  classify PANE                  print fields separated by \\x1f:
                                 harness state composer marker dead in_mode cmd composer_text
  classify-text [--cmd C] [--harness H]   same, classifying a capture read from stdin
  check-typed PANE TEXT          ok | missing | foreign | noprompt   (before pressing Enter)
  post-check PANE TEXT           delivered | queued | pending | noprompt  (after pressing Enter)
  tail PANE [N]                  last N (default 15) non-empty lines of the pane
  panes [--json]                 table / JSON of every pane
"""
import json
import os
import re
import subprocess
import sys

SEP = "\x1f"

SHELLS = {"bash", "zsh", "sh", "fish", "dash", "ksh", "tcsh", "csh", "mksh", "ash"}

CODEX_PLACEHOLDERS = ["Ask Codex to do anything"]
P1_IDLE_PLACEHOLDER = "message, / for commands"
P1_BUSY_PLACEHOLDER = "steer the running turn"
P1_PLACEHOLDERS = [P1_IDLE_PLACEHOLDER, P1_BUSY_PLACEHOLDER]
CLAUDE_PLACEHOLDER_RE = re.compile(r'^Try "[^"]*"$')

# Composers are introduced by a prompt glyph. `❯ › » ‣` are unambiguous; a bare `>` is only
# taken as a prompt when the pane shows other TUI evidence (footer / placeholder / @harness), so a
# markdown quote in a transcript or a shell continuation prompt is not mistaken for one. A box
# edge ("│") may sit before the glyph and after the text, and the glyph need not be followed by a
# space: live Claude Code renders a typed line as "❯ Did you restart the workers?" and, in
# narrow panes, "❯Did you restart the workers?". A left margin may precede the glyph (p1 draws
# its TUI four columns in).
PROMPT_RE = re.compile(r"^[ \t]*(?:[│┃|][ \t]*)?([❯›»‣])[ \t\u00a0]*(.*?)[ \t\u00a0]*$")
GT_PROMPT_RE = re.compile(r"^[ \t]*(?:[│┃|][ \t]*)?(>)[ \t\u00a0]*(.*?)[ \t\u00a0]*$")
BOX_EDGE_RE = re.compile(r"^[ \t]*[│┃|]")
BORDER_RE = re.compile(r"^\s*[│┃|]?\s*[─━═╭╮╰╯┌┐└┘▔▁]{3,}\s*$")
FOOTER_MARKERS = ("⏎", "? for shortcuts", "context left", "esc to interrupt", "⏵⏵", "shift+tab",
                  "queue steering", "queue follow-up")
CLAUDE_EVIDENCE = ("? for shortcuts", "⏵⏵", "bypass permissions", 'Try "')
SPINNER_RE = re.compile(r"^\s*[✻✶✳✢✽*●◐◓◑◒⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏·]\s+\S.*(…|\.\.\.)")
P1_MARKER_RE = re.compile(r"·\s*steering|\bqueued\b", re.IGNORECASE)
PASTED_RE = re.compile(r"\[Pasted", re.IGNORECASE)
SCROLL_MARK_RE = re.compile(r"^\s*(?:…|\.\.\.|\[\.\.\.\])\s*")
REGION_MAX_LINES = 30


# --------------------------------------------------------------------------- tmux access

def tmux(*args, check=True):
    cmd = ["tmux"]
    sock = os.environ.get("TMUX_COMMS_SOCKET")
    if sock:
        cmd += ["-L", sock]
    cmd += list(args)
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                       encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        raise TmuxError(r.stderr.strip() or "tmux %s failed" % args[0])
    return r.stdout


class TmuxError(Exception):
    pass


PANE_FIELDS = ["pane_id", "@pane-label", "pane_title", "window_name", "session_name",
               "window_index", "pane_index", "pane_dead", "pane_in_mode",
               "pane_current_command", "@harness", "pane_current_path", "host", "host_short"]


def list_panes():
    fmt = "\t".join("#{%s}" % f for f in PANE_FIELDS)
    try:
        out = tmux("list-panes", "-a", "-F", fmt)
    except TmuxError:
        return []
    panes = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != len(PANE_FIELDS):
            continue
        panes.append(dict(zip(PANE_FIELDS, parts)))
    return panes


def pane_info(pane_id):
    for p in list_panes():
        if p["pane_id"] == pane_id:
            return p
    return None


def capture(pane_id):
    out = tmux("capture-pane", "-p", "-J", "-t", pane_id)
    lines = [l.rstrip() for l in out.split("\n")]
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def resolve(target):
    """Return (pane_id, error). Exact matches only; ambiguity is an error."""
    panes = list_panes()
    if re.fullmatch(r"%\d+", target):
        if any(p["pane_id"] == target for p in panes):
            return target, None
        return None, "no such pane: %s" % target
    for key, what in (("@pane-label", "@pane-label"), ("pane_title", "pane_title"),
                      ("window_name", "window name")):
        hits = [p for p in panes if p[key] == target]
        if len(hits) == 1:
            return hits[0]["pane_id"], None
        if len(hits) > 1:
            desc = ", ".join("%s(%s:%s.%s)" % (p["pane_id"], p["session_name"], p["window_index"],
                                               p["pane_index"]) for p in hits)
            return None, "ambiguous %s %r matches %d panes: %s — use a pane id" % (
                what, target, len(hits), desc)
    if ":" in target or "." in target:
        try:
            pid = tmux("display-message", "-p", "-t", target, "#{pane_id}").strip()
            if re.fullmatch(r"%\d+", pid):
                return pid, None
        except TmuxError:
            pass
    return None, "no pane with id/label/title/window name %r" % target


# --------------------------------------------------------------------------- classification

def clean_line(line):
    """Drop a right box edge and trailing blanks, so '│ ❯ text │' reads as '│ ❯ text'."""
    return re.sub(r"[ \t]*[│┃]$", "", line.rstrip())


def _is_placeholder(content):
    return content.strip() in CODEX_PLACEHOLDERS + P1_PLACEHOLDERS


def _strip_edges(text):
    return text.strip().strip("│┃ ").strip()


def classify_lines(lines, cmd="", override=""):
    """Classify a pane capture.

    Returns dict(harness, state, composer, text, marker, prompt):
      composer = empty   | provably empty: safe to type into
               | text    | holds text (someone's, possibly ours): never type blind
               | none    | no input prompt at all (plain shell / not a TUI)
               | unknown | looks like a TUI but the composer line could not be located
      text = everything from the prompt glyph up to the separator/footer: the composer region,
             including wrapped continuation lines and text on the glyph line itself. ANY
             non-empty region is text, so a line a person typed ("❯ Did you restart the
             workers?") is never mistaken for an empty composer.
    """
    cmd = (cmd or "").strip()
    lines = [clean_line(l) for l in lines]
    bottom = "\n".join(lines[-14:])
    screen = "\n".join(lines)
    tui_evidence = bool(override) or any(m in bottom for m in FOOTER_MARKERS) or any(
        p in screen for p in CODEX_PLACEHOLDERS + P1_PLACEHOLDERS)

    prompt_idx = glyph = kind = None
    content = ""
    for i in range(len(lines) - 1, -1, -1):
        line = lines[i]
        m = PROMPT_RE.match(line)
        if m:
            kind = "claude" if m.group(1) == "❯" else "arrow"
        else:
            m = GT_PROMPT_RE.match(line)
            if m and (BOX_EDGE_RE.match(line) or tui_evidence):
                kind = "claude" if any(e in bottom for e in CLAUDE_EVIDENCE[:2]) else "arrow"
            else:
                m = None
        if m:
            prompt_idx, glyph, content = i, m.group(1), (m.group(2) or "").strip()
            break

    if glyph is None:
        harness = override or ("shell" if cmd in SHELLS else "unknown")
    elif override:
        harness = override
    elif kind == "claude":
        harness = "claude"
    elif (content in CODEX_PLACEHOLDERS or "codex" in cmd.lower()
          or "Codex" in screen or "Ask Codex to do anything" in screen
          or "context left" in bottom):
        harness = "codex"
    elif (content in P1_PLACEHOLDERS or "queue steering" in bottom or "queue follow-up" in bottom
          or "⏎ send" in bottom or "/ for commands" in bottom or P1_BUSY_PLACEHOLDER in bottom):
        harness = "p1"
    elif any(e in bottom for e in CLAUDE_EVIDENCE):
        harness = "claude"
    else:
        harness = "tui"

    # ---- composer region
    text = ""
    if prompt_idx is not None:
        if kind == "claude" and CLAUDE_PLACEHOLDER_RE.match(content):
            content = ""
        if _is_placeholder(content):
            content = ""
        parts = [content] if content else []
        for line in lines[prompt_idx + 1:prompt_idx + 1 + REGION_MAX_LINES]:
            s = line.strip()
            if not s:
                continue                      # empty row inside the input box
            if BORDER_RE.match(line) or any(m in line for m in FOOTER_MARKERS):
                break                         # separator / status bar: composer ends here
            if P1_MARKER_RE.search(line):
                continue                      # queued-steering echo, not composer text
            if PROMPT_RE.match(line) or GT_PROMPT_RE.match(line):
                break                         # another input line: stop
            parts.append(_strip_edges(line))
        text = " ".join(p for p in parts if p)
    elif harness == "shell" and lines:
        m = re.match(r"^.*?[$#%]\s?(.*)$", lines[-1])
        text = m.group(1).strip() if m else lines[-1].strip()

    if prompt_idx is None and harness != "shell":
        composer = "unknown" if tui_evidence else "none"
    else:
        composer = "text" if text else "empty"

    # busy / idle
    last = prompt_idx if prompt_idx is not None else len(lines)
    above = "\n".join(lines[max(0, last - 8):last])
    if harness == "claude":
        busy = "esc to interrupt" in bottom or any(SPINNER_RE.match(l) for l in above.split("\n"))
    elif harness == "codex":
        busy = "esc to interrupt" in bottom or "Working (" in bottom
    elif harness == "p1":
        busy = (content == P1_BUSY_PLACEHOLDER or P1_BUSY_PLACEHOLDER in bottom
                or "queue steering" in bottom or "queue follow-up" in bottom)
    elif harness == "shell":
        busy = cmd not in SHELLS
    elif harness == "tui":
        busy = "esc to interrupt" in bottom
    else:
        busy = None
    state = "unknown" if busy is None else ("busy" if busy else "idle")

    marker = bool(harness == "p1" and P1_MARKER_RE.search(bottom))
    return {"harness": harness, "state": state, "composer": composer, "text": text,
            "marker": marker, "prompt": prompt_idx}


def last_line(lines, width=60):
    for l in reversed(lines):
        if l.strip():
            s = " ".join(l.split())
            return s[:width]
    return ""


def classify_pane(pane_id):
    info = pane_info(pane_id)
    if info is None:
        return None, None, []
    lines = capture(pane_id)
    c = classify_lines(lines, info["pane_current_command"], info["@harness"])
    if info["pane_dead"] == "1":
        c["state"] = "dead"
    return info, c, lines


# --------------------------------------------------------------------------- text checks

def _ns(s):
    return re.sub(r"\s+", "", s)


def match_composer(comp, want):
    """Is `want` the text visible in the composer region `comp` (whitespace-insensitive)?

    same    the region is our message, or the part of it still on screen — the pane may have
            wrapped or scrolled, so the region can be any slice of the message, even one that
            starts mid-word
    foreign the region also holds text that is not ours (someone typed in front of or behind us)
    missing our text is not in the region at all
    """
    comp, want = _ns(comp), _ns(want)
    if not want or comp == want or PASTED_RE.search(comp):
        return "same"
    if not comp:
        return "missing"
    for cand in (comp, SCROLL_MARK_RE.sub("", comp)):
        if cand and cand in want:
            return "same"                      # visible slice of our message (wrapped/scrolled)
    n = min(40, len(want))
    probe = want[-n:]
    idx = comp.find(probe)
    if idx >= 0:
        prefix, rest = comp[:idx], comp[idx + n:]
        if prefix and prefix != want[:len(prefix)]:
            return "foreign"                   # a stranger's text in front of ours
        if rest:
            return "foreign"                   # someone typed behind our tail
        return "same"
    if comp[-n:] and comp[-n:] in want:
        return "same"                          # region clipped at its tail
    return "missing"


def check_typed(c, sent, lines=None):
    """Before pressing Enter: is the text we typed visible in the composer?"""
    if c["prompt"] is None and c["harness"] != "shell":
        return "noprompt"
    state = match_composer(c["text"], sent)
    if state == "missing" and lines:
        # widen the region: look past whatever stopped the extraction above the separator
        i = c["prompt"] or 0
        wide = " ".join(l.strip() for l in lines[i:] if l.strip())
        if match_composer(wide, sent) != "missing":
            return "ok"
    return {"same": "ok", "foreign": "foreign", "missing": "missing"}[state]


def post_check(c, sent):
    """After pressing Enter: did the message leave the composer?"""
    if c["composer"] == "text" and match_composer(c["text"], sent) != "missing":
        return "pending"
    if c["marker"] and c["harness"] == "p1":
        return "queued"
    if c["composer"] in ("none", "unknown"):
        return "noprompt"
    return "delivered"  # composer empty, or holds only someone else's new text


# --------------------------------------------------------------------------- output

def fields(info, c):
    text = c["text"].replace(SEP, " ").replace("\n", " ")
    return SEP.join([c["harness"], c["state"], c["composer"], "1" if c["marker"] else "0",
                     info.get("pane_dead", "0") or "0", info.get("pane_in_mode", "0") or "0",
                     info.get("pane_current_command", "") or "-", text])


def cmd_panes(as_json):
    rows = []
    for p in list_panes():
        try:
            lines = capture(p["pane_id"])
        except TmuxError:
            lines = []
        c = classify_lines(lines, p["pane_current_command"], p["@harness"])
        dead = p["pane_dead"] == "1"
        rows.append({
            "id": p["pane_id"],
            "session": p["session_name"],
            "window": "%s:%s" % (p["session_name"], p["window_index"]),
            "window_name": p["window_name"],
            "pane_index": int(p["pane_index"] or 0),
            "label": p["@pane-label"],
            "title": "" if p["pane_title"] in (p["host"], p["host_short"]) else p["pane_title"],
            "harness": c["harness"],
            "state": "dead" if dead else c["state"],
            "composer": c["composer"],
            "dead": dead,
            "in_mode": p["pane_in_mode"] == "1",
            "cmd": p["pane_current_command"],
            "path": p["pane_current_path"],
            "last": last_line(lines),
        })
    if as_json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    hdr = ["ID", "WINDOW", "LABEL", "HARNESS", "STATE", "DEAD", "CMD", "LAST"]
    table = [hdr] + [[r["id"], "%s(%s)" % (r["window"], r["window_name"])[:28],
                      (r["label"] or r["title"] or "-")[:24], r["harness"], r["state"],
                      "1" if r["dead"] else "0", r["cmd"][:12], r["last"]] for r in rows]
    widths = [max(len(row[i]) for row in table) for i in range(len(hdr) - 1)]
    for row in table:
        print("  ".join(row[i].ljust(widths[i]) for i in range(len(widths))) + "  " + row[-1])
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 1
    sub, rest = argv[1], argv[2:]
    try:
        if sub == "resolve" and len(rest) == 1:
            pid, err = resolve(rest[0])
            if err:
                print(err, file=sys.stderr)
                return 4
            print(pid)
            return 0
        if sub == "classify-text":
            cmd, override = "", ""
            i = 0
            while i < len(rest):
                if rest[i] == "--cmd":
                    cmd, i = rest[i + 1], i + 2
                elif rest[i] == "--harness":
                    override, i = rest[i + 1], i + 2
                else:
                    return 1
            lines = [l.rstrip() for l in sys.stdin.read().split("\n")]
            while lines and not lines[-1].strip():
                lines.pop()
            c = classify_lines(lines, cmd, override)
            print(fields({"pane_current_command": cmd}, c))
            return 0
        if sub == "panes":
            return cmd_panes("--json" in rest)
        if sub in ("classify", "check-typed", "post-check", "tail") and rest:
            info, c, lines = classify_pane(rest[0])
            if info is None:
                print("no such pane: %s" % rest[0], file=sys.stderr)
                return 4
            if sub == "classify":
                print(fields(info, c))
            elif sub == "check-typed" and len(rest) == 2:
                print(check_typed(c, rest[1], lines))
            elif sub == "post-check" and len(rest) == 2:
                print(post_check(c, rest[1]))
            elif sub == "tail":
                n = int(rest[1]) if len(rest) > 1 else 15
                print("\n".join([l for l in lines if l.strip()][-n:]))
            else:
                return 1
            return 0
    except TmuxError as e:
        print("tmux error: %s" % e, file=sys.stderr)
        return 4
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
