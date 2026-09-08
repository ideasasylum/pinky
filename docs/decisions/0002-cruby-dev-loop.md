# 0002 The same Ruby runs on CRuby and Spinel; develop on CRuby, ship the Spinel binary

Date: 2026-09-08. Status: accepted.

## Context

Spinel compiles whole programs only; there is no incremental mode and no backtraces. CRuby gives instant
feedback and real stack traces but cannot produce the single binary. Melee proved the two can share one
codebase when native pieces have two backends.

## Decision

Every file under `pinky/` runs under both runtimes. The native boundary is one module, `Pinky::DBBackend`,
implemented twice: `pinky/db_backend.rb` (Spinel FFI to the carried SQLite amalgamation and sqlite-vec)
and `cruby/pinky/db_backend.rb` (the `sqlite3` gem plus sqlite-vec as a loadable extension). The CRuby
backend wins by load path (`ruby -I cruby -I .`), because `defined?` is resolved statically under Spinel.

Tests are programs that print observations. `test/run.sh` runs each under CRuby and as a Spinel binary and
diffs the output; any difference fails.

## Consequences

- Floats are never printed raw in tests (formatting can differ); they are rounded to integers first.
- Dialect drift (code that runs on CRuby but fails Spinel inference) is caught by the parity run, which is
  therefore part of `scripts/check.sh` and must stay fast.
- Frozen string literals are on everywhere so CRuby behaves like Spinel.
