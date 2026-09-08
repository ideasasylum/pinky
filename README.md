# pinky

A local knowledge base for coding agents. Agents write short markdown facts (gotchas, decisions, tasks,
notes) tagged with the agent and project that produced them, and query them back by full-text and semantic
search. Everything runs on this machine: SQLite with FTS5 and sqlite-vec, static embeddings computed in
Ruby, one native binary compiled by [Spinel](https://github.com/matz/spinel). No cloud APIs.

Claude Code integration is through hooks (facts injected at session start and per prompt, a once-per-session
nudge to save learnings) and two skills, `/remember` and `/recall`. A small web UI browses and prunes the
base; an MCP server exposes the same store to other tools.

## Layout

| Path | What |
|---|---|
| `bin/pinky.rb` | the CLI entry point; `spin build` compiles it to `build/bin/brain` |
| `pinky.rb`, `pinky/` | the library; runs under CRuby and Spinel (ADR 0002) |
| `cruby/pinky/` | CRuby backends for the native pieces, used by the dev loop and tests |
| `native/` | SQLite amalgamation, sqlite-vec, and the C shim; compiled into the binary |
| `test/` | observation-print tests; `test/run.sh` diffs CRuby against the Spinel binary |
| `spike/` | throwaway probes, one directory each, with a `NOTES.md` |
| `docs/spinel.md` | the Spinel rules this code follows; `docs/decisions/` holds the ADRs |
| `vendor/spinel` | Spinel, pinned (ADR 0001) |

## Using it

The command is `brain` (GNU coreutils already owns `pinky`; ADR 0004). Data lives in `~/.pinky/`.

```sh
brain setup                        # ~/.pinky/pinky.db and the 30 MB embedding model (one-off download)
brain install-hooks                # hooks into ~/.claude/settings.json, skills into ~/.claude/skills
echo 'Spinel strings are frozen' | brain add --kind gotcha --tags spinel
brain search "immutable strings"   # hybrid search; --mode fts|vector, --project, --tag, --kind, --json
brain show 1 | brain list | brain rm 1 | brain restore 1 | brain doctor
```

Facts are tagged with the project (the repository name) and agent (`repo/branch`) of the working directory;
override with `--project`, `--agent`, or the `PINKY_PROJECT` / `PINKY_AGENT` environment variables.

In Claude Code the hooks inject the project's facts at session start, pull relevant facts in for each
substantial prompt, and, once per session, ask the model to save learnings before it finishes if the
session did real work and saved nothing.

`brain serve` opens the browsing and pruning UI on http://127.0.0.1:4242/ (search, filters, edit, archive,
bulk archive, JSON under `/api/facts`). `brain mcp` is an MCP server over stdio with the same operations as
tools plus one resource per project; register it with `claude mcp add --scope user pinky -- brain mcp`.

## Building

```sh
mise install            # ruby
mise run spinel         # builds vendor/spinel/bin/{spinel,spin}; needs clang
gem install sqlite3     # CRuby dev loop only
scripts/check.sh        # ruby -wc, CRuby+Spinel parity tests, release build, dependency check
vendor/spinel/bin/spin build && ./build/bin/brain doctor
```
