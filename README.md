# tmux-comms

Three commands for sending text to a tmux pane that runs an interactive agent CLI (Claude Code,
Codex CLI, or anything else whose composer the classifier recognises), and for checking that the
text was actually submitted:

| command | what it does |
|---|---|
| `tmux-panes` | list every pane: id, window, label, harness, idle/busy/dead, current command, last line (`--json` for scripts) |
| `tmux-send` | type a message into another pane, confirm it is visible in the composer, press Enter, confirm the composer is empty again |
| `tmux-await` | wait, read-only, until a pane's composer is empty (`--empty`, default) or the pane is idle (`--idle`) |

Typing into a pane by hand is a blind `send-keys`: the keypress may land in a composer that already
holds someone else's draft, in a pane that is scrolling (copy mode), or in a shell where the text
runs as a command. `tmux-send` classifies the target first, refuses instead of guessing, and reports
one outcome word (`DELIVERED`, `QUEUED`, `UNSENT`, `REFUSED`, `NOPANE`) as the last line of stdout.
`tmux-send` never sends Escape, `C-u` or `C-c`, never clears another pane's input, and never kills,
respawns or creates panes.

The classifier is a text match over `tmux capture-pane -p -J -t PANE` (`bin/tmux-comms-lib.py`).
It knows the composer glyph and placeholder of Claude Code (`❯`), Codex CLI (`›`) and one more
TUI called p1 (`›`, footer `⏎ send`); other TUIs are reported as `unknown` and refused.
Every classification case is pinned by a fixture file in `tests/fixtures/`, so a UI change shows
up as a failing test rather than as a silent mis-send.

## Requirements

* `tmux` 3.0 or newer on the machine that runs the panes.
* `python3` 3.7 or newer (standard library only; nothing to `pip install`).
* `bash` 4 or newer for the three commands.
* Optional: `shellcheck`, used by the test suite when present (skipped otherwise).

Debian/Ubuntu: `apt-get install tmux python3` (plus `shellcheck` for the tests).
macOS (Homebrew): `brew install tmux python3`.

## Install

```sh
git clone https://github.com/5omeOtherGuy/tmux-comms tmux-comms
install -m 0755 tmux-comms/bin/tmux-send tmux-comms/bin/tmux-panes \
  tmux-comms/bin/tmux-await tmux-comms/bin/tmux-comms-lib.py ~/.local/bin/
```

`tmux-comms-lib.py` must sit next to the three commands (they find it via `$BASH_SOURCE`), and
`~/.local/bin` must be on `PATH`. Nothing else is installed; there is no config file.

## Worked example

The repository ships a fake agent TUI, so the whole flow can be tried without Claude Code or Codex.
Start it in a pane of its own tmux server and label the pane:

```sh
$ tmux -L demo new-session -d -P -F '#{pane_id}' -s demo \
    'python3 tests/fake-harness.py --kind claude --log /tmp/demo.log'
%0
$ tmux -L demo set-option -p -t %0 @pane-label worker
```

Then, in another shell (`TMUX_COMMS_SOCKET` points every command at that server):

```sh
$ export TMUX_COMMS_SOCKET=demo
$ tmux-panes
ID  WINDOW    LABEL   HARNESS  STATE  DEAD  CMD      LAST
%0  demo:1()  worker  claude   idle   0     python3  ? for shortcuts fake-opus

$ tmux-await worker --empty --timeout 10
tmux-await: %0 (claude) is empty                         # exit 0

$ tmux-send worker "run the tests and report the exit code"
DELIVERED %0 (claude, was idle) after 1 Enter(s)         # exit 0

$ tail -1 /tmp/demo.log
SUBMIT	run the tests and report the exit code
```

(`tests/fake-harness.py` writes its log line when it handles the message, so the file appears at
that point.) The same three commands target a real agent pane: give the pane a label with
`tmux set-option -p -t "$TMUX_PANE" @pane-label <name>` and send to that name.

Without `--pane-label`, a target may be a pane id (`%12`), a `pane_title`, a window name, or a tmux
target (`sess:win.pane`). Label and title matches must be unique; an ambiguous name is exit 4 and
nothing is typed. When the target is refused, the reason is on stderr: a composer that already holds
text, a full-screen view, copy mode, a plain shell (needs `--allow-shell`, the text then *runs as a
command*), an unrecognisable TUI, a dead pane, or the pane you are typing from.

## Configuration

Environment variables (all optional):

| variable | default | meaning |
|---|---|---|
| `TMUX_COMMS_SOCKET` | tmux's default server | server name, passed as `tmux -L NAME` |
| `TMUX_COMMS_INBOX` | `$XDG_STATE_HOME/tmux-comms/inbox`, i.e. `~/.local/state/tmux-comms/inbox` | where messages longer than 600 characters (or `--file` messages) are written before a pointer line is sent |
| `TMUX_COMMS_FROM` | own `@pane-label`, else `$USER` | sender name used in inbox file names (`--from` overrides it) |
| `TMUX_COMMS_SETTLE` | `1.5` | seconds to wait after typing before looking at the composer |
| `TMUX_COMMS_ENTER_WAIT` | `2` | seconds to wait after Enter before checking whether it submitted |
| `TMUX_COMMS_GRACE` | `8` | seconds to keep re-checking a slow redraw before reporting `UNSENT` |

Tmux pane options, set by you:

* `@pane-label` — name this pane (also useful as a target). Names must be unique.
* `@harness claude|codex|p1` — force the classification of a pane when the automatic match fails.

```sh
tmux set-option -p -t "$TMUX_PANE" @pane-label worker
tmux set-option -p -t %12 @harness codex
```

## Outcomes and exit codes

`tmux-send` prints human-readable lines on stderr and, as the **last** line of stdout, the outcome
whose first word is `DELIVERED`, `QUEUED`, `UNSENT`, `REFUSED`, `NOPANE` or `USAGE`. The outcome line
never contains pane text, so it is safe to log.

| exit | meaning | what to do |
|---|---|---|
| 0 | delivered, or queued as steering in a busy p1 pane | record the outcome; the recipient acknowledging is separate |
| 1 | usage or file error | fix the arguments; do not resend blindly |
| 2 | text may have been typed but submission is unconfirmed | do not resend and do not press Enter yourself; check with `tmux-await <pane> --empty` |
| 3 | refused before typing (composer not empty, full-screen view, copy mode, plain shell, unknown TUI, own pane) | resolve the reported condition, then retry; never force. For a composer that holds text or a full-screen view, wait with `tmux-await <pane> --empty` |
| 4 | no such pane, ambiguous name, dead pane, or typing failed | rediscover the pane; partial typing is possible, so do not resend blindly |

`tmux-await` exits 0 when the condition is met, 1 on timeout (it prints the reason and a short tail),
4 when the pane does not exist or is dead. A timeout authorises nothing by itself.

Sequence: capture the pane, classify the UI, refuse if the composer is not empty, type the text
literally (`send-keys -l`) in chunks of at most 500 characters — never in the same call as Enter —
confirm the text is visible, press `C-m`, wait, confirm the composer is empty, press `C-m` once more
if the first Enter was swallowed, then keep polling for up to `TMUX_COMMS_GRACE` seconds before
reporting `UNSENT`. Newlines in the message are flattened to spaces; for multi-line or code-bearing
text, write a file and send `--file F`, which types a one-line pointer instead.

## Recognised UIs

Read from `tmux capture-pane -p -J -t PANE`:

| harness | empty composer | busy marker |
|---|---|---|
| Claude Code | `❯ ` alone between `───` rules; `Try "..."` placeholders and a dim (SGR 2) prompt suggestion count as empty | spinner line above (`✻ … (esc to interrupt)`); a full-screen view (below) |
| Codex CLI | `› Ask Codex to do anything` | `• Working (… esc to interrupt)`, or `esc to interrupt` |
| p1 TUI | `› message, / for commands`, footer `⏎ send` | `› steer the running turn`, `⏎ queue steering`; Enter then queues steering (`· steering`) |
| shell | `$ ` or `# ` prompt | not a shell (`#{pane_current_command}`) |
| dead | `#{pane_dead}` = 1 | — |

A left margin (the p1 TUI draws four columns in), a missing space after the glyph (`❯text`), box
edges, and wrapped or scrolled composer text are all handled. A bare `>` is only read as a prompt
when the pane shows other TUI evidence (footer, placeholder or `@harness`), so a quoted line in a
transcript is not mistaken for a composer. The newer Claude Code footer (`… · Context 41% · …`)
counts as TUI evidence and ends the composer region like the older footers.

Claude Code's full-screen views (the `/workflows` viewer, the agents viewer, task lists) show a
key-command footer instead of a composer, with hints such as `esc back`, `x stop workflow`,
`↑↓ select ·`, `↑↓ agent ·`, `j/k scroll` or `⏎ collapse`. Typed characters are commands there, so
such a pane is reported as busy with composer `view` (harness `claude`, or the `@harness` override)
and `tmux-send` refuses it with exit 3 until the view is closed.

A plain capture cannot tell Claude Code's dim prompt suggestion from typed text. When a Claude
composer seems to hold text, the pane is captured once more with its attributes
(`capture-pane -p -e -J`); if everything in the composer is dim text on the prompt line, the
composer counts as empty.

## Limits and caveats

* Classification is a heuristic over rendered text. A UI redesign (new glyph, new placeholder, new
  footer) can make a pane `unknown`; the tool then refuses instead of typing. Update
  `tests/fixtures/` for the new rendering when that happens.
* Only the three UIs above are known. Anything else needs a fixture and probably a rule.
* "Delivered" means "the text left the composer after Enter" — the recipient application may still
  be thinking, or may have queued the message. `tmux-send` cannot read the application's state.
* Long messages are typed in 500-character chunks with 0.2 s between them; a very long message
  therefore takes seconds to type and the Enter waits for the last chunk.
* The tool refuses to touch a pane whose composer it cannot locate, and never clears text it did not
  type. If it reports exit 2, text you typed may still be sitting in the other pane's composer —
  leave it and check.
* `--no-verify`, `--force-second-enter` and `--allow-shell` exist for manual recovery and for
  panes you own; they weaken the checks.
* Developed and tested on Linux with GNU coreutils and on tmux 3.7; no Windows support.
* Not a session or worktree manager: it does not create, arrange or kill anything.

## Tests

```sh
bash tests/run-tests.sh
```

Needs `tmux` and `python3` (and `shellcheck` for the lint check; without it that check prints
`SKIP`). It takes about three minutes, most of it deliberate sleeps. The suite:

* runs against a private server (`tmux -L tmuxcomms-test`) and installs a `tmux` shim on `PATH`
  that makes any call to another server fail loudly, so the machine's own tmux server is untouched;
  a before/after snapshot of that server is compared as a second signal and prints `SKIP` (with the
  delta) when no server of yours is running or another process changes it during the run;
* points `HOME` and `XDG_STATE_HOME` into a fresh temp directory and sets its own
  `TMUX_COMMS_INBOX`, so nothing is written to your account;
* classifies the static fixtures in `tests/fixtures/` against `tests/fixtures/expected.tsv`;
* drives a live fake TUI (`tests/fake-harness.py`) through delivery, refusal, steering (queueing),
  a swallowed Enter, a slow redraw, copy mode, dead panes, ambiguous labels and the default inbox
  path;
* reads the tool sources to assert that every `send-keys` is literal text or `C-m`, and that no
  tool ever kills or respawns anything.

A failure keeps the temp work directory and prints its path. On a failure, read the `FAIL` line:
`got X want Y` names the field that changed.

## Secret scan and git hook

`tools/secret-scan.sh` refuses a tree that contains credential-looking strings (API keys, tokens,
private keys, `Bearer` headers, JWTs) or forbidden file names (`*.key`, `*.pem`, `auth.json`, …).
Exit 0 is clean, 1 is a hit, 2 is a scanner error.

```sh
tools/secret-scan.sh              # scan the working tree
tools/install-git-hooks.sh        # install tools/hooks/pre-push as .git/hooks/pre-push
```

With the hook installed, every `git push` scans each outgoing commit's patch and file names and
refuses on a hit or a scanner error (it fails closed). `.github/workflows/ci.yml` runs the scan and
the test suite on every push.

## License

MIT — see `LICENSE`.
