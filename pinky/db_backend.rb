# frozen_string_literal: true
# Spinel backend: the SQLite amalgamation and sqlite-vec are carried in native/ and bound with FFI.
# Vectors (Array<Float>) are bound as float32 blobs through the C shim so no Ruby String holds binary.
module Pinky
  module SQLite3C
    ffi_const :OK, 0
    ffi_const :ROW, 100
    ffi_const :DONE, 101
    ffi_const :INTEGER, 1
    ffi_const :FLOAT, 2
    ffi_const :TEXT, 3
    ffi_const :BLOB, 4
    ffi_const :NULL, 5
    ffi_const :OPEN_READWRITE, 2
    ffi_const :OPEN_CREATE, 4
    ffi_func :sqlite3_open_v2,      [:str, :ptr, :int, :ptr],   :int
    ffi_func :sqlite3_close_v2,     [:ptr],                     :int
    ffi_func :sqlite3_exec,         [:ptr, :str, :ptr, :ptr, :ptr], :int
    ffi_func :sqlite3_prepare_v2,   [:ptr, :str, :int, :ptr, :ptr], :int
    ffi_func :sqlite3_bind_int64,   [:ptr, :int, :long],        :int
    ffi_func :sqlite3_bind_double,  [:ptr, :int, :double],      :int
    ffi_func :sqlite3_bind_text,    [:ptr, :int, :str, :int, :ptr], :int
    ffi_func :sqlite3_bind_null,    [:ptr, :int],               :int
    ffi_func :sqlite3_step,         [:ptr],                     :int
    ffi_func :sqlite3_finalize,     [:ptr],                     :int
    ffi_func :sqlite3_column_count, [:ptr],                     :int
    ffi_func :sqlite3_column_name,  [:ptr, :int],               :str
    ffi_func :sqlite3_column_type,  [:ptr, :int],               :int
    ffi_func :sqlite3_column_int64, [:ptr, :int],               :long
    ffi_func :sqlite3_column_double,[:ptr, :int],               :double
    ffi_func :sqlite3_column_text,  [:ptr, :int],               :str
    ffi_func :sqlite3_errmsg,       [:ptr],                     :str
    ffi_func :sqlite3_changes,      [:ptr],                     :int
    ffi_func :sqlite3_last_insert_rowid, [:ptr],                :long
    ffi_func :pinky_vec_init,       [:ptr],                     :int
    ffi_func :pinky_bind_f32,       [:ptr, :int, :float_array, :size_t], :int
    ffi_buffer :db_out, 8
    ffi_buffer :stmt_out, 8
    ffi_read_ptr :read_ptr, 0
  end

  module DBBackend
    def self.open(path)
      rc = SQLite3C.sqlite3_open_v2(path, SQLite3C.db_out, SQLite3C::OPEN_READWRITE | SQLite3C::OPEN_CREATE, nil)
      raise DBError, "cannot open #{path} (#{rc})" unless rc == SQLite3C::OK
      h = SQLite3C.read_ptr(SQLite3C.db_out)
      rc = SQLite3C.pinky_vec_init(h)
      raise DBError, "sqlite-vec init failed (#{rc})" unless rc == SQLite3C::OK
      h
    end

    def self.exec(h, sql)
      rc = SQLite3C.sqlite3_exec(h, sql, nil, nil, nil)
      raise DBError, SQLite3C.sqlite3_errmsg(h) unless rc == SQLite3C::OK
      SQLite3C.sqlite3_changes(h)
    end

    def self.query(h, sql, binds)
      stmt = prepare(h, sql)
      bind_all(h, stmt, binds)
      n = SQLite3C.sqlite3_column_count(stmt)
      names = []
      i = 0
      while i < n
        names << SQLite3C.sqlite3_column_name(stmt, i).to_s
        i += 1
      end
      rows = []
      while (rc = SQLite3C.sqlite3_step(stmt)) == SQLite3C::ROW
        row = []
        i = 0
        while i < n
          row << column(stmt, i)
          i += 1
        end
        rows << row
      end
      SQLite3C.sqlite3_finalize(stmt)
      raise DBError, SQLite3C.sqlite3_errmsg(h) unless rc == SQLite3C::DONE
      [names, rows]
    end

    def self.run(h, sql, binds)
      stmt = prepare(h, sql)
      bind_all(h, stmt, binds)
      rc = SQLite3C.sqlite3_step(stmt)
      SQLite3C.sqlite3_finalize(stmt)
      raise DBError, SQLite3C.sqlite3_errmsg(h) unless rc == SQLite3C::DONE || rc == SQLite3C::ROW
      SQLite3C.sqlite3_changes(h)
    end

    def self.last_id(h) = SQLite3C.sqlite3_last_insert_rowid(h)
    def self.close(h) = SQLite3C.sqlite3_close_v2(h)

    def self.prepare(h, sql)
      rc = SQLite3C.sqlite3_prepare_v2(h, sql, -1, SQLite3C.stmt_out, nil)
      raise DBError, SQLite3C.sqlite3_errmsg(h) unless rc == SQLite3C::OK
      SQLite3C.read_ptr(SQLite3C.stmt_out)
    end

    def self.bind_all(h, stmt, binds)
      binds.each_with_index do |v, i|
        case v
        when Integer then SQLite3C.sqlite3_bind_int64(stmt, i + 1, v)
        when Float then SQLite3C.sqlite3_bind_double(stmt, i + 1, v)
        when String then SQLite3C.sqlite3_bind_text(stmt, i + 1, v, v.bytesize, -1)
        when Array then SQLite3C.pinky_bind_f32(stmt, i + 1, v, v.size)
        when nil then SQLite3C.sqlite3_bind_null(stmt, i + 1)
        else
          SQLite3C.sqlite3_finalize(stmt)
          raise DBError, "cannot bind a #{v.class}"
        end
      end
    end

    def self.column(stmt, i)
      case SQLite3C.sqlite3_column_type(stmt, i)
      when SQLite3C::INTEGER then SQLite3C.sqlite3_column_int64(stmt, i)
      when SQLite3C::FLOAT then SQLite3C.sqlite3_column_double(stmt, i)
      when SQLite3C::NULL then nil
      else SQLite3C.sqlite3_column_text(stmt, i)
      end
    end
  end
end
