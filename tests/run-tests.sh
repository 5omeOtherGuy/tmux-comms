#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2001  # literal $ in patterns/messages is intended
# tmux-comms test suite. Runs ONLY against a private tmux server (tmux -L tmuxcomms-test);
# a guard shim makes any tmux call from the tools that targets another server fail loudly.
# Everything the tools write (HOME, XDG_STATE_HOME, inbox, logs) stays in one temp work dir,
# so the suite does not touch the machine it runs on.
# usage: tests/run-tests.sh    (≈3 min; needs tmux >= 3.0 and python3 >= 3.8; shellcheck is
#                              used when installed, skipped with a note otherwise)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BIN="$ROOT/bin"
SOCK=tmuxcomms-test
REAL_TMUX="$(command -v tmux)" || { echo "tmux not installed"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not installed"; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tmuxcomms-test.XXXXXX")"

unset TMUX TMUX_PANE TMUX_COMMS_FROM TMUX_COMMS_INBOX
export HOME="$WORK/home" XDG_STATE_HOME="$WORK/xdg-state"
mkdir -p "$HOME" "$XDG_STATE_HOME"
export TMUX_COMMS_SOCKET="$SOCK" TMUX_COMMS_INBOX="$WORK/inbox"

# Force UTF-8 in python (the fixtures carry box-drawing glyphs, arrows and em dashes) so that
# decoding never depends on the locale of the machine running the suite.
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1
utf8_locale=""
for cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qxF -- "$cand"; then utf8_locale="$cand"; break; fi
done
if [[ -n $utf8_locale ]]; then
  export LC_ALL="$utf8_locale"
else
  echo "NOTE  no C/en_US UTF-8 locale installed; tmux and the shell keep '${LC_ALL:-${LANG:-C}}'"
fi

# ---- guard shim: tools may only talk to the private server -----------------------------------
mkdir -p "$WORK/shim"
cat >"$WORK/shim/tmux" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == -L && "\${2:-}" == "$SOCK" ]]; then exec "$REAL_TMUX" "\$@"; fi
printf '%s\n' "\$*" >>"$WORK/shim-violations.log"
exit 99
EOF
chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"

T() { tmux -L "$SOCK" "$@"; }
real_panes() { "$REAL_TMUX" list-panes -a -F '#{pane_id} #{pane_current_command}' 2>/dev/null | sort; }
REAL_BEFORE="$(real_panes)"

cleanup() {
  T kill-server 2>/dev/null
  if ((fail)); then echo "work dir kept: $WORK"; else rm -rf "$WORK"; fi
}
pass=0 fail=0
trap cleanup EXIT
ok() { pass=$((pass + 1)); echo "PASS  $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { echo; echo "== $*"; }

send() { OUT="$("$BIN/tmux-send" "$@" 2>&1)"; RC=$?; }
rc_is() { [[ $RC == "$1" ]] || { echo "      rc=$RC, output:"; sed 's/^/      /' <<<"$OUT"; return 1; }; }
out_has() { grep -qF -- "$1" <<<"$OUT" || { echo "      output lacks «$1»:"; sed 's/^/      /' <<<"$OUT"; return 1; }; }
log_has() { grep -qxF -- "$2" "$WORK/$1.log" 2>/dev/null || { echo "      $1.log lacks «$2»:"; sed 's/^/      /' "$WORK/$1.log" 2>/dev/null; return 1; }; }
log_count() { local n; n=$(grep -c -- "^$2" "$WORK/$1.log" 2>/dev/null); [[ ${n:-0} == "$3" ]] || { echo "      $1.log: $2 count ${n:-0} != $3"; return 1; }; }
no_keys() { ! grep -q '^KEY' "$WORK/$1.log" 2>/dev/null; }
screen_has() { T capture-pane -p -J -t "$1" | grep -qF -- "$2"; }

newpane() { T new-window -d -P -F '#{pane_id}' -n "$1" -c "$WORK" "$2"; }
fake() { local n="$1" k="$2"; shift 2; newpane "$n" "python3 '$HERE/fake-harness.py' --kind $k --log '$WORK/$n.log' $*"; }
ps1pane() { newpane "$1" "PS1='$2' HISTFILE=/dev/null bash --norc --noprofile"; }
wait_screen() { # pane text
  local i; for ((i = 0; i < 50; i++)); do screen_has "$1" "$2" && return 0; sleep 0.1; done
  echo "      pane $1 never showed «$2»"; return 1
}
word() { printf '%s\n' "$OUT" | tail -n 1 | awk '{print $1}'; }
json_field() { # window-name field
  python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])); print([str(r[sys.argv[3]]) for r in rows if r["window_name"]==sys.argv[2]][0])' \
    "$WORK/panes.json" "$1" "$2"
}

# ============================================================================================
section "static checks"
check "bash -n bin/tmux-send bin/tmux-panes bin/tmux-await tests/run-tests.sh" \
  bash -c "for f in '$BIN/tmux-send' '$BIN/tmux-panes' '$BIN/tmux-await' '$HERE/run-tests.sh'; do bash -n \"\$f\" || exit 1; done"
check "python3 py_compile lib + fake harness" \
  python3 -c "import py_compile,sys; [py_compile.compile(f, cfile=sys.argv[1]+'/x.pyc', doraise=True) for f in sys.argv[2:]]" "$WORK" \
  "$BIN/tmux-comms-lib.py" "$HERE/fake-harness.py"
if command -v shellcheck >/dev/null; then
  check "shellcheck clean" shellcheck "$BIN/tmux-send" "$BIN/tmux-panes" "$BIN/tmux-await" "$HERE/run-tests.sh"
else
  echo "SKIP  shellcheck not installed"
fi
TOOLS=("$BIN/tmux-send" "$BIN/tmux-await" "$BIN/tmux-panes" "$BIN/tmux-comms-lib.py")
sendkeys_literal_or_enter_only() {
  local offending
  offending="$(grep -n 'send-keys' "${TOOLS[@]}" | grep -vE ':[0-9]+: *#' |
    grep -vE 'send-keys -t "\$pane" (-l -- "\$c"|C-m)(;.*)?$')"
  [[ -z $offending ]] || { echo "      $offending"; return 1; }
  grep -q 'send-keys -t "$pane" -l -- "$c"' "$BIN/tmux-send"
}
never_kills() {
  # strip comments and quoted strings first: the tools mention respawn-pane/kill only in advice
  python3 - "${TOOLS[@]}" <<'PY'
import re, sys
pat = re.compile(r"(^|[;&|(]\s*)((tmux|tmx)\s+(kill-(pane|window|session|server)|respawn-pane)|pkill\b)",
                 re.M)
bad = []
for path in sys.argv[1:]:
    src = open(path, encoding="utf-8").read()
    src = re.sub(r"(?m)^\s*#.*$", "", src)
    src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)
    src = re.sub(r"'(?:\\.|[^'\\])*'", "''", src)
    m = pat.search(src)
    if m:
        bad.append("%s: %s" % (path, m.group(0).strip()))
print("\n".join("      " + b for b in bad))
sys.exit(1 if bad else 0)
PY
}
check "code read: every send-keys is literal text (-l --) or C-m; no Escape/C-u/C-c" sendkeys_literal_or_enter_only
check "code read: tools never kill/respawn anything" never_kills

section "classification on static fixtures (Claude Code, Codex CLI, p1 TUI, shell)"
while IFS=$'\t' read -r f cmd harness state composer marker text; do
  [[ $f == \#* || -z $f ]] && continue
  IFS=$'\x1f' read -r h s c m _ _ _ t < <(python3 "$BIN/tmux-comms-lib.py" classify-text --cmd "$cmd" <"$HERE/fixtures/$f")
  got="$h/$s/$c/$m/$t" want="$harness/$state/$composer/$marker/$text"
  if [[ $got == "$want" ]]; then ok "fixture $f → $harness $state $composer"; else bad "fixture $f: got $got want $want"; fi
done <"$HERE/fixtures/expected.tsv"

# ============================================================================================
section "private tmux server $SOCK"
T -f /dev/null new-session -d -s t -x 160 -y 40 -n home "bash --norc --noprofile"
T set -g default-size 160x40
T set -g remain-on-exit on
check "private server is up" T has-session -t t

P_CL_PS1=$(ps1pane ps1-claude '❯ ')
P_P1_PS1=$(ps1pane ps1-p1 '› message, / for commands')
P_CX_PS1=$(ps1pane ps1-codex '› Ask Codex to do anything')
P_SH_PS1=$(ps1pane ps1-shell '$ ')
P_CL=$(fake claude1 claude)
P_CLB=$(fake claudebusy claude --busy)
P_CX=$(fake codex1 codex)
P_CXB=$(fake codexbusy codex --busy)
P_P1=$(fake p1a p1)
P_P1B=$(fake p1busy p1 --busy)
P_SW1=$(fake p1swallow p1 --swallow-enters 1)
P_SW1F=$(fake p1force p1 --swallow-enters 1)
P_STUCK=$(fake codexstuck codex --swallow-enters 9)
P_FOREIGN=$(fake person codex "--prefill 'What direct'")
P_LAB=$(fake labelled claude)
P_TTL=$(fake titled codex)
P_DUP1=$(fake dup1 claude)
P_DUP2=$(fake dup2 claude)
P_LONG=$(fake longmsg claude)
P_FILE=$(fake filemsg p1)
P_AWAIT=$(fake awaiter claude "--prefill 'draft in progress' --clear-after 3")
P_MODE=$(fake scrolled claude)
P_RACE=$(fake race claude "--interleave 'What direct'")
P_USERLINE=$(fake userline claude "--prefill 'Did you restart the workers?'")
P_USERSLASH=$(fake userslash claude "--prefill '/status'")
P_USERBUSY=$(fake userbusy claude "--busy --prefill 'Did you restart the workers?'")
P_TIGHT=$(fake tight claude --tight-glyph)
P_TIGHTUSER=$(fake tightuser claude "--tight-glyph --prefill 'Did you restart the workers?'")
P_GT=$(fake gtglyph claude "--glyph '>'")
P_GTUSER=$(fake gtglyphuser claude "--glyph '>' --prefill 'Did you restart the workers?'")
P_P1GT=$(fake p1gtglyph p1 "--busy --glyph '>'")
P_VIEWT=$(fake viewtail claude --reveal tail:25)
P_VIEWS=$(fake viewslice claude --reveal slice:40:120)
P_P1VIEW=$(fake p1viewtail p1 "--busy --reveal tail:25")
P_STUCK2=$(fake codexstuck2 codex --swallow-enters 9)
P_GTP1IDLE=$(fake gtglyphidle p1 "--glyph '>'")
P_SLOW=$(fake p1slow p1 --submit-delay 5)
P_MARGIN=$(fake p1margin p1 "--margin 4 --wrap 90")
P_MARGINB=$(fake p1marginbusy p1 "--margin 4 --wrap 90 --busy")
P_DEAD=$(newpane deadwin "exit 0")
for p in "$P_CL_PS1" "$P_P1_PS1" "$P_CX_PS1"; do wait_screen "$p" "›" >/dev/null 2>&1 || wait_screen "$p" "❯"; done
wait_screen "$P_SH_PS1" '$'
for p in "$P_RACE" "$P_CL" "$P_CLB" "$P_LAB" "$P_DUP1" "$P_DUP2" "$P_LONG" "$P_MODE"; do
  wait_screen "$p" "❯" >/dev/null || bad "pane $p never showed a ❯ prompt"
done
for p in "$P_CX" "$P_CXB" "$P_P1" "$P_P1B" "$P_SW1" "$P_SW1F" "$P_STUCK" "$P_FOREIGN" "$P_TTL" "$P_FILE" "$P_SLOW" "$P_MARGIN" "$P_MARGINB"; do
  wait_screen "$p" "›" >/dev/null || bad "pane $p never showed a › prompt"
done
wait_screen "$P_AWAIT" "draft in progress"
for p in "$P_USERLINE" "$P_USERSLASH" "$P_USERBUSY" "$P_TIGHT" "$P_TIGHTUSER" "$P_GT" "$P_GTUSER" "$P_VIEWT" "$P_VIEWS"; do
  wait_screen "$p" "? for shortcuts" >/dev/null || bad "pane $p never showed a Claude footer"
done
for p in "$P_P1GT" "$P_P1VIEW" "$P_GTP1IDLE"; do
  wait_screen "$p" "⏎" >/dev/null || bad "pane $p never showed a p1 footer"
done
wait_screen "$P_STUCK2" "›" >/dev/null || bad "pane $P_STUCK2 never showed a › prompt"
sleep 0.5

section "tmux-panes: live classification (PS1 bash panes + fake TUIs), dead flag"
"$BIN/tmux-panes" --json >"$WORK/panes.json"; RC=$?
check "tmux-panes --json exits 0" test "$RC" = 0
for spec in ps1-claude:claude ps1-p1:p1 ps1-codex:codex ps1-shell:shell claude1:claude codex1:codex p1a:p1; do
  w=${spec%%:*} h=${spec#*:}
  check "tmux-panes: $w → harness $h" test "$(json_field "$w" harness)" = "$h"
done
for spec in claude1:idle claudebusy:busy codex1:idle codexbusy:busy p1a:idle p1busy:busy ps1-shell:idle deadwin:dead; do
  w=${spec%%:*} s=${spec#*:}
  check "tmux-panes: $w → state $s" test "$(json_field "$w" state)" = "$s"
done
check "tmux-panes: deadwin dead flag true" test "$(json_field deadwin dead)" = True
check "tmux-panes: last line of claude1 is its footer" bash -c "[[ '$(json_field claude1 last)' == *'fake-opus'* ]]"
TABLE="$("$BIN/tmux-panes")"
check "tmux-panes table has header + one row per pane" \
  test "$(wc -l <<<"$TABLE")" -eq "$(($(T list-panes -a | wc -l) + 1))"
grep -E '^ID|ps1-codex|deadwin' <<<"$TABLE" | sed 's/^/      /'

section "delivery + verification"
MSG='hello from test; $HOME #{pane_id} "dq" '"'sq'"' back\slash ending;'
send "$P_CL" "$MSG"
check "claude fake: exit 0 delivered" rc_is 0
check "claude fake: message arrived byte-exact (incl. trailing ;)" log_has claude1 "SUBMIT	$MSG"
check "claude fake: exactly one submit, first Enter sufficed" out_has "after 1 Enter(s)"
UTF='Grüße ❯ › 日本語 — ok'
send claude1 "$UTF"
check "claude fake: UTF-8 message delivered exact (by window name)" log_has claude1 "SUBMIT	$UTF"
send "$P_CX" -- "-starts with a dash"
check "codex fake: text after -- starting with '-' delivered" log_has codex1 "SUBMIT	-starts with a dash"
send "$P_CX" - <<<$'line one\nline two'
check "codex fake: stdin multi-line text flattened to one line" log_has codex1 "SUBMIT	line one line two"
send "$P_CL_PS1" ": tmux-comms-ps1-ok"
check "PS1 ❯ bash pane: exit 0" rc_is 0
check "PS1 ❯ bash pane: line was submitted to bash" screen_has "$P_CL_PS1" "❯ : tmux-comms-ps1-ok"
check "never sent ESC/C-u/C-c/C-w to claude1 or codex1" bash -c "! grep -q '^KEY' '$WORK/claude1.log' '$WORK/codex1.log'"
send "$P_CLB" "note while you are busy"
check "busy claude fake: delivered (queued by harness) exit 0" rc_is 0
check "busy claude fake: submitted" log_has claudebusy "SUBMIT	note while you are busy"

section "p1: second-Enter path, steering, unsent"
send "$P_SW1" "please pick up task 7"
check "p1 swallowing first Enter: exit 0" rc_is 0
check "p1 swallowing first Enter: second Enter was pressed" out_has "pressing Enter once more"
check "p1 swallowing first Enter: exactly 1 swallowed + 1 submit" bash -c "grep -c '^SWALLOW' '$WORK/p1swallow.log' | grep -qx 1 && grep -qxF 'SUBMIT	please pick up task 7' '$WORK/p1swallow.log'"
send "$P_SW1F" "forced second enter" --force-second-enter
check "--force-second-enter: exit 0 and submitted" bash -c "[[ $RC == 0 ]] && grep -qxF 'SUBMIT	forced second enter' '$WORK/p1force.log'"
send "$P_P1B" "steer: also run the linter"
check "p1 busy: exit 0" rc_is 0
check "p1 busy: reported as queued steering" out_has "queued as steering"
check "p1 busy: harness received steering" log_has p1busy "STEER	steer: also run the linter"
send "$P_P1" "plain p1 message"
check "p1 idle: delivered" log_has p1a "SUBMIT	plain p1 message"
send "$P_SLOW" "slow submit please"
check "p1 slow redraw (text lingers 5 s after submit): exit 0, not UNSENT" rc_is 0
check "p1 slow redraw: last line says DELIVERED" bash -c "[[ \"$(word)\" == DELIVERED ]]"
check "p1 slow redraw: reports the slow submit" out_has "slow submit"
check "p1 slow redraw: exactly one submit, no duplicate" bash -c "[[ \$(grep -c '^SUBMIT' '$WORK/p1slow.log') == 1 ]]"
printf 'seam reply: item 10 is #140, runs first in the queue under your conditions; details inside.\n' >"$WORK/margin-note.md"
send "$P_MARGIN" --file "$WORK/margin-note.md" --from alice
check "p1 with 4-col margin, wrapped --file pointer: exit 0" rc_is 0
check "p1 with 4-col margin: pointer submitted exactly once" bash -c "[[ \$(grep -c '^SUBMIT	\[from alice\] Message for you in' '$WORK/p1margin.log') == 1 ]]"
send "$P_MARGINB" "bob: your seam reply is in the inbox; the queue order is item 10 first, then item 11, then the dashboard shell; no reply needed"
check "busy p1 with 4-col margin, wrapped 160-char text: exit 0 queued" bash -c "[[ $RC == 0 ]] && [[ \"$(word)\" == QUEUED ]]"
check "busy p1 with margin: steering received once" bash -c "[[ \$(grep -c '^STEER' '$WORK/p1marginbusy.log') == 1 ]]"
send "$P_STUCK" "this will not submit"
check "Enter swallowed twice: exit 2 (queued-but-unsent)" rc_is 2
check "unsent: prints NOT submitted + pane tail" bash -c "grep -q 'NOT submitted' <<<\"\$0\" && grep -q '  | ' <<<\"\$0\"" "$OUT"
check "unsent: at most 2 Enters pressed, text left in composer (not cleared)" \
  bash -c "[[ \$(grep -c '^SWALLOW' '$WORK/codexstuck.log') == 2 ]] && ! grep -q '^KEY' '$WORK/codexstuck.log'"
check "unsent: composer still shows the text" screen_has "$P_STUCK" "› this will not submit"

section "refusal: foreign text in composer, copy mode, plain shell, dead pane"
send "$P_FOREIGN" "alice → please check"
check "foreign composer text: exit 3" rc_is 3
check "foreign composer text: says why" out_has "already holds text you did not type"
check "foreign composer text: the existing text is untouched, nothing typed" screen_has "$P_FOREIGN" "› What direct"
check "foreign composer text: no submit and no keys at all" bash -c "! grep -q . '$WORK/person.log' 2>/dev/null"
send "$P_RACE" "alice → please check"
check "someone types while we type (interleave): exit 2, Enter NOT pressed" \
  bash -c "[[ $RC == 2 ]] && ! grep -qs '^SUBMIT' '$WORK/race.log'"
check "interleave: says someone else typed, text left in place" out_has "someone else typed"
check "interleave: nothing cleared" screen_has "$P_RACE" "❯ What directalice"
T copy-mode -t "$P_MODE"
send "$P_MODE" "hi"
check "pane in copy mode: exit 3" rc_is 3
T send-keys -t "$P_MODE" -X cancel
send "$P_SH_PS1" "echo hi"
check "plain shell target: exit 3 without --allow-shell" rc_is 3
send "$P_DEAD" "anyone there?"
check "dead pane: exit 4" rc_is 4
check "dead pane: suggests respawn-pane" out_has "respawn-pane"

section "target resolution"
T set-option -p -t "$P_LAB" @pane-label alpha
T select-pane -t "$P_TTL" -T beta-title
T set-option -p -t "$P_DUP1" @pane-label dup
T set-option -p -t "$P_DUP2" @pane-label dup
check "resolve @pane-label alpha → $P_LAB" test "$(python3 "$BIN/tmux-comms-lib.py" resolve alpha)" = "$P_LAB"
send alpha "via label"
check "send by @pane-label: delivered to the labelled pane" log_has labelled "SUBMIT	via label"
send beta-title "via title"
check "send by pane_title: delivered" log_has titled "SUBMIT	via title"
send "t:codex1" "via tmux target"
check "send by sess:window target: delivered" log_has codex1 "SUBMIT	via tmux target"
send no-such-label "x"
check "unknown label: exit 4" rc_is 4
send dup "x"
check "ambiguous label: exit 4, nothing typed" bash -c "[[ $RC == 4 ]] && ! grep -q . '$WORK/dup1.log' '$WORK/dup2.log' 2>/dev/null"
send "%9999" "x"
check "unknown pane id: exit 4" rc_is 4

section "long message → inbox file + one-line pointer"
LONG="$(printf 'long-body-%04d ' $(seq 1 60))END"
send "$P_LONG" "$LONG" --from tester --topic review
check "long message: exit 0" rc_is 0
INBOXFILE="$(compgen -G "$TMUX_COMMS_INBOX/tester-to-longmsg-review-*.md" | head -1)"
check "long message: inbox file tester-to-longmsg-review-<YYYYmmdd-HHMM>.md created" \
  bash -c "[[ '$INBOXFILE' =~ /tester-to-longmsg-review-[0-9]{8}-[0-9]{4}\\.md\$ ]]"
check "long message: inbox file holds the full body" grep -qF -- "$LONG" "$INBOXFILE"
check "long message: pane got a single short pointer naming the file" \
  bash -c "grep '^SUBMIT' '$WORK/longmsg.log' | grep -qF '$INBOXFILE' && [[ \$(grep -c '^SUBMIT' '$WORK/longmsg.log') == 1 ]] && [[ \$(grep '^SUBMIT' '$WORK/longmsg.log' | wc -c) -lt 300 ]]"
send "$P_FILE" "short but explicit" --file "$WORK/explicit.md" --from alice
check "--file F <text>: body written to F, pointer delivered" \
  bash -c "grep -qF 'short but explicit' '$WORK/explicit.md' && grep -qF 'SUBMIT	[from alice] Message for you in $WORK/explicit.md' '$WORK/filemsg.log'"
send "$P_FILE" --file "$WORK/explicit.md" --from alice
check "--file F without text: pointer to existing file delivered" \
  bash -c "[[ $RC == 0 ]] && [[ \$(grep -c 'explicit.md' '$WORK/filemsg.log') == 2 ]]"

section "default inbox path (TMUX_COMMS_INBOX unset)"
P_DEFINBOX=$(fake definbox claude)
wait_screen "$P_DEFINBOX" "❯" >/dev/null || bad "pane $P_DEFINBOX never showed a ❯ prompt"
DEFLONG="$(printf 'default-inbox-%04d ' $(seq 1 60))END"
OUT="$(env -u TMUX_COMMS_INBOX "$BIN/tmux-send" "$P_DEFINBOX" "$DEFLONG" --from tester 2>&1)"; RC=$?
check "default inbox: exit 0" rc_is 0
check "default inbox: file under \$XDG_STATE_HOME/tmux-comms/inbox" \
  bash -c "compgen -G '$XDG_STATE_HOME/tmux-comms/inbox/tester-to-definbox-*.md' >/dev/null"
check "default inbox: pointer names that file" \
  bash -c "grep '^SUBMIT' '$WORK/definbox.log' | grep -qF '$XDG_STATE_HOME/tmux-comms/inbox/tester-to-definbox-'"

section "tmux-await"
OUT="$("$BIN/tmux-await" "$P_FOREIGN" --empty --timeout 1 2>&1)"; RC=$?
check "await --empty on an occupied composer times out (exit 1)" rc_is 1
OUT="$("$BIN/tmux-await" awaiter --empty --timeout 15 2>&1)"; RC=$?
check "await --empty returns 0 once the prefill was submitted elsewhere" rc_is 0
OUT="$("$BIN/tmux-await" claudebusy --idle --timeout 1 2>&1)"; RC=$?
check "await --idle on a busy pane times out (exit 1)" rc_is 1
OUT="$("$BIN/tmux-await" claude1 --idle --timeout 5 2>&1)"; RC=$?
check "await --idle on an idle pane: exit 0" rc_is 0
OUT="$("$BIN/tmux-await" deadwin --timeout 2 2>&1)"; RC=$?
check "await on a dead pane: exit 4" rc_is 4

section "live-defect regressions (found using the tools in practice)"
LIVE='all sessions: typed text is not sent until the composer is empty — verify with capture-pane before and after pressing Enter, and use tmux-send which does both steps for you; report the outcome word back.'

# defect 1: never type after text that is already in the composer
for spec in "userline:$P_USERLINE" "userslash:$P_USERSLASH" "userbusy:$P_USERBUSY" "tightuser:$P_TIGHTUSER" "gtglyphuser:$P_GTUSER"; do
  w=${spec%%:*} p=${spec#*:}
  send "$p" "alice → please check"
  check "defect 1: $w holds unsent text → REFUSED (exit 3)" \
    bash -c "[[ $RC == 3 ]] && [[ \"$(word)\" == REFUSED ]]"
  check "defect 1: $w — nothing typed, that text left alone" bash -c "! grep -qs . '$WORK/$w.log'"
done
check "defect 1: refusal names the existing composer text" out_has "already holds text you did not type"

# odd-but-real prompt glyphs must be understood, not treated as 'no prompt'
send "$P_TIGHT" "tight glyph delivery"
check "defect 1/3: '❯text' (no gap) composer delivered" bash -c "[[ $(word) == DELIVERED ]] && grep -qxF 'SUBMIT	tight glyph delivery' '$WORK/tight.log'"
send "$P_GT" "bare gt glyph delivery"
check "defect 1/3: '> text' composer delivered" bash -c "[[ $(word) == DELIVERED ]] && grep -qxF 'SUBMIT	bare gt glyph delivery' '$WORK/gtglyph.log'"
send "$P_GTP1IDLE" "gt glyph on a p1 pane"
check "defect 3: '>' glyph + '⏎ send' footer is classified p1, delivered" \
  bash -c "[[ $(word) == DELIVERED ]] && grep -qxF 'SUBMIT	gt glyph on a p1 pane' '$WORK/gtglyphidle.log'"
send "$P_P1GT" "gt glyph steering"
check "defect 3: '>' glyph p1 busy pane → QUEUED, not NOPROMPT" \
  bash -c "[[ $(word) == QUEUED ]] && grep -qxF 'STEER	gt glyph steering' '$WORK/p1gtglyph.log'"
"$BIN/tmux-panes" --json >"$WORK/panes.json"
check "defect 3: tmux-panes calls the '>' p1 panes p1 (footer honoured)" \
  bash -c "[[ $(json_field p1gtglyph harness) == p1 ]] && [[ $(json_field gtglyphidle harness) == p1 ]] && [[ $(json_field p1gtglyph state) == busy ]]"

# defect 2: a long message that wraps / scrolls must still be recognised as typed
send "$P_VIEWT" "$LIVE"
check "defect 2: message visible only as its tail (scrolled) → DELIVERED, not UNSENT" \
  bash -c "[[ $(word) == DELIVERED ]] && grep -qxF 'SUBMIT	$LIVE' '$WORK/viewtail.log'"
send "$P_VIEWS" "$LIVE"
check "defect 2: message visible only as a middle slice → DELIVERED, not UNSENT" \
  bash -c "[[ $(word) == DELIVERED ]] && grep -qxF 'SUBMIT	$LIVE' '$WORK/viewslice.log'"
send "$P_P1VIEW" "$LIVE"
check "defect 2: same on a p1 pane → QUEUED, message not left unsent" \
  bash -c "[[ $(word) == QUEUED ]] && grep -qxF 'STEER	$LIVE' '$WORK/p1viewtail.log'"
send "$P_CL" "$LIVE"
check "defect 2: long un-wrapped message still delivered byte-exact" \
  bash -c "[[ $(word) == DELIVERED ]] && grep -qxF 'SUBMIT	$LIVE' '$WORK/claude1.log'"

# defect 4: the outcome word is the first token of the LAST line
send "$P_STUCK2" "left in the composer"
check "defect 4: unsent broadcast → last line starts with UNSENT" \
  bash -c "[[ $RC == 2 ]] && [[ $(word) == UNSENT ]]"
send "$P_CL" "delivered word"
check "defect 4: delivered → last line starts with DELIVERED" test "$(word)" = DELIVERED
send "$P_P1B" "queued word"
check "defect 4: p1 steering → last line starts with QUEUED" test "$(word)" = QUEUED
send nope-no-such-pane "x"
check "defect 4: unknown pane → last line starts with NOPANE (exit 4)" bash -c "[[ $RC == 4 ]] && [[ $(word) == NOPANE ]]"

section "Claude Code full-screen view and dim prompt suggestion"
P_VIEW=$(fake viewer claude --view)
P_DIM=$(fake dimsugg claude "--dim-suggestion 'run the tests'")
P_DIMMIX=$(fake dimmixed claude "--prefill '/sta' --dim-suggestion 'tus'")
wait_screen "$P_VIEW" "esc back" >/dev/null || bad "pane $P_VIEW never showed its view footer"
for p in "$P_DIM" "$P_DIMMIX"; do
  wait_screen "$p" "? for shortcuts" >/dev/null || bad "pane $p never showed a Claude footer"
done
"$BIN/tmux-panes" --json >"$WORK/panes.json"
check "tmux-panes: full-screen view → claude busy, composer view" \
  bash -c "[[ $(json_field viewer harness)/$(json_field viewer state)/$(json_field viewer composer) == claude/busy/view ]]"
check "tmux-panes: dim suggestion alone → composer empty; typed text before it → text" \
  bash -c "[[ $(json_field dimsugg composer)/$(json_field dimmixed composer) == empty/text ]]"
OUT="$("$BIN/tmux-await" viewer --empty --timeout 1 2>&1)"; RC=$?
check "await --empty on a full-screen view times out (exit 1)" rc_is 1
OUT="$("$BIN/tmux-await" dimsugg --empty --timeout 5 2>&1)"; RC=$?
check "await --empty on a composer showing only a dim suggestion: exit 0" rc_is 0
send "$P_VIEW" "alice → please check"
check "full-screen view → REFUSED (exit 3)" bash -c "[[ $RC == 3 ]] && [[ \"$(word)\" == REFUSED ]]"
check "full-screen view: tells the caller to wait with tmux-await --empty" out_has "tmux-await $P_VIEW --empty"
check "full-screen view: not a single key reached the view" bash -c "! grep -qs . '$WORK/viewer.log'"
send "$P_DIM" "dim suggestion is not text"
check "dim suggestion alone: DELIVERED byte-exact" \
  bash -c "[[ $RC == 0 ]] && [[ \"$(word)\" == DELIVERED ]] && grep -qxF 'SUBMIT	dim suggestion is not text' '$WORK/dimsugg.log'"
send "$P_DIMMIX" "alice → please check"
check "typed text followed by a dim completion → REFUSED, nothing typed" \
  bash -c "[[ $RC == 3 ]] && [[ \"$(word)\" == REFUSED ]] && ! grep -qs . '$WORK/dimmixed.log'"

section "isolation"
check "no fake harness ever received ESC / C-u / C-c / C-w" bash -c "! cat '$WORK'/*.log | grep -q '^KEY'"
check "tools never addressed a tmux server other than $SOCK" test ! -s "$WORK/shim-violations.log"
# Second, weaker signal: a server of yours should look the same before and after the run. On a
# machine where somebody else is working in tmux, panes appear and their commands change during
# these three minutes, so a difference is reported as SKIP with the delta rather than as a
# failure — the shim check above is the one that attributes changes to the tools.
if ! "$REAL_TMUX" list-panes -a >/dev/null 2>&1; then
  echo "SKIP  the machine's own tmux server: none is running, so there is nothing to compare"
elif [[ "$(real_panes)" == "$REAL_BEFORE" ]]; then
  ok "the machine's own tmux server is unchanged"
else
  echo "SKIP  the machine's own tmux server changed while the suite ran: another process is using"
  echo "      it, so the difference cannot be attributed to the tools. Delta (before/after):"
  diff <(printf '%s\n' "$REAL_BEFORE") <(printf '%s\n' "$(real_panes)") | sed 's/^/      /'
fi

echo
echo "RESULT: $pass passed, $fail failed"
((fail == 0))
