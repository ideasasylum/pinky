# frozen_string_literal: true
# Which regex features does Spinel's engine accept? One per line so the failing one is obvious.
$stdout.sync = true
s = "## Head **bold** *it* _u_ `c` [l](https://x.y/z) 2*3*4 snake_case"
puts "interp: #{s =~ /\A(#{"#"}{1,6})\s+(.*)\z/ ? $1.size : -1}"
puts "plain: #{s =~ /\A(#+)\s+(.*)\z/ ? $1.size : -1}"
puts "last_match: #{Regexp.last_match(2).to_s[0, 4]}"
puts "gsub block $1: #{s.gsub(/\*\*([^*]+)\*\*/) { "<b>#{$1}</b>" }[0, 20]}"
puts "gsub block last_match: #{s.gsub(/`([^`]+)`/) { "<code>#{Regexp.last_match(1)}</code>" }[20, 30]}"
puts "lookahead: #{s.gsub(/\*([^*\s][^*]*)\*(?![\w*])/) { "<em>#{$1}</em>" }[0, 40]}"
puts "lookbehind: #{s.gsub(/(?<![\w*])\*([^*\s][^*]*)\*/) { "<em>#{$1}</em>" }[0, 40]}"
puts "underscore: #{s.gsub(/(\A|\s)_([^_\s][^_]*)_(\s|\z)/) { "#{$1}<em>#{$2}</em>#{$3}" }[0, 40]}"
puts "link: #{s.gsub(/\[([^\]]+)\]\((https?:[^)\s]+)\)/) { "<a href=\"#{$2}\">#{$1}</a>" }[20, 60]}"
puts "ok"
