# frozen_string_literal: true
# Hybrid, full-text and vector search through the store with the real embedder. Skips when the model is
# absent so the parity run still passes on a machine that has not run `brain setup`.
require "pinky"
require "tmpdir"

$stdout.sync = true
dir = ENV["PINKY_MODEL_DIR"] || Pinky::Model2Vec.default_dir
unless Pinky::Model2Vec.available?(dir)
  puts "model not present at #{dir}; run brain setup"
  puts "ok"
  exit 0
end

embedder = Pinky::Model2Vec.load(dir)
tmp = Dir.mktmpdir("pinky-search-test")
store = Pinky::Store.open("#{tmp}/t.db", embedder: embedder)
puts "meta #{store.meta("embedder")} #{store.meta("embedder_dim")}"

facts = [
  ["Frozen string literals", "Under Spinel every string literal is frozen; build mutable buffers with +\"\" and append with <<.", "chips", ["spinel"]],
  ["WAL for shared databases", "Use WAL journal mode and a busy timeout when several processes open one SQLite file.", "pinky", ["sqlite"]],
  ["Blobs need a C shim", "The :str FFI type stops at the first NUL, so binary data is bound through a small C function.", "chips", ["spinel", "ffi"]],
  ["Kitchen calendar feeds", "The kitchen app reads private iCalendar feeds and expands RRULE recurrences into a two-week window.", "chips", ["ical"]],
  ["Hook context injection", "Only SessionStart and UserPromptSubmit hooks can add context to a Claude Code conversation.", "pinky", ["claude-code", "hooks"]],
  ["Reciprocal rank fusion", "Hybrid search fuses the BM25 list and the KNN list with 1/(60+rank) scores.", "pinky", ["search"]]
]
t = "2026-09-08T00:00:00Z"
facts.each_with_index do |f, i|
  store.add(f[1], title: f[0], agent: "test", project: f[2], tags: f[3], now: "2026-09-08T00:0#{i}:00Z")
end
puts "facts #{store.count} vectors #{store.db.first("SELECT count(*) AS n FROM facts_vec")["n"]}"

def show(label, results)
  puts "#{label}: #{results.map { |r| "#{r["id"]}#{r["via"] ? "(#{r["via"]})" : ""}" }.join(" ")}"
end

# A paraphrase with no shared keywords: only the vector side can find it.
show("vector paraphrase", store.search("the compiler makes text constants immutable", mode: "vector", limit: 3))
show("fts paraphrase", store.search("the compiler makes text constants immutable", mode: "fts", limit: 3))
show("hybrid paraphrase", store.search("the compiler makes text constants immutable", limit: 3))
# Exact keywords: fts and vector should agree and the hybrid score marks both lists.
show("hybrid keywords", store.search("WAL busy timeout SQLite", limit: 3))
show("hybrid calendar", store.search("recurring events from an ical feed", limit: 2))
show("hybrid hooks", store.search("which hooks inject context", limit: 2))
show("project filter", store.search("spinel ffi strings", project: "pinky", limit: 5))
show("tag filter", store.search("spinel", tag: "ffi", limit: 5))
show("kind filter", store.search("spinel", kind: "decision", limit: 5))

store.archive(1, now: t)
show("after archive", store.search("the compiler makes text constants immutable", mode: "vector", limit: 2))
store.restore(1, now: t)
show("after restore", store.search("the compiler makes text constants immutable", mode: "vector", limit: 2))
store.update(4, body: "Nothing about calendars any more: this fact is now about container orchestration.", now: t)
show("after update", store.search("recurring events from an ical feed", mode: "vector", limit: 1))

n = store.reindex(embedder)
puts "reindex #{n} vectors #{store.db.first("SELECT count(*) AS n FROM facts_vec")["n"]}"
show("after reindex", store.search("the compiler makes text constants immutable", mode: "vector", limit: 1))

class FakeEmbedder
  def name = "fake/other"
  def dim = 8
  def embed(_text) = Array.new(8, 0.5)
end
store.close
reopened = Pinky::Store.open("#{tmp}/t.db", embedder: FakeEmbedder.new)
puts "stale: #{reopened.stale_embedder} embedder nil: #{reopened.embedder.nil?}"
show("stale falls back to fts", reopened.search("WAL busy timeout", limit: 1))
puts "reindex with fake: #{reopened.reindex(FakeEmbedder.new)} meta #{reopened.meta("embedder")} #{reopened.meta("embedder_dim")}"
reopened.close
puts "ok"
