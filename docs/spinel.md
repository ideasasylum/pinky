# Spinel: rules that keep pinky compiling

Pinned at `b2cbeba390764bc7c395800672f1228043e9e940` (ADR 0001). The full trap list with reproducers is
melee's `docs/research/spinel.md` (`/Users/jamie/orca/workspaces/chips/spike`); this file is the subset that
shapes pinky, plus what pinky found itself. Update it whenever a parity test fails for a dialect reason.

## Dialect

- String literals are frozen, always. Build strings with `+""` and `<<`.
- Never return a NUL-containing String from a method; it loses its length. Binary never lives in a Ruby
  String at all: vectors go to C as `:float_array` and are converted to float32 in the shim.
- Keep IO, String, Proc and pointer values in statically typed locals. Do not put them in polymorphic
  containers, do not seed an array with `nil` to type it, do not bind the same variable name in two
  `rescue` clauses with different classes.
- An empty `[]` is an int array. Seed arrays that will hold objects, or use a Hash.
- An empty `{}` in a ternary (`x = cond ? {} : typed_hash_method`) is typed on its own, not unified with
  the other branch; hash writes later in the method then call the wrong specialised setter and segfault
  (`sp_StrIntHash_set` with a null key). Write `x = {}` and then `x = typed_hash_method unless cond`.
- A frozen Hash literal constant with String keys and Integer values (`{ "a" => 0 }.freeze`) crashed at
  load in one build; a `case` method is the safe form for small lookup tables.
- Do not call a yielding method on a constant receiver (`DB.transaction do` fails; `db.transaction do` on
  a local or method result works). Do not nest a yielding call inside another block when it can be avoided.
- `IO#read(n)` may return fewer than `n` bytes: loop. Set `io.sync = true` on sockets and `$stdout`.
- `defined?` is static; backend selection is by load path, never by `defined?`.
- Multiple assignment from a method with an unknown return type fails; `names, rows = Backend.query(...)`
  is fine because the return is a literal two-element array in both backends.
- `require` everything a file uses; with `--require-gate` a missing require is an opaque "unsupported call".
- A compile error inside a required file makes the gate report "'pinky' is not available in Spinel; the
  require is ignored" as a *warning*, the compile exits 0, and the binary segfaults at start. `test/run.sh`
  greps for that warning. To find the real error compile a one-liner that requires each file in turn.
- Comparing an Integer or String with a method result on a duck-typed receiver (`meta(...).to_i != @embedder.dim`)
  is "unsupported equality"; narrow both sides with `.to_s` first.
- No `eval`, `define_method` with computed names, `method_missing`, `send` with dynamic names, `ObjectSpace`,
  ERB, or gems. We do not link `openssl` or `net/http`, which avoids the polymorphic-IO dispatch bugs.
- `Exception#backtrace` is `[]`: run the failing test under CRuby for the trace.
- A NUL byte inside a source file makes the parse fail with "unterminated string meets end of file",
  reported against the *requiring* file; CRuby tolerates the same bytes silently. When a parse error makes
  no sense, `grep -rlP '\x00' --include='*.rb' .` first. `spinel --dump-ast <file>` parses one file on its
  own and is the quickest way to find which file is at fault. (Backticks in regexes, lookbehind, `$1`,
  `Regexp.last_match` and interpolated regex literals all parse and run fine.)
- Missing methods met so far: `Integer#chr("UTF-8")` (compile error; use `[cp].pack("U")`),
  `String#each_codepoint` (compiles, raises at run time; use `codepoints.each`), `String#each_line` on a
  String that came out of a Hash (raises at run time; use `split("\n")`). Spinel's `optparse` is a
  stub that only understands `--flag=VALUE`; `pinky/args.rb` replaces it.

## FFI and native code

- Any `.c` in the package is compiled by spin; `exclude` in `spin.toml` keeps the raw amalgamations out and
  `native/pinky_sqlite.c` / `native/pinky_vec.c` include them with the compile options set by `#define`,
  because `ffi_cflags` only reaches the generated translation unit.
- Every `.c` that includes `sqlite-vec.h` defines `SQLITE_CORE` first, or the SDK's `sqlite3ext.h` is
  pulled in and clashes with the amalgamation's `sqlite3.h`.
- `:str` results stop at the first NUL; `:binstr` is return-only and binary safe.
- `spinel --link` takes objects, `.a` archives and `-lLIB`; spin.toml also supports `[[build]]` steps and
  `[native] libs = [...]` for prebuilt archives (see Spinel's `test/spin_test.sh`). Not used yet; this is
  the path for llama.cpp later.

## Toolchain quirks

- `spinel -E` returns 0 even when the program dies; compile to a binary and run it.
- `spin flags` prints the flags to compile a file outside spin with the package's native objects linked.
- Native objects are cached in `$XDG_CACHE_HOME/spin/native` keyed by (package, version, toolchain); set
  `SPIN_NO_NATIVE_CACHE=1` when a native change does not seem to take effect.
- The CRuby loadable extension must be compiled against the amalgamation's `sqlite3ext.h` (`-I native`),
  not the SDK's, which omits the API redirects and produces a dylib that segfaults on load.
