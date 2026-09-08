# 0004 The executable is `brain`; the project, paths and env vars stay `pinky`

Date: 2026-09-08. Status: accepted.

## Context

GNU coreutils ships a `pinky` command (a lightweight `finger`). On macOS with Homebrew's coreutils gnubin
on PATH, and on every Linux, `pinky` resolves to that tool. Hooks and skills have agents type the command in
ordinary shells, so an absolute path is not a fix.

## Decision

The binary is `bin/brain.rb`, compiled to `build/bin/brain` and installed as `brain`. The Ruby namespace
(`Pinky`), the data directory (`~/.pinky`), the environment variables (`PINKY_DB`, `PINKY_MODEL_DIR`,
`PINKY_PROJECT`, `PINKY_AGENT`) and the skill names (`/pinky-remember`, `/pinky-recall`) keep the project
name; only the thing typed in a shell changes.

## Consequences

- `brain install-hooks` writes `brain hook <event>` commands; `--bin PATH` overrides for unusual installs.
- Text that tells agents what to type (usage, hook context, skills, README) says `brain`; internal names
  say pinky. `grep -n 'pinky \(add\|search\|hook\)'` should stay empty.
