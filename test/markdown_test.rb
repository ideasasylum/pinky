# frozen_string_literal: true
# Backticks are spelled \x60 throughout: Spinel's lexer mis-tokenises literal backticks (docs/spinel.md).
require "pinky/markdown"

$stdout.sync = true
bt = "\x60"
fence = bt * 3
doc = [
  "# Title with #{bt}code#{bt} & <angles>",
  "",
  "A paragraph with **bold**, *italic*, _also italic_, #{bt}inline <code>#{bt} and a [link](https://example.com/a?b=1).",
  "It continues on a second line.",
  "",
  "- first item",
  "- second **item**",
  "* third item",
  "",
  "1. one",
  "2) two",
  "",
  "#{fence}ruby",
  "puts \"<hello>\" # not **bold** here",
  fence,
  "",
  "Trailing paragraph 2*3*4 and snake_case_name stay literal.",
  "## Sub-heading",
  "Text right after a heading."
].join("\n")
puts Pinky::Markdown.render(doc)
puts "---"
puts Pinky::Markdown.render("")
puts Pinky::Markdown.render("unterminated #{fence}\ncode\nstill code")
puts Pinky::Markdown.render("#{fence}\nonly code\n#{fence}")
puts Pinky::Markdown.inline("a #{bt}b#{bt} c #{bt}d#{bt}")
puts Pinky::Markdown.h("<script>alert(\"x\")</script> & 'q'")
puts "ok"
