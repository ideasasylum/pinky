#!/usr/bin/env bash
# Run every test under CRuby and as a Spinel binary; outputs must match.
# Usage: test/run.sh [test_name...]
set -uo pipefail
cd "$(dirname "$0")/.."
SPINEL="${SPINEL:-vendor/spinel/bin/spinel}"
SPIN="${SPIN:-vendor/spinel/bin/spin}"
FLAGS=$("$SPIN" flags 2>/dev/null | tail -n 1)
OUT="${TMPDIR:-/tmp}/pinky-tests"; mkdir -p "$OUT"
export TZ=UTC
tests=("$@"); [ ${#tests[@]} -eq 0 ] && tests=($(ls test/*_test.rb | xargs -n1 basename | sed 's/_test.rb$//'))
fail=0
for t in "${tests[@]}"; do
  ruby -w -I cruby -I . "test/${t}_test.rb" > "$OUT/$t.cruby" 2>&1; rc1=$?
  "$SPINEL" $FLAGS "test/${t}_test.rb" -o "$OUT/$t.bin" > "$OUT/$t.compile" 2>&1; rc2=$?
  if [ $rc2 -ne 0 ] || grep -q 'not available in Spinel' "$OUT/$t.compile"; then echo "FAIL $t: spinel compile"; grep -v -- '->' "$OUT/$t.compile" | head -8; fail=1; continue; fi
  "$OUT/$t.bin" > "$OUT/$t.spinel" 2>&1; rc3=$?
  if [ $rc1 -ne 0 ] || [ $rc3 -ne 0 ]; then echo "FAIL $t: exit cruby=$rc1 spinel=$rc3"; tail -n 5 "$OUT/$t.cruby" "$OUT/$t.spinel"; fail=1; continue; fi
  if diff -q "$OUT/$t.cruby" "$OUT/$t.spinel" >/dev/null; then echo "ok   $t ($(wc -l < "$OUT/$t.cruby" | tr -d ' ') lines)"; else echo "FAIL $t: output differs"; diff "$OUT/$t.cruby" "$OUT/$t.spinel" | head -10; fail=1; fi
done
exit $fail
