# frozen_string_literal: true
module SQLite3C
  ffi_const :OK, 0
  ffi_const :ROW, 100
  ffi_const :DONE, 101
  ffi_const :INTEGER, 1
  ffi_const :FLOAT, 2
  ffi_const :TEXT, 3
  ffi_const :BLOB, 4
  ffi_const :NULL, 5
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
  ffi_func :pinky_vec_init,       [:ptr],                     :int
  ffi_func :pinky_bind_f32,       [:ptr, :int, :float_array, :size_t], :int
  ffi_buffer :db_out, 8
  ffi_buffer :stmt_out, 8
  ffi_read_ptr :read_ptr, 0
end

class DBError < StandardError; end

class DB
  def initialize(path)
    rc = SQLite3C.sqlite3_open_v2(path, SQLite3C.db_out, 6, nil)
    raise DBError, "open failed: #{rc}" unless rc == SQLite3C::OK
    @db = SQLite3C.read_ptr(SQLite3C.db_out)
    rc = SQLite3C.pinky_vec_init(@db)
    raise DBError, "vec init failed: #{rc}" unless rc == SQLite3C::OK
  end

  def exec(sql)
    rc = SQLite3C.sqlite3_exec(@db, sql, nil, nil, nil)
    raise DBError, SQLite3C.sqlite3_errmsg(@db) unless rc == SQLite3C::OK
    nil
  end

  # binds: Integer, Float, String, nil, or Array<Float> (bound as a float32 blob)
  def query(sql, binds = [])
    stmt = prepare(sql)
    bind_all(stmt, binds)
    n = SQLite3C.sqlite3_column_count(stmt)
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
    raise DBError, SQLite3C.sqlite3_errmsg(@db) unless rc == SQLite3C::DONE
    rows
  end

  def run(sql, binds = [])
    query(sql, binds)
    nil
  end

  private

  def prepare(sql)
    rc = SQLite3C.sqlite3_prepare_v2(@db, sql, -1, SQLite3C.stmt_out, nil)
    raise DBError, SQLite3C.sqlite3_errmsg(@db) unless rc == SQLite3C::OK
    SQLite3C.read_ptr(SQLite3C.stmt_out)
  end

  def bind_all(stmt, binds)
    binds.each_with_index do |v, i|
      case v
      when Integer then SQLite3C.sqlite3_bind_int64(stmt, i + 1, v)
      when Float then SQLite3C.sqlite3_bind_double(stmt, i + 1, v)
      when String then SQLite3C.sqlite3_bind_text(stmt, i + 1, v, v.bytesize, -1)
      when Array then SQLite3C.pinky_bind_f32(stmt, i + 1, v, v.size)
      when nil then SQLite3C.sqlite3_bind_null(stmt, i + 1)
      else raise DBError, "cannot bind #{v.class}"
      end
    end
  end

  def column(stmt, i)
    case SQLite3C.sqlite3_column_type(stmt, i)
    when SQLite3C::INTEGER then SQLite3C.sqlite3_column_int64(stmt, i)
    when SQLite3C::FLOAT then SQLite3C.sqlite3_column_double(stmt, i)
    when SQLite3C::NULL then nil
    else SQLite3C.sqlite3_column_text(stmt, i)
    end
  end
end

$stdout.sync = true
db = DB.new(":memory:")
puts "sqlite #{db.query("select sqlite_version()")[0][0]} vec #{db.query("select vec_version()")[0][0]}"

db.exec("create table facts(id integer primary key, title text, body text)")
db.exec("create virtual table facts_fts using fts5(title, body, content='', tokenize='porter unicode61')")
db.exec("create virtual table facts_vec using vec0(fact_id integer primary key, embedding float[4] distance_metric=cosine)")

facts = [
  ["Spinel strings", "String literals are always frozen under Spinel; build buffers with +\"\" and <<", [1.0, 0.0, 0.0, 0.0]],
  ["SQLite WAL", "Use WAL journal mode and a busy timeout when several processes share one database", [0.0, 1.0, 0.0, 0.0]],
  ["FFI blobs", "Binary blobs must go through a C shim because :str truncates at NUL", [0.7, 0.0, 0.7, 0.0]]
]
id = 1
facts.each do |f|
  title = f[0].to_s
  body = f[1].to_s
  vec = f[2]
  db.run("insert into facts(id, title, body) values (?, ?, ?)", [id, title, body])
  db.run("insert into facts_fts(rowid, title, body) values (?, ?, ?)", [id, title, body])
  db.run("insert into facts_vec(fact_id, embedding) values (?, ?)", [id, vec]) if vec.is_a?(Array)
  id += 1
end

puts "fts:"
db.query("select rowid, rank from facts_fts where facts_fts match ? order by rank", ["frozen OR blob"]).each { |r| puts "  #{r[0]} #{r[1]}" }

puts "knn:"
q = [0.9, 0.0, 0.4, 0.0]
db.query("select fact_id, distance from facts_vec where embedding match ? and k = 2", [q]).each { |r| puts "  #{r[0]} #{r[1]}" }

puts "rrf:"
sql = <<~SQL
  with vec_matches as (
    select fact_id, row_number() over (order by distance) as rn
    from facts_vec where embedding match ? and k = 10),
  fts_matches as (
    select rowid as fact_id, row_number() over (order by rank) as rn
    from facts_fts where facts_fts match ? limit 10)
  select f.id, f.title,
    coalesce(1.0 / (60 + fts_matches.rn), 0.0) + coalesce(1.0 / (60 + vec_matches.rn), 0.0) as score
  from fts_matches full outer join vec_matches using (fact_id)
  join facts f on f.id = fact_id
  order by score desc
SQL
db.query(sql, [q, "frozen OR blob"]).each { |r| puts "  #{r[0]} #{r[1]} #{r[2]}" }
puts "ok"
