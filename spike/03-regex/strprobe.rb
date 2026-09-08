# frozen_string_literal: true
$stdout.sync = true
puts "a\"b"
puts "x".gsub("\"", "&quot;")
puts "<a href=\"#{1 + 1}\">l</a>"
puts "ok"
