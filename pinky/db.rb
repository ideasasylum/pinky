# frozen_string_literal: true
# One SQLite connection. pinky/db_backend.rb (Spinel, FFI to the carried amalgamation) and
# cruby/pinky/db_backend.rb (sqlite3 gem) implement the same small Backend surface:
#   open(path) -> handle; exec(h, sql) -> changes; query(h, sql, binds) -> [[name...], [row...]];
#   run(h, sql, binds) -> changes; last_id(h); close(h)
# Bind values are Integer, Float, String, nil, or Array<Float> (stored as a float32 blob for vec0).
require "pinky/db_backend"

module Pinky
  class DBError < StandardError; end

  class DB
    attr_reader :path

    def initialize(path)
      @path = path
      @h = DBBackend.open(path)
      exec("PRAGMA journal_mode=WAL")
      exec("PRAGMA synchronous=NORMAL")
      exec("PRAGMA foreign_keys=ON")
      exec("PRAGMA busy_timeout=5000")
    end

    def exec(sql) = DBBackend.exec(@h, sql)

    # Array<Hash{String => Integer|Float|String|nil}>
    def query(sql, *binds)
      names, rows = DBBackend.query(@h, sql, binds)
      out = []
      rows.each do |row|
        rec = {}
        names.each_with_index { |name, i| rec[name] = row[i] }
        out << rec
      end
      out
    end

    def first(sql, *binds)
      rows = query(sql, *binds)
      rows.empty? ? nil : rows[0]
    end

    def run(sql, *binds) = DBBackend.run(@h, sql, binds)
    def last_id = DBBackend.last_id(@h)

    def transaction
      exec("BEGIN")
      begin
        yield
        exec("COMMIT")
      rescue StandardError
        exec("ROLLBACK")
        raise
      end
      nil
    end

    def close
      DBBackend.close(@h)
      nil
    end
  end
end
