# frozen_string_literal: true
# Drives the web UI as request string -> response string, no sockets. The socket loop is exercised by
# scripts/check.sh with curl against the compiled binary.
require "pinky"
require "pinky/web"
require "tmpdir"

$stdout.sync = true
tmp = Dir.mktmpdir("pinky-web-test")
store = Pinky::Store.open("#{tmp}/t.db")
t = "2026-09-08T00:00:00Z"
store.add("# Frozen strings\nUnder Spinel every string literal is frozen; use `+\"\"` and `<<`.", agent: "chips/spike", project: "chips", kind: "gotcha", tags: ["spinel"], now: t)
store.add("Use WAL & a busy timeout when <several> processes share one file.", title: "WAL for shared databases", agent: "pinky/spike", project: "pinky", kind: "decision", tags: ["sqlite"], now: "2026-09-08T00:01:00Z")
web = Pinky::Web.new(store)

def request(web, method, target, body = nil)
  raw = +""
  raw << "#{method} #{target} HTTP/1.1\r\nHost: localhost\r\n"
  raw << "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: #{body.bytesize}\r\n" if body
  raw << "\r\n"
  raw << body if body
  req = Pinky::HTTP.parse(raw)
  return "unparseable" if req.nil?
  web.call(req)
end

def summary(res)
  "#{res.status} #{res.headers["content-type"].to_s.split(";")[0]}#{res.headers["location"] ? " -> #{res.headers["location"]}" : ""}"
end

def has(res, *needles) = needles.map { |n| res.body.include?(n) }.join(",")

puts "-- parsing"
req = Pinky::HTTP.parse("GET /a%20b/c?q=hello+world%21&project=chips&empty=&flag HTTP/1.1\r\nHost: x\r\nX-Thing:  spaced  \r\n\r\n")
puts "method=#{req.method} path=#{req.path} q=#{req.query["q"]} project=#{req.query["project"]} empty=#{req.query["empty"].inspect} flag=#{req.query["flag"].inspect} hdr=#{req.header("x-thing")}"
puts "bad: #{Pinky::HTTP.parse("GARBAGE\r\n\r\n").inspect} #{Pinky::HTTP.parse("GET / HTTP/1.1").inspect}"
puts "unescape utf8: #{Pinky::HTTP.unescape("caf%C3%A9+%E4%B8%AD")} escape: #{Pinky::HTTP.escape("a b/ü~")}"
puts "form: #{Pinky::HTTP.parse_query("title=A+%26+B&body=line1%0Aline2&tags=x%2Cy").inspect}"
res = Pinky::HTTP::Response.html("<p>hi</p>")
puts "response head: #{res.to_s.split("\r\n\r\n")[0].split("\r\n").join(" | ")}"

puts "-- index"
res = request(web, "GET", "/")
puts "#{summary(res)} title,rows,new-link: #{has(res, "<title>Facts", "/facts/1", "/facts/2", "/facts/new")}"
puts "escaped: #{has(request(web, "GET", "/facts/2"), "&lt;several&gt;", "WAL &amp; a busy")}"
res = request(web, "GET", "/?q=frozen+strings")
puts "search: #{summary(res)} #{has(res, "Search: frozen strings", "/facts/1", "via")} second fact present: #{res.body.include?("/facts/2\"")}"
res = request(web, "GET", "/?project=pinky")
puts "project filter: #{has(res, "/facts/2\"")},#{res.body.include?("/facts/1\"")}"
res = request(web, "GET", "/?kind=gotcha")
puts "kind filter: #{has(res, "/facts/1\"")},#{res.body.include?("/facts/2\"")}"
res = request(web, "GET", "/?tag=sqlite")
puts "tag filter: #{has(res, "/facts/2\"")},#{res.body.include?("/facts/1\"")}"

puts "-- show"
res = request(web, "GET", "/facts/1")
puts "#{summary(res)} #{has(res, "<h1>Frozen strings</h1>", "<code>+&quot;&quot;</code>", "/facts/1/edit", "/facts/1/archive")}"
puts "missing: #{summary(request(web, "GET", "/facts/99"))} #{summary(request(web, "GET", "/nope"))} #{summary(request(web, "DELETE", "/facts/1"))}"
puts "css: #{summary(request(web, "GET", "/style.css"))}"

puts "-- edit"
res = request(web, "GET", "/facts/2/edit")
puts "#{summary(res)} #{has(res, "name=\"title\" value=\"WAL for shared databases\"", "option value=\"decision\" selected", "value=\"sqlite\"")}"
res = request(web, "POST", "/facts/2", "title=WAL+everywhere&kind=fact&tags=sqlite%2Cwal&body=New+%3Cbody%3E+text")
puts "post: #{summary(res)}"
f = store.get(2)
puts "stored: #{f["title"]} | #{f["kind"]} | #{f["tags"]} | #{f["body"]}"
res = request(web, "POST", "/facts/2", "title=&kind=rumour&tags=&body=x")
puts "bad kind: #{summary(res)} #{has(res, "unknown kind rumour")}"
puts "missing: #{summary(request(web, "POST", "/facts/99", "title=x&kind=fact&tags=&body=x"))}"

puts "-- new"
res = request(web, "GET", "/facts/new")
puts "#{summary(res)} #{has(res, "action=\"/facts\"", "name=\"project\"")}"
res = request(web, "POST", "/facts", "title=&kind=note&tags=a%2C+B&body=Third+fact+body&project=misc&agent=")
puts "create: #{summary(res)}"
f = store.get(3)
puts "created: #{f["title"]} | #{f["kind"]} | #{f["tags"]} | #{f["project"]} | #{f["agent"]} | #{f["source"]}"
res = request(web, "POST", "/facts", "title=&kind=note&tags=&body=Third+fact+body&project=misc&agent=")
puts "duplicate: #{summary(res)}"
res = request(web, "POST", "/facts", "title=&kind=note&tags=&body=&project=misc&agent=")
puts "empty: #{summary(res)} #{has(res, "empty body")}"

puts "-- archive / restore / purge"
puts "archive: #{summary(request(web, "POST", "/facts/1/archive", "back=%2F%3Fproject%3Dchips"))} active=#{store.count} archived=#{store.count(archived: true)}"
res = request(web, "GET", "/?archived=1")
puts "archived list: #{has(res, "/facts/1\"", "Archived facts")},#{res.body.include?("/facts/2\"")}"
res = request(web, "GET", "/facts/1")
puts "archived show: #{has(res, "archived 20", "/facts/1/restore", "/facts/1/purge")} edit link: #{res.body.include?("/facts/1/edit")}"
puts "restore: #{summary(request(web, "POST", "/facts/1/restore"))} active=#{store.count}"
puts "bulk: #{summary(request(web, "POST", "/archive", "ids=1%2C3%2C99"))} active=#{store.count} archived=#{store.count(archived: true)}"
puts "purge: #{summary(request(web, "POST", "/facts/3/purge"))} gone=#{store.get(3).nil?}"

puts "-- api"
res = request(web, "GET", "/api/facts?q=WAL&limit=5")
rows = JSON.parse(res.body)
puts "#{summary(res)} n=#{rows.size} first=#{rows[0] ? rows[0]["id"] : nil} keys=#{rows[0] ? (rows[0].keys.include?("score") && rows[0].keys.include?("body")) : nil}"
res = request(web, "GET", "/api/facts?project=pinky")
puts "list: #{JSON.parse(res.body).map { |r| r["id"] }.inspect}"
res = request(web, "GET", "/api/facts/2")
puts "one: #{summary(res)} #{JSON.parse(res.body)["title"]}"
puts "missing: #{summary(request(web, "GET", "/api/facts/99"))}"
puts "projects: #{JSON.parse(request(web, "GET", "/api/projects").body).map { |r| r["project"] }.inspect}"
store.close
puts "ok"
