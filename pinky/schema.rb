# frozen_string_literal: true
require "pinky/db"

module Pinky
  # Migrations run in order; meta.schema_version records the last applied. The vector table's dimension
  # is fixed at creation, so changing embedders means `brain reindex` recreating facts_vec.
  module Schema
    DIM = 256

    MIGRATIONS = [
      <<~SQL
        CREATE TABLE facts (
          id INTEGER PRIMARY KEY,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          agent TEXT NOT NULL,
          project TEXT NOT NULL,
          kind TEXT NOT NULL DEFAULT 'fact',
          source TEXT,
          content_hash TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          archived_at TEXT
        );
        CREATE INDEX facts_project ON facts(project, archived_at);
        CREATE INDEX facts_agent ON facts(agent);
        CREATE TABLE tags (
          fact_id INTEGER NOT NULL REFERENCES facts(id) ON DELETE CASCADE,
          tag TEXT NOT NULL,
          PRIMARY KEY (fact_id, tag)
        );
        CREATE VIRTUAL TABLE facts_fts USING fts5(title, body, tags, content='', tokenize='porter unicode61');
        CREATE VIRTUAL TABLE facts_vec USING vec0(fact_id INTEGER PRIMARY KEY, embedding float[#{DIM}] distance_metric=cosine);
        CREATE TABLE sessions (
          session_id TEXT PRIMARY KEY,
          project TEXT,
          agent TEXT,
          started_at TEXT,
          last_seen_at TEXT,
          turns INTEGER NOT NULL DEFAULT 0,
          saved INTEGER NOT NULL DEFAULT 0,
          nudged_at TEXT
        );
      SQL
    ]

    def self.migrate(db)
      db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      row = db.first("SELECT value FROM meta WHERE key = 'schema_version'")
      current = row ? row["value"].to_s.to_i : 0
      i = current
      while i < MIGRATIONS.size
        sql = MIGRATIONS[i]
        version = (i + 1).to_s
        db.transaction do
          db.exec(sql)
          db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)", version)
        end
        i += 1
      end
      MIGRATIONS.size
    end
  end
end
