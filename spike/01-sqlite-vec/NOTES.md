# 01: SQLite + FTS5 + sqlite-vec under Spinel

Result (2026-09-08, Spinel b2cbeba, macOS arm64): works first time once the shim defines `SQLITE_CORE`.

- `native/pinky_sqlite.c` sets the SQLite compile options and `#include "sqlite3.c"`; `native/pinky_vec.c`
  defines `SQLITE_CORE` and `#include "sqlite-vec.c"`; the raw amalgamations are `exclude`d in `spin.toml`.
  This is the reliable way to pass `-D` flags to package C: `ffi_cflags` only reaches the generated
  translation unit, not spin's native compile.
- Every `.c` that includes `sqlite-vec.h` must define `SQLITE_CORE` first or it picks up the SDK's
  `sqlite3ext.h` and the two `sqlite3.h` headers clash.
- `sqlite3_vec_init(db, NULL, NULL)` per connection registers vec0 and the `vec_*` functions.
- `:float_array` + `:size_t` into a C shim that converts to float32 and `sqlite3_bind_blob`s with
  `SQLITE_TRANSIENT` is the path for vectors. No Ruby String ever holds binary.
- FTS5 `bm25` ranking, vec0 KNN with `k = ?`, and RRF via `FULL OUTER JOIN` all return the expected order.
- Binary: 1.6 MB, `otool -L` shows only `libSystem`. Native compile is ~19 s once (cached per package).
- For the CRuby dev loop the same `sqlite-vec.c` is built as a loadable extension. Two macOS traps: the
  SDK's `sqlite3ext.h` never defines the `sqlite3_api->` redirects (Apple builds with
  `SQLITE_OMIT_LOAD_EXTENSION`), so the dylib ends up with 74 direct `sqlite3_*` references and the
  sqlite3 gem segfaults on load; compile with `-I native` so the amalgamation's `sqlite3ext.h` is used, and
  add `-undefined dynamic_lookup` for the few remaining symbols.

Run: `SPIN=.../spin spin build && ./build/bin/vecprobe`.
