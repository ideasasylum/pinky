# frozen_string_literal: true
require "pinky"
require "tmpdir"

$stdout.sync = true
dir = Dir.mktmpdir("pinky-store-test")
store = Pinky::Store.open("#{dir}/t.db")
t0 = "2026-09-08T00:00:00Z"

id1, created1 = store.add("# Frozen strings\nString literals are always frozen under Spinel; build buffers with +\"\" and <<.",
                          agent: "chips/spike", project: "chips", kind: "gotcha", tags: ["Spinel", "strings", "spinel"], now: t0)
id2, created2 = store.add("Use WAL journal mode and a busy timeout when several processes share one SQLite file.",
                          agent: "pinky/spike", project: "pinky", kind: "decision", tags: ["sqlite"], now: "2026-09-08T00:01:00Z")
id3, created3 = store.add("Binary blobs go through a C shim because the :str FFI type stops at the first NUL byte.",
                          agent: "chips/spike", project: "chips", tags: ["spinel", "ffi"], source: "sess-1", now: "2026-09-08T00:02:00Z")
dup_id, dup_created = store.add("# Frozen strings\nString literals are always frozen under Spinel; build buffers with +\"\" and <<.",
                                agent: "someone", project: "chips", now: "2026-09-08T00:03:00Z")
puts "ids #{id1} #{id2} #{id3} created #{created1} #{created2} #{created3}"
puts "dup #{dup_id == id1} #{dup_created}"

f = store.get(id1)
puts "title: #{f["title"]}"
puts "tags: #{f["tags"]}"
puts "kind: #{f["kind"]} agent: #{f["agent"]}"
puts "derived: #{store.get(id2)["title"]}"

begin
  store.add("", agent: "a", project: "p")
rescue ArgumentError => e
  puts "empty: #{e.message}"
end
begin
  store.add("x", agent: "a", project: "p", kind: "rumour")
rescue ArgumentError => e
  puts "kind: #{e.message}"
end

puts "list all: #{store.list.map { |r| r["id"] }.join(",")}"
puts "list chips: #{store.list(project: "chips").map { |r| r["id"] }.join(",")}"
puts "list tag spinel: #{store.list(tag: "spinel").map { |r| r["id"] }.join(",")}"
puts "list kind decision: #{store.list(kind: "decision").map { |r| r["id"] }.join(",")}"
puts "count: #{store.count} chips: #{store.count(project: "chips")}"

puts "fts query: #{Pinky::Store.fts_query("Spinel's frozen-strings, NUL!")}"
puts "search frozen: #{store.search("frozen strings").map { |r| "#{r["id"]}:#{r["via"]}" }.join(" ")}"
puts "search nul chips: #{store.search("NUL byte blob", project: "chips").map { |r| r["id"] }.join(" ")}"
puts "search tag sqlite: #{store.search("timeout", tag: "sqlite").map { |r| r["id"] }.join(" ")}"
puts "search nothing: #{store.search("zebra").size}"
puts "search empty: #{store.search("   ").size}"

puts "projects: #{store.projects.map { |r| "#{r["project"]}=#{r["n"]}" }.join(" ")}"
puts "agents: #{store.agents.map { |r| "#{r["agent"]}=#{r["n"]}" }.join(" ")}"
puts "tags: #{store.tags.map { |r| "#{r["tag"]}=#{r["n"]}" }.join(" ")}"

puts "archive: #{store.archive(id1, now: "2026-09-08T00:04:00Z")} again: #{store.archive(id1)}"
puts "after archive list: #{store.list.map { |r| r["id"] }.join(",")} archived: #{store.list(archived: true).map { |r| r["id"] }.join(",")}"
puts "after archive search: #{store.search("frozen").map { |r| r["id"] }.join(" ")}"
puts "restore: #{store.restore(id1, now: "2026-09-08T00:05:00Z")} again: #{store.restore(id1)}"
puts "after restore search: #{store.search("frozen").map { |r| r["id"] }.join(" ")}"

updated = store.update(id2, body: "Use WAL mode, synchronous=NORMAL and busy_timeout when processes share a database.", tags: ["sqlite", "wal"], now: "2026-09-08T00:06:00Z")
puts "update: #{updated["title"]} | #{updated["tags"]}"
puts "search wal: #{store.search("synchronous").map { |r| r["id"] }.join(" ")}"
puts "update missing: #{store.update(999, title: "x").inspect}"

puts "delete: #{store.delete(id3)} again: #{store.delete(id3)}"
puts "after delete: #{store.count} search: #{store.search("blob").size}"

store.record_session("s1", project: "chips", agent: "chips/spike", now: t0)
store.bump_session("s1", now: t0)
store.bump_session("s1", now: t0)
store.mark_saved("s1")
s = store.session("s1")
puts "session turns=#{s["turns"]} saved=#{s["saved"]} nudged=#{s["nudged_at"].inspect}"
store.mark_nudged("s1", now: t0)
puts "nudged=#{store.session("s1")["nudged_at"]}"
store.set_meta("embedder", "none")
puts "meta: #{store.meta("embedder")} #{store.meta("missing").inspect}"
store.close
puts "ok"
