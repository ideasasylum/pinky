# frozen_string_literal: true
# The one owner of pinky's SQL: facts, tags, the FTS5 and vec0 indexes, search, and session bookkeeping.
# An Embedder (optional) turns text into an Array<Float>; without one, search is full-text only.
require "digest"
require "pinky/db"
require "pinky/schema"

module Pinky
  class Store
    KINDS = ["fact", "gotcha", "decision", "task", "note"].freeze
    RRF_K = 60
    CANDIDATES = 50

    attr_reader :db, :embedder

    def self.open(path, embedder: nil)
      dir = File.dirname(path)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      db = DB.new(path)
      Schema.migrate(db)
      store = new(db, embedder: embedder)
      store.check_embedder
      store
    end

    # Vectors are only comparable when they come from one model; a database embedded with another model
    # (or none) keeps working for full-text search and says so until `brain reindex` runs.
    def check_embedder
      return if @embedder.nil?
      recorded = meta("embedder")
      if recorded.nil?
        set_meta("embedder", @embedder.name)
        set_meta("embedder_dim", @embedder.dim.to_s)
      elsif recorded.to_s != @embedder.name.to_s || meta("embedder_dim").to_s != @embedder.dim.to_s
        @stale_embedder = recorded
        @embedder = nil
      end
      nil
    end

    def stale_embedder = @stale_embedder

    # Recreates the vector table for the given embedder and re-embeds every active fact.
    def reindex(embedder)
      @db.transaction do
        @db.exec("DROP TABLE IF EXISTS facts_vec")
        @db.exec("CREATE VIRTUAL TABLE facts_vec USING vec0(fact_id INTEGER PRIMARY KEY, embedding float[#{embedder.dim}] distance_metric=cosine)")
        set_meta("embedder", embedder.name)
        set_meta("embedder_dim", embedder.dim.to_s)
      end
      @embedder = embedder
      @stale_embedder = nil
      n = 0
      @db.query("SELECT id, title, body FROM facts WHERE archived_at IS NULL ORDER BY id").each do |r|
        vec = embedder.embed(embedding_text(r["title"].to_s, r["body"].to_s))
        @db.run("INSERT INTO facts_vec(fact_id, embedding) VALUES (?, ?)", r["id"].to_s.to_i, vec)
        n += 1
      end
      n
    end

    def initialize(db, embedder: nil)
      @db = db
      @embedder = embedder
    end

    def close = @db.close

    def self.now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    # Returns [id, created]. A fact with the same project and body already present is returned untouched.
    def add(body, agent:, project:, title: nil, kind: "fact", tags: [], source: nil, now: Store.now)
      body = body.to_s.strip
      raise ArgumentError, "empty body" if body.empty?
      kind = kind.to_s
      raise ArgumentError, "unknown kind #{kind}" unless KINDS.include?(kind)
      title = derive_title(body) if title.nil? || title.to_s.strip.empty?
      title = title.to_s.strip
      tags = normalize_tags(tags)
      hash = Digest::SHA256.hexdigest("#{project}\n#{body}")
      existing = @db.first("SELECT id FROM facts WHERE content_hash = ?", hash)
      return [existing["id"].to_s.to_i, false] if existing

      id = 0
      vec = @embedder ? @embedder.embed(embedding_text(title, body)) : nil
      @db.transaction do
        @db.run("INSERT INTO facts(title, body, agent, project, kind, source, content_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                title, body, agent.to_s, project.to_s, kind, source, hash, now, now)
        id = @db.last_id
        tags.each { |t| @db.run("INSERT INTO tags(fact_id, tag) VALUES (?, ?)", id, t) }
        @db.run("INSERT INTO facts_fts(rowid, title, body, tags) VALUES (?, ?, ?, ?)", id, title, body, tags.join(" "))
        @db.run("INSERT INTO facts_vec(fact_id, embedding) VALUES (?, ?)", id, vec) if vec
      end
      [id, true]
    end

    def update(id, body: nil, title: nil, kind: nil, tags: nil, now: Store.now)
      fact = get(id)
      return nil unless fact
      new_body = body.nil? ? fact["body"].to_s : body.to_s.strip
      old_title = fact["title"].to_s
      derived = body && title.nil? && old_title == derive_title(fact["body"].to_s)
      new_title = title.nil? ? (derived ? derive_title(new_body) : old_title) : title.to_s.strip
      new_kind = kind.nil? ? fact["kind"].to_s : kind.to_s
      raise ArgumentError, "unknown kind #{new_kind}" unless KINDS.include?(new_kind)
      new_tags = tags.nil? ? fact["tags"].to_s.split(" ") : normalize_tags(tags)
      hash = Digest::SHA256.hexdigest("#{fact["project"]}\n#{new_body}")
      vec = @embedder ? @embedder.embed(embedding_text(new_title, new_body)) : nil
      old_tags = fact["tags"].to_s.split(" ")
      @db.transaction do
        unindex(id, fact["title"].to_s, fact["body"].to_s, old_tags) if fact["archived_at"].nil?
        @db.run("UPDATE facts SET title = ?, body = ?, kind = ?, content_hash = ?, updated_at = ? WHERE id = ?",
                new_title, new_body, new_kind, hash, now, id)
        @db.run("DELETE FROM tags WHERE fact_id = ?", id)
        new_tags.each { |t| @db.run("INSERT INTO tags(fact_id, tag) VALUES (?, ?)", id, t) }
        index(id, new_title, new_body, new_tags, vec) if fact["archived_at"].nil?
      end
      get(id)
    end

    def archive(id, now: Store.now)
      fact = get(id)
      return false if fact.nil? || fact["archived_at"]
      @db.transaction do
        @db.run("UPDATE facts SET archived_at = ?, updated_at = ? WHERE id = ?", now, now, id)
        unindex(id, fact["title"].to_s, fact["body"].to_s, fact["tags"].to_s.split(" "))
      end
      true
    end

    def restore(id, now: Store.now)
      fact = get(id)
      return false if fact.nil? || fact["archived_at"].nil?
      vec = @embedder ? @embedder.embed(embedding_text(fact["title"].to_s, fact["body"].to_s)) : nil
      @db.transaction do
        @db.run("UPDATE facts SET archived_at = NULL, updated_at = ? WHERE id = ?", now, id)
        index(id, fact["title"].to_s, fact["body"].to_s, fact["tags"].to_s.split(" "), vec)
      end
      true
    end

    def delete(id)
      fact = get(id)
      return false unless fact
      @db.transaction do
        unindex(id, fact["title"].to_s, fact["body"].to_s, fact["tags"].to_s.split(" ")) if fact["archived_at"].nil?
        @db.run("DELETE FROM tags WHERE fact_id = ?", id)
        @db.run("DELETE FROM facts WHERE id = ?", id)
      end
      true
    end

    # Hash with the fact's columns plus "tags" (space separated), or nil.
    def get(id)
      fact = @db.first("SELECT * FROM facts WHERE id = ?", id)
      return nil unless fact
      fact["tags"] = tags_for(id).join(" ")
      fact
    end

    def list(project: nil, agent: nil, kind: nil, tag: nil, archived: false, limit: 50, offset: 0)
      where, binds = filters(project, agent, kind, tag, archived)
      rows = @db.query("SELECT f.* FROM facts f WHERE #{where} ORDER BY f.updated_at DESC, f.id DESC LIMIT ? OFFSET ?", *binds, limit, offset)
      rows.each { |r| r["tags"] = tags_for(r["id"].to_s.to_i).join(" ") }
      rows
    end

    def count(project: nil, agent: nil, kind: nil, tag: nil, archived: false)
      where, binds = filters(project, agent, kind, tag, archived)
      row = @db.first("SELECT count(*) AS n FROM facts f WHERE #{where}", *binds)
      row ? row["n"].to_s.to_i : 0
    end

    def projects = @db.query("SELECT project, count(*) AS n FROM facts WHERE archived_at IS NULL GROUP BY project ORDER BY n DESC, project")
    def agents = @db.query("SELECT agent, count(*) AS n FROM facts WHERE archived_at IS NULL GROUP BY agent ORDER BY n DESC, agent")
    def tags = @db.query("SELECT t.tag, count(*) AS n FROM tags t JOIN facts f ON f.id = t.fact_id WHERE f.archived_at IS NULL GROUP BY t.tag ORDER BY n DESC, t.tag")

    # mode: "hybrid" (default), "fts", or "vector". Returns facts with "score" and "via" ("fts", "vec" or
    # "fts+vec"). Vector modes fall back to fts when there is no embedder.
    def search(query, mode: "hybrid", project: nil, agent: nil, kind: nil, tag: nil, limit: 10)
      query = query.to_s.strip
      return [] if query.empty?
      mode = "fts" if @embedder.nil? && mode != "fts"
      fts_ranks = {}
      fts_ranks = rank_map(fts_ids(query)) unless mode == "vector"
      distances = {}
      distances = vec_distances(query) unless mode == "fts"
      vec_ranks = rank_map(distances.keys)
      scores = {}
      via = {}
      fts_ranks.each do |id, rank|
        scores[id] = 1.0 / (RRF_K + rank)
        via[id] = "fts"
      end
      vec_ranks.each do |id, rank|
        scores[id] = (scores[id] || 0.0) + 1.0 / (RRF_K + rank)
        via[id] = via[id] ? "fts+vec" : "vec"
      end
      return [] if scores.empty?
      ids = scores.keys
      where, binds = filters(project, agent, kind, tag, false)
      placeholders = ids.map { "?" }.join(",")
      rows = @db.query("SELECT f.* FROM facts f WHERE f.id IN (#{placeholders}) AND #{where}", *ids, *binds)
      rows.each do |r|
        id = r["id"].to_s.to_i
        r["score"] = scores[id]
        r["via"] = via[id]
        r["distance"] = distances[id]
        r["tags"] = tags_for(id).join(" ")
      end
      rows.sort_by { |r| [-r["score"].to_f, r["updated_at"].to_s] }.reverse.sort_by { |r| -r["score"].to_f }.first(limit)
    end

    STOPWORDS = %w[a an and are as at be been but by can could do does for from has have how i if in into is it its
                   me my not of on or our should so than that the their then there these they this to use using was
                   we were what when where which who why will with would you your].freeze

    # FTS5 MATCH expression: each word quoted (so punctuation is safe) and OR-ed, ranking left to bm25.
    # Stopwords are dropped so that "the" alone does not match every fact.
    def self.fts_query(text)
      words = text.to_s.downcase.scan(/[[:alnum:]_]+/).reject { |w| w.size < 2 || STOPWORDS.include?(w) }.uniq
      return "" if words.empty?
      words.map { |w| "\"#{w}\"" }.join(" OR ")
    end

    def record_session(session_id, project:, agent:, now: Store.now)
      row = @db.first("SELECT session_id FROM sessions WHERE session_id = ?", session_id)
      if row
        @db.run("UPDATE sessions SET last_seen_at = ?, project = ?, agent = ? WHERE session_id = ?", now, project, agent, session_id)
      else
        @db.run("INSERT INTO sessions(session_id, project, agent, started_at, last_seen_at) VALUES (?, ?, ?, ?, ?)", session_id, project, agent, now, now)
      end
      nil
    end

    def bump_session(session_id, now: Store.now)
      @db.run("UPDATE sessions SET turns = turns + 1, last_seen_at = ? WHERE session_id = ?", now, session_id)
      nil
    end

    def mark_saved(session_id)
      @db.run("UPDATE sessions SET saved = saved + 1 WHERE session_id = ?", session_id)
      nil
    end

    def mark_nudged(session_id, now: Store.now)
      @db.run("UPDATE sessions SET nudged_at = ? WHERE session_id = ?", now, session_id)
      nil
    end

    def session(session_id) = @db.first("SELECT * FROM sessions WHERE session_id = ?", session_id)

    def meta(key)
      row = @db.first("SELECT value FROM meta WHERE key = ?", key)
      row ? row["value"].to_s : nil
    end

    def set_meta(key, value)
      @db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", key, value.to_s)
      nil
    end

    private

    def fts_ids(query)
      expr = Store.fts_query(query)
      return [] if expr.empty?
      @db.query("SELECT rowid AS id FROM facts_fts WHERE facts_fts MATCH ? ORDER BY rank LIMIT ?", expr, CANDIDATES).map { |r| r["id"].to_s.to_i }
    end

    # Hash{fact_id => cosine distance}, nearest first (Hash keeps insertion order on both runtimes).
    def vec_distances(query)
      vec = @embedder.embed(query)
      out = {}
      @db.query("SELECT fact_id, distance FROM facts_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance", vec, CANDIDATES).each do |r|
        out[r["fact_id"].to_s.to_i] = r["distance"].to_f
      end
      out
    end

    def rank_map(ids)
      ranks = {}
      ids.each_with_index { |id, i| ranks[id] = i + 1 }
      ranks
    end

    def filters(project, agent, kind, tag, archived)
      clauses = [archived ? "f.archived_at IS NOT NULL" : "f.archived_at IS NULL"]
      binds = []
      if project
        clauses << "f.project = ?"
        binds << project.to_s
      end
      if agent
        clauses << "f.agent = ?"
        binds << agent.to_s
      end
      if kind
        clauses << "f.kind = ?"
        binds << kind.to_s
      end
      if tag
        clauses << "EXISTS (SELECT 1 FROM tags t WHERE t.fact_id = f.id AND t.tag = ?)"
        binds << tag.to_s.downcase
      end
      [clauses.join(" AND "), binds]
    end

    def tags_for(id) = @db.query("SELECT tag FROM tags WHERE fact_id = ? ORDER BY tag", id).map { |r| r["tag"].to_s }

    def index(id, title, body, tags, vec)
      @db.run("INSERT INTO facts_fts(rowid, title, body, tags) VALUES (?, ?, ?, ?)", id, title, body, tags.join(" "))
      @db.run("INSERT INTO facts_vec(fact_id, embedding) VALUES (?, ?)", id, vec) if vec
      nil
    end

    # The FTS table is contentless, so the 'delete' command needs the exact values that were indexed.
    def unindex(id, title, body, tags)
      @db.run("INSERT INTO facts_fts(facts_fts, rowid, title, body, tags) VALUES ('delete', ?, ?, ?, ?)", id, title, body, tags.join(" "))
      @db.run("DELETE FROM facts_vec WHERE fact_id = ?", id)
      nil
    end

    def embedding_text(title, body)
      text = +""
      text << title << "\n" << body
      text
    end

    def derive_title(body)
      body.to_s.split("\n").each do |line|
        l = line.strip
        next if l.empty?
        l = l.sub(/\A#+\s*/, "")
        return l.size > 80 ? "#{l[0, 77]}..." : l
      end
      "untitled"
    end

    def normalize_tags(tags)
      tags.map { |t| t.to_s.strip.downcase }.reject(&:empty?).uniq
    end
  end
end
