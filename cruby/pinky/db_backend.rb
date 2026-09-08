# frozen_string_literal: true
# CRuby backend for the dev loop: the sqlite3 gem plus sqlite-vec as a loadable extension built by
# scripts/check.sh into build/vec0.dylib (override with PINKY_VEC_EXT).
require "sqlite3"

module Pinky
  module DBBackend
    VEC_EXT = ENV["PINKY_VEC_EXT"] || File.expand_path("../../build/vec0", __dir__)

    def self.open(path)
      db = SQLite3::Database.new(path)
      db.enable_load_extension(true)
      db.load_extension(VEC_EXT)
      db.enable_load_extension(false)
      db
    rescue SQLite3::Exception => e
      raise DBError, e.message
    end

    def self.exec(h, sql)
      h.execute_batch(sql)
      h.changes
    rescue SQLite3::Exception => e
      raise DBError, e.message
    end

    def self.query(h, sql, binds)
      stmt = h.prepare(sql)
      stmt.bind_params(*binds.map { |v| bindable(v) })
      rows = stmt.execute.to_a
      [stmt.columns, rows]
    rescue SQLite3::Exception => e
      raise DBError, e.message
    ensure
      stmt&.close
    end

    def self.run(h, sql, binds)
      query(h, sql, binds)
      h.changes
    end

    def self.last_id(h) = h.last_insert_row_id
    def self.close(h) = h.close

    def self.bindable(v)
      v.is_a?(Array) ? SQLite3::Blob.new(v.pack("e*")) : v
    end
  end
end
