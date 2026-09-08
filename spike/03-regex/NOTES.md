# 03: regex features under Spinel

`probe.rb` compiles and prints the same output under CRuby and Spinel for: an interpolated regex literal,
`$1` after `=~`, `Regexp.last_match(n)`, `$1` and `Regexp.last_match` inside `gsub` blocks, lookahead,
lookbehind, capture groups re-emitted in the replacement, and a link-matching pattern with `[^)\s]`.

Written while chasing a "unterminated string meets end of file" parse error in `pinky/markdown.rb` that
turned out to be four NUL bytes in the file, not any regex construct (see docs/spinel.md).
