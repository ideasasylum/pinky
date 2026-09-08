# frozen_string_literal: true
# Prints observations; test/run.sh diffs this output between CRuby and the Spinel binary.
require "pinky"
require "tmpdir"

$stdout.sync = true
dir = Dir.mktmpdir("pinky-db-test")
db = Pinky::DB.new("#{dir}/t.db")
puts "schema v#{Pinky::Schema.migrate(db)}"
puts "again v#{Pinky::Schema.migrate(db)}"
vec = db.first("SELECT vec_version() AS v")
puts "vec #{vec ? vec["v"] : "?"}"

def unit(i, dim)
  v = []
  j = 0
  while j < dim
    v << (j == i ? 1.0 : 0.0)
    j += 1
  end
  v
end

def count(db)
  row = db.first("SELECT count(*) AS n FROM facts")
  row ? row["n"] : -1
end

now = "2026-09-08T00:00:00Z"
titles = ["Frozen strings", "WAL mode", "Blob binding"]
bodies = ["String literals are always frozen under Spinel",
          "Use WAL and a busy timeout when processes share a database",
          "Binary blobs go through a C shim because :str stops at NUL"]
i = 0
while i < titles.size
  title = titles[i]
  body = bodies[i]
  vec_i = i
  db.transaction do
    db.run("INSERT INTO facts(title, body, agent, project, content_hash, created_at, updated_at) VALUES (?, ?, 'test', 'pinky', ?, ?, ?)",
           title, body, "h#{vec_i}", now, now)
    id = db.last_id
    db.run("INSERT INTO facts_fts(rowid, title, body, tags) VALUES (?, ?, ?, '')", id, title, body)
    db.run("INSERT INTO facts_vec(fact_id, embedding) VALUES (?, ?)", id, unit(vec_i, Pinky::Schema::DIM))
  end
  i += 1
end
puts "facts #{count(db)}"

puts "fts:"
db.query("SELECT rowid AS id FROM facts_fts WHERE facts_fts MATCH ? ORDER BY rank", "frozen OR blob").each { |r| puts "  #{r["id"]}" }

q = unit(2, Pinky::Schema::DIM)
q[0] = 0.5
puts "knn:"
db.query("SELECT fact_id, distance FROM facts_vec WHERE embedding MATCH ? AND k = 2", q).each do |r|
  puts "  #{r["fact_id"]} #{(r["distance"].to_f * 1000).round}"
end

puts "rollback:"
begin
  db.transaction do
    db.run("INSERT INTO facts(title, body, agent, project, content_hash, created_at, updated_at) VALUES ('x', 'x', 'a', 'p', 'hx', ?, ?)", now, now)
    raise Pinky::DBError, "boom"
  end
rescue Pinky::DBError => e
  puts "  #{e.message}"
end
puts "  facts #{count(db)}"

puts "dup:"
begin
  db.run("INSERT INTO facts(title, body, agent, project, content_hash, created_at, updated_at) VALUES ('x', 'x', 'a', 'p', 'h0', ?, ?)", now, now)
rescue Pinky::DBError
  puts "  rejected"
end
db.close
puts "ok"
