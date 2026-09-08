# frozen_string_literal: true
require "pinky"
require "pinky/hooks"
require "pinky/install"
require "tmpdir"

$stdout.sync = true
tmp = Dir.mktmpdir("pinky-hooks-test")
model_dir = ENV["PINKY_MODEL_DIR"] || Pinky::Model2Vec.default_dir
embedder = Pinky::Model2Vec.available?(model_dir) ? Pinky::Model2Vec.load(model_dir) : nil
puts "embedder #{embedder ? "yes" : "no"}"
store = Pinky::Store.open("#{tmp}/t.db", embedder: embedder)
t = "2026-09-08T00:00:00Z"

store.add("Under Spinel every string literal is frozen; build mutable buffers with +\"\" and append with <<.", title: "Frozen string literals",
          agent: "chips/spike", project: "chips", kind: "gotcha", tags: ["spinel"], now: "2026-09-08T00:01:00Z")
store.add("Use WAL journal mode and a busy timeout when several processes open one SQLite file.", title: "WAL for shared databases",
          agent: "pinky/spike", project: "pinky", kind: "decision", tags: ["sqlite"], now: "2026-09-08T00:02:00Z")
store.add("The kitchen app reads private iCalendar feeds and expands RRULE recurrences.", title: "Kitchen calendar feeds",
          agent: "chips/spike", project: "chips", kind: "fact", tags: ["ical"], now: "2026-09-08T00:03:00Z")
store.add("Only SessionStart and UserPromptSubmit hooks can add context to a Claude Code conversation.", title: "Hook context injection",
          agent: "pinky/spike", project: "pinky", kind: "gotcha", tags: ["claude-code"], now: "2026-09-08T00:04:00Z")

class Capture
  attr_reader :text
  def initialize = @text = +""
  def puts(s = "") = @text << s.to_s << "\n"
  def write(s) = @text << s.to_s
end

def run_hook(store, event, input, now)
  out = Capture.new
  err = Capture.new
  rc = Pinky::Hooks.new(store, out, err).run(event, input.nil? ? "" : JSON.generate(input), now: now)
  [rc, out.text, err.text]
end

cwd = "#{tmp}/chips"
Dir.mkdir(cwd)

puts "-- session-start"
rc, out, err = run_hook(store, "session-start", { "session_id" => "s1", "cwd" => cwd, "hook_event_name" => "SessionStart" }, t)
payload = JSON.parse(out)
ctx = payload["hookSpecificOutput"]["additionalContext"].to_s
puts "rc=#{rc} event=#{payload["hookSpecificOutput"]["hookEventName"]} err=#{err.inspect}"
puts ctx.split("\n").map { |l| l.size > 90 ? "#{l[0, 90]}..." : l }.join("\n")
s = store.session("s1")
puts "session project=#{s["project"]} agent=#{s["agent"]} turns=#{s["turns"]}"

puts "-- session-start, unknown project"
rc, out, _err = run_hook(store, "session-start", { "session_id" => "s2", "cwd" => "#{tmp}/nowhere" }, t)
puts JSON.parse(out)["hookSpecificOutput"]["additionalContext"].split("\n")[0]

puts "-- prompt, short"
rc, out, _err = run_hook(store, "prompt", { "session_id" => "s1", "cwd" => cwd, "prompt" => "hi there" }, t)
puts "rc=#{rc} out=#{out.inspect} turns=#{store.session("s1")["turns"]}"

puts "-- prompt, slash command"
rc, out, _err = run_hook(store, "prompt", { "session_id" => "s1", "cwd" => cwd, "prompt" => "/remember everything about this long session please" }, t)
puts "rc=#{rc} out=#{out.inspect}"

puts "-- prompt, relevant"
rc, out, _err = run_hook(store, "prompt", { "session_id" => "s1", "cwd" => cwd, "prompt" => "why can't I mutate this string in spinel, it raises FrozenError" }, t)
ctx = out.empty? ? "" : JSON.parse(out)["hookSpecificOutput"]["additionalContext"].to_s
puts "rc=#{rc} lines=#{ctx.split("\n").size} mentions frozen: #{ctx.include?("Frozen string literals")} mentions ical: #{ctx.include?("Kitchen")}"

puts "-- prompt, cross-project"
rc, out, _err = run_hook(store, "prompt", { "session_id" => "s1", "cwd" => cwd, "prompt" => "how should several processes share one sqlite database file safely" }, t)
ctx = out.empty? ? "" : JSON.parse(out)["hookSpecificOutput"]["additionalContext"].to_s
puts "rc=#{rc} mentions WAL: #{ctx.include?("WAL")}"

puts "-- prompt, unrelated"
rc, out, _err = run_hook(store, "prompt", { "session_id" => "s1", "cwd" => cwd, "prompt" => "write a short poem about autumn leaves falling in the park" }, t)
puts "rc=#{rc} injected=#{!out.empty?}"

puts "-- stop, not enough work"
rc, out, _err = run_hook(store, "stop", { "session_id" => "s1", "cwd" => cwd, "stop_hook_active" => false }, t)
puts "rc=#{rc} out=#{out.inspect} turns=#{store.session("s1")["turns"]}"

puts "-- stop, after work"
transcript = "#{tmp}/transcript.jsonl"
f = File.open(transcript, "w")
4.times { f.write("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{}}]}}\n") }
f.write("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}\n")
f.close
rc, out, _err = run_hook(store, "stop", { "session_id" => "s1", "cwd" => cwd, "stop_hook_active" => false, "transcript_path" => transcript }, t)
decision = out.empty? ? {} : JSON.parse(out)
puts "rc=#{rc} decision=#{decision["decision"]} mentions session: #{decision["reason"].to_s.include?("--source s1")} nudged=#{store.session("s1")["nudged_at"]}"

puts "-- stop, again"
rc, out, _err = run_hook(store, "stop", { "session_id" => "s1", "cwd" => cwd, "stop_hook_active" => false, "transcript_path" => transcript }, t)
puts "rc=#{rc} out=#{out.inspect}"

puts "-- stop, hook active"
rc, out, _err = run_hook(store, "stop", { "session_id" => "s9", "stop_hook_active" => true }, t)
puts "rc=#{rc} out=#{out.inspect}"

puts "-- stop, saved already"
10.times { store.bump_session("s2", now: t) }
store.mark_saved("s2")
rc, out, _err = run_hook(store, "stop", { "session_id" => "s2", "cwd" => cwd, "stop_hook_active" => false }, t)
puts "rc=#{rc} out=#{out.inspect}"

puts "-- stop, many turns, no transcript"
store.record_session("s3", project: "chips", agent: "x", now: t)
10.times { store.bump_session("s3", now: t) }
rc, out, _err = run_hook(store, "stop", { "session_id" => "s3", "cwd" => cwd, "stop_hook_active" => false }, t)
puts "rc=#{rc} decision=#{out.empty? ? nil : JSON.parse(out)["decision"]}"

puts "-- bad input"
rc, out, err = run_hook(store, "prompt", nil, t)
puts "rc=#{rc} out=#{out.inspect} err=#{err.inspect}"
out = Capture.new
err = Capture.new
rc = Pinky::Hooks.new(store, out, err).run("prompt", "{not json", now: t)
puts "rc=#{rc} bad json reported: #{err.text.include?("bad input JSON")}"

puts "-- install"
home = "#{tmp}/home"
Dir.mkdir(home)
Dir.mkdir("#{home}/.claude")
existing = { "permissions" => { "defaultMode" => "auto" }, "hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command", "command" => "/usr/local/bin/other-tool" }] }] } }
Pinky::Install.write("#{home}/.claude/settings.json", JSON.generate(existing))
out = Capture.new
Pinky::Install.run(home, "brain", out)
puts out.text.gsub(home, "HOME")
settings = JSON.parse(File.read("#{home}/.claude/settings.json"))
puts "permissions kept: #{settings["permissions"]["defaultMode"]}"
puts "Stop entries: #{settings["hooks"]["Stop"].size} commands: #{settings["hooks"]["Stop"].map { |e| e["hooks"][0]["command"] }.join(" | ")}"
puts "SessionStart: #{settings["hooks"]["SessionStart"][0]["hooks"][0]["command"]} timeout #{settings["hooks"]["SessionStart"][0]["hooks"][0]["timeout"]}"
puts "skills: #{Dir.exist?("#{home}/.claude/skills/pinky-remember")} #{File.read("#{home}/.claude/skills/pinky-recall/SKILL.md").split("\n")[1]}"
out = Capture.new
Pinky::Install.run(home, "brain", out)
puts out.text.gsub(home, "HOME")
store.close
puts "ok"
