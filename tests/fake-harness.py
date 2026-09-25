#!/usr/bin/env python3
"""Fake agent TUI for tmux-comms tests. Draws a Claude/Codex/p1-like screen, reads raw keys.

Log lines (tab separated) go to --log:
  SUBMIT <text>   message submitted with Enter      STEER <text>  queued steering (p1 busy)
  SWALLOW <text>  Enter ignored (paste detection)   KEY <name>    ESC / C-u / C-c / C-w received
  TYPED <text>    someone else typed this text into the composer (--clear-after)
"""
import argparse
import codecs
import os
import select
import sys
import termios
import time
import tty

ap = argparse.ArgumentParser()
ap.add_argument("--kind", choices=["claude", "codex", "p1"], required=True)
ap.add_argument("--busy", action="store_true")
ap.add_argument("--swallow-enters", type=int, default=0,
                help="ignore the first N Enters after text was typed")
ap.add_argument("--prefill", default="", help="text already in the composer (someone typing)")
ap.add_argument("--margin", type=int, default=0, help="left margin in columns (p1 draws 4)")
ap.add_argument("--wrap", type=int, default=0,
                help="p1 only: wrap the composer text at this width with a 2-column hanging indent")
ap.add_argument("--submit-delay", type=float, default=0,
                help="seconds the submitted text stays visible in the composer (slow TUI redraw)")
ap.add_argument("--clear-after", type=float, default=0,
                help="the prefilled text is submitted by someone else after S seconds")
ap.add_argument("--glyph", default="", help="override the prompt glyph (default: ❯ / ›)")
ap.add_argument("--tight-glyph", action="store_true", help="no space between glyph and text")
ap.add_argument("--reveal", default="",
                help="composer shows only part of the buffered text, as when the pane scrolls: "
                     "tail:N or slice:S:E")
ap.add_argument("--interleave", default="",
                help="TEXT appears in the composer the moment the first foreign key arrives")
ap.add_argument("--log", required=True)
a = ap.parse_args()

buf = a.prefill
history = []
swallow_left = a.swallow_enters
clear_at = None  # --submit-delay: composer still shows the submitted text until then
start = time.time()
glyph = a.glyph or ("❯" if a.kind == "claude" else "›")
gap = "" if a.tight_glyph else " "


def shown(text):
    """What the composer displays for `text` (may be a slice of it, as in a scrolled pane)."""
    if not a.reveal:
        return text
    kind, _, spec = a.reveal.partition(":")
    if kind == "tail":
        n = int(spec or 0)
        return text[-n:] if n > 0 else ""
    if kind == "slice":
        s0, s1 = (int(x) for x in (spec.split(":") + [""])[:2])
        return text[s0:s1] if s1 else text[s0:]
    raise SystemExit("bad --reveal %r" % a.reveal)


def log(kind, text=""):
    with open(a.log, "a", encoding="utf-8") as f:
        f.write("%s\t%s\n" % (kind, text))


def draw():
    w = os.get_terminal_size().columns
    out = ["\x1b[H\x1b[2J"]
    lines = []
    if a.kind == "claude":
        lines.append(" ✻ Claude Code (fake fixture)")
        lines += ["● got: " + h for h in history[-8:]]
        if a.busy:
            lines.append("✻ Thinking… (3s · esc to interrupt)")
        lines.append("─" * (w - 1))
        lines.append(glyph + gap + shown(buf))
        lines.append("─" * (w - 1))
        lines.append("  ? for shortcuts                                   fake-opus")
    elif a.kind == "codex":
        lines.append(">_ OpenAI Codex (fake fixture)")
        lines += ["• got: " + h for h in history[-8:]]
        if a.busy:
            lines.append("• Working (3s • esc to interrupt)")
        lines.append("")
        lines.append(glyph + gap + (shown(buf) if buf else "Ask Codex to do anything"))
        lines.append("")
        lines.append("  100% context left · ? for shortcuts")
    else:
        lines.append("p1 (fake fixture)")
        lines += history[-8:]
        placeholder = "steer the running turn" if a.busy else "message, / for commands"
        if buf and a.wrap:
            import textwrap
            rows = textwrap.wrap(shown(buf), a.wrap) or [""]
            lines.append(glyph + gap + rows[0])
            lines += ["  " + r for r in rows[1:]]
        else:
            lines.append(glyph + gap + (shown(buf) if buf else placeholder))
        lines.append("  ⏎ queue steering" if a.busy else "  ⏎ send")
    if a.margin:
        lines = [" " * a.margin + l for l in lines]
    out.append("\r\n".join(lines))
    sys.stdout.write("".join(out))
    sys.stdout.flush()


def submit():
    global buf, swallow_left, clear_at
    text = buf
    if a.kind == "p1" and a.busy:
        history.append("· steering: " + text)
        log("STEER", text)
    else:
        history.append(text)
        log("SUBMIT", text)
    if a.submit_delay:
        clear_at = time.time() + a.submit_delay   # text lingers; Enters meanwhile are ignored
    else:
        buf = ""
    swallow_left = a.swallow_enters


fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
try:
    draw()
    while True:
        r, _, _ = select.select([fd], [], [], 0.2)
        if a.clear_after and buf == a.prefill and a.prefill and time.time() - start > a.clear_after:
            log("TYPED", buf)
            history.append(buf)
            buf = ""
            a.prefill = ""
            draw()
        if clear_at and time.time() >= clear_at:
            buf, clear_at = "", None
            draw()
        if not r:
            continue
        data = os.read(fd, 4096)
        if not data:
            break
        for ch in dec.decode(data):
            if ch in "\r\n":
                if clear_at:
                    log("LATE-ENTER", buf)      # already submitted; a TUI ignores this Enter
                elif buf and swallow_left > 0:
                    swallow_left -= 1
                    log("SWALLOW", buf)
                elif buf:
                    submit()
            elif ch == "\x1b":
                log("KEY", "ESC")
            elif ch == "\x15":
                log("KEY", "C-u")
                buf = ""
            elif ch == "\x03":
                log("KEY", "C-c")
            elif ch == "\x17":
                log("KEY", "C-w")
            elif ch == "\x7f":
                buf = buf[:-1]
            elif ch >= " ":
                if a.interleave and not buf:
                    buf, a.interleave = a.interleave, ""
                buf += ch
        draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
