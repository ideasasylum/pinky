#!/usr/bin/env bash
# All verification: ruby -wc, the sqlite-vec extension for CRuby, CRuby-vs-Spinel parity tests, the
# release build and its dynamic dependencies. Non-zero exit when anything fails.
set -uo pipefail
cd "$(dirname "$0")/.."
SPIN="${SPIN:-vendor/spinel/bin/spin}"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /' | head -30; }

echo "== ruby -wc =="
warnings=""
for f in pinky.rb pinky/*.rb cruby/pinky/*.rb bin/*.rb test/*.rb; do
  out=$(ruby -wc "$f" 2>&1) || { bad "ruby -wc $f" "$out"; continue; }
  w=$(printf '%s\n' "$out" | grep -v '^Syntax OK' || true)
  [ -n "$w" ] && warnings="$warnings$w"$'\n'
done
if [ -n "$warnings" ]; then bad "ruby -w warnings" "$warnings"; else ok "ruby -wc"; fi

echo "== sqlite-vec extension for CRuby =="
mkdir -p build
if [ ! -f build/vec0.dylib ] || [ native/sqlite-vec.c -nt build/vec0.dylib ]; then
  if out=$(cc -O2 -fPIC -dynamiclib -undefined dynamic_lookup -I native native/sqlite-vec.c -o build/vec0.dylib 2>&1); then ok "build/vec0.dylib"; else bad "build/vec0.dylib" "$out"; fi
else
  ok "build/vec0.dylib (cached)"
fi

echo "== parity tests =="
if [ -x "$SPIN" ]; then
  out=$(test/run.sh 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/     /'
  if [ $rc -eq 0 ]; then ok "test/run.sh"; else bad "test/run.sh"; fi
  echo "== release build =="
  if out=$("$SPIN" build 2>&1); then ok "spin build"; else bad "spin build" "$out"; fi
  if [ -x build/bin/brain ]; then
    libs=$(otool -L build/bin/brain | tail -n +2 | grep -v libSystem || true)
    if [ -z "$libs" ]; then ok "only libSystem linked"; else bad "unexpected dynamic libraries" "$libs"; fi
    echo "== web server end to end (compiled binary, real sockets) =="
    e2e_dir=$(mktemp -d "${TMPDIR:-/tmp}/pinky-e2e.XXXXXX")
    e2e_port=$((20000 + RANDOM % 20000))
    printf 'End-to-end fact about <sockets> & curl.\n' | PINKY_MODEL_DIR=/nonexistent build/bin/brain add --db "$e2e_dir/e2e.db" --project e2e --agent check --tags e2e >/dev/null
    PINKY_MODEL_DIR=/nonexistent build/bin/brain serve --db "$e2e_dir/e2e.db" --port "$e2e_port" 2>"$e2e_dir/server.log" &
    e2e_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$e2e_port/" 2>/dev/null && break; sleep 0.2; done
    home=$(curl -s -w '\n%{http_code}' "http://127.0.0.1:$e2e_port/?q=sockets")
    if printf '%s' "$home" | tail -n1 | grep -q '^200$' && printf '%s' "$home" | grep -q '&lt;sockets&gt;'; then ok "GET / search renders the fact"; else bad "GET / search" "$home"; fi
    show=$(curl -s -w '\n%{http_code}' "http://127.0.0.1:$e2e_port/facts/1")
    if printf '%s' "$show" | tail -n1 | grep -q '^200$'; then ok "GET /facts/1"; else bad "GET /facts/1" "$show"; fi
    api=$(curl -s "http://127.0.0.1:$e2e_port/api/facts?q=curl")
    if printf '%s' "$api" | grep -q '"project":"e2e"'; then ok "GET /api/facts"; else bad "GET /api/facts" "$api"; fi
    post=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data 'title=Posted&kind=note&tags=&body=Posted+body&project=e2e&agent=curl' "http://127.0.0.1:$e2e_port/facts")
    if [ "$post" = "303" ]; then ok "POST /facts creates and redirects"; else bad "POST /facts ($post)"; fi
    nf=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$e2e_port/nope")
    if [ "$nf" = "404" ]; then ok "404 for unknown path"; else bad "unknown path returned $nf"; fi
    kill "$e2e_pid" 2>/dev/null; wait "$e2e_pid" 2>/dev/null
    rm -rf "$e2e_dir"
  fi
else
  bad "spinel not built ($SPIN missing): run mise run spinel"
fi

echo "$pass ok, $fail failed"
[ $fail -eq 0 ]
