# frozen_string_literal: true
require "pinky/args"

$stdout.sync = true
values = ["db", "limit", "tags"]
flags = ["json", "archived"]

def show(opts, rest)
  keys = opts.keys.sort
  "opts{#{keys.map { |k| "#{k}=#{opts[k]}" }.join(" ")}} rest[#{rest.join(",")}]"
end

opts, rest = Pinky::Args.parse(["search", "frozen", "strings", "--limit", "5", "--json"], values, flags)
puts show(opts, rest)
opts, rest = Pinky::Args.parse(["--db=/tmp/x.db", "--tags", "a,b", "show", "3"], values, flags)
puts show(opts, rest)
opts, rest = Pinky::Args.parse(["--archived", "--", "--not-an-option", "x"], values, flags)
puts show(opts, rest)
opts, rest = Pinky::Args.parse([], values, flags)
puts show(opts, rest)

["--limit", "--json=1", "--bogus", "--limit=", ""].each do |bad|
  begin
    opts, rest = Pinky::Args.parse([bad], values, flags)
    puts "#{bad.inspect}: #{show(opts, rest)}"
  rescue Pinky::Args::Error => e
    puts "#{bad.inspect}: #{e.message}"
  end
end
puts "ok"
