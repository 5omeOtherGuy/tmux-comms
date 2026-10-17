# AGENTS.md

## Profile
- Purpose: type messages into tmux panes running agent CLIs and verify they were submitted
- Stage: prototype (repository standard 2026-10-17)
- Gate: `scripts/gate` (CI job `gate`)
- Landing: direct to main after a green gate; agents land: yes
- Release: none; agents release: no
- Outside issues and PRs: agents triage; outside PRs merge: owner approves

No deliberate deviations from the standard.

## Map
- `bin/tmux-comms-lib.py`: pane resolution and the classifier (`classify_lines`,
  `classify_pane`); read-only towards tmux.
- `bin/tmux-send`, `bin/tmux-await`, `bin/tmux-panes`: the three commands; they find the library
  next to themselves.
- `tests/run-tests.sh`: the suite. `tests/fixtures/*.txt` with `tests/fixtures/expected.tsv` pin
  every classification case; `tests/fake-harness.py` is the fake agent TUI the live part drives.
- `tools/secret-scan.sh`: secret scan; `tools/hooks/pre-push` runs it on outgoing commits
  (install with `tools/install-git-hooks.sh`).
- `scripts/gate`: the gate. `.agents/setup`: orb setup.

## Landing (prototype)
Small commits straight to `main`, Conventional Commits subjects. Run `scripts/gate` before
pushing; push at the end of every session. Risky ideas go on `spike/<slug>` branches.

## Rules
- The tools must never type where keystrokes would do anything but add text: no Escape, `C-u`,
  `C-c`, no clearing another pane's input, no killing or respawning panes. The suite reads the
  sources to enforce this; do not weaken those checks.
- When the classifier refuses too much or too little, add a fixture and an `expected.tsv` row for
  the rendering first, then change the rule. Unknown screens are refused, never guessed.
- Tests run only against the private tmux server `tmuxcomms-test` and a temporary `HOME`; never
  point them at a real tmux server or a real agent CLI. Two runs of the suite at the same time
  share that server name and break each other.
- Keep the code site-independent: no personal paths, hostnames or names.
- Standard library only (Python), no new runtime dependencies.
- This repository is public: commits carry no personal email address, including in trailers.
  `.agents/setup` sets a repository-local `core.hooksPath` for that reason.

## Focused tests
- One fixture: `python3 bin/tmux-comms-lib.py classify-text --cmd node < tests/fixtures/<f>.txt`
  prints `harness state composer marker dead in_mode cmd text`, separated by `\x1f`
  (`| tr '\037' '|'` makes it readable); compare with the row in `expected.tsv`.
- The whole suite: `bash tests/run-tests.sh` (needs tmux, python3, shellcheck).
