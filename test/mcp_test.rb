# frozen_string_literal: true
require "pinky"
require "pinky/mcp"
require "tmpdir"

$stdout.sync = true
tmp = Dir.mktmpdir("pinky-mcp-test")
store = Pinky::Store.open("#{tmp}/t.db")
t = "2026-09-08T00:00:00Z"
store.add("Under Spinel every string literal is frozen.", title: "Frozen strings", agent: "chips/spike", project: "chips", kind: "gotcha", tags: ["spinel"], now: t)
store.add("Use WAL and a busy timeout when processes share a database.", title: "WAL mode", agent: "pinky/spike", project: "pinky", kind: "decision", tags: ["sqlite"], now: "2026-09-08T00:01:00Z")
mcp = Pinky::MCP.new(store, "#{tmp}/somewhere")

def rpc(mcp, id, method, params = nil)
  msg = { "jsonrpc" => "2.0", "method" => method }
  msg["id"] = id unless id.nil?
  msg["params"] = params if params
  reply = mcp.handle(JSON.generate(msg))
  reply.nil? ? nil : JSON.parse(reply)
end

r = rpc(mcp, 1, "initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {}, "clientInfo" => { "name" => "test" } })
puts "initialize: id=#{r["id"]} version=#{r["result"]["protocolVersion"]} caps=#{r["result"]["capabilities"].keys.sort.join(",")} server=#{r["result"]["serverInfo"]["name"]}"
puts "initialized notification: #{rpc(mcp, nil, "notifications/initialized").inspect}"
puts "ping: #{rpc(mcp, 2, "ping")["result"].inspect}"
r = rpc(mcp, 3, "tools/list")
puts "tools: #{r["result"]["tools"].map { |x| x["name"] }.join(" ")}"
puts "search schema required: #{r["result"]["tools"][0]["inputSchema"]["required"].inspect}"

r = rpc(mcp, 4, "tools/call", { "name" => "pinky_search", "arguments" => { "query" => "frozen literal" } })
puts "search: #{r["result"]["content"][0]["text"]}"
r = rpc(mcp, 5, "tools/call", { "name" => "pinky_search", "arguments" => { "query" => "frozen", "project" => "pinky" } })
puts "search filtered: #{r["result"]["content"][0]["text"]}"
r = rpc(mcp, 6, "tools/call", { "name" => "pinky_get", "arguments" => { "id" => 2 } })
puts "get: #{r["result"]["content"][0]["text"].split("\n")[0]} | #{r["result"]["content"][0]["text"].split("\n")[1]}"
r = rpc(mcp, 7, "tools/call", { "name" => "pinky_get", "arguments" => { "id" => 99 } })
puts "get missing: #{r["result"]["content"][0]["text"]}"
r = rpc(mcp, 8, "tools/call", { "name" => "pinky_add", "arguments" => { "body" => "# Via MCP\nA fact added through the protocol.", "kind" => "note", "tags" => ["mcp", "Test"] } })
puts "add: #{r["result"]["content"][0]["text"]}"
f = store.get(3)
puts "added: #{f["title"]} | #{f["kind"]} | #{f["tags"]} | #{f["project"]} | #{f["agent"]} | #{f["source"]}"
r = rpc(mcp, 9, "tools/call", { "name" => "pinky_add", "arguments" => { "body" => "# Via MCP\nA fact added through the protocol.", "project" => "somewhere" } })
puts "add dup: #{r["result"]["content"][0]["text"]}"
r = rpc(mcp, 10, "tools/call", { "name" => "pinky_add", "arguments" => { "body" => "x", "kind" => "rumour" } })
puts "add bad kind: isError=#{r["result"]["isError"]} #{r["result"]["content"][0]["text"]}"
r = rpc(mcp, 11, "tools/call", { "name" => "pinky_list", "arguments" => { "project" => "chips" } })
puts "list: #{r["result"]["content"][0]["text"]}"
r = rpc(mcp, 12, "tools/call", { "name" => "pinky_projects", "arguments" => {} })
puts "projects: #{r["result"]["content"][0]["text"].split("\n").join(" / ")}"
r = rpc(mcp, 13, "tools/call", { "name" => "pinky_archive", "arguments" => { "id" => 3 } })
puts "archive: #{r["result"]["content"][0]["text"]} active=#{store.count}"
r = rpc(mcp, 14, "tools/call", { "name" => "pinky_archive", "arguments" => { "id" => 3, "restore" => true } })
puts "restore: #{r["result"]["content"][0]["text"]} active=#{store.count}"
r = rpc(mcp, 15, "tools/call", { "name" => "nope", "arguments" => {} })
puts "unknown tool: isError=#{r["result"]["isError"]}"

r = rpc(mcp, 16, "resources/list")
puts "resources: #{r["result"]["resources"].map { |x| x["uri"] }.sort.join(" ")}"
r = rpc(mcp, 17, "resources/read", { "uri" => "pinky://project/chips" })
puts "read: #{r["result"]["contents"][0]["mimeType"]} #{r["result"]["contents"][0]["text"].split("\n")[0]}"
r = rpc(mcp, 18, "resources/read", { "uri" => "file:///etc/passwd" })
puts "read bad: error=#{r["error"]["code"]} #{r["error"]["message"]}"
r = rpc(mcp, 19, "frobnicate")
puts "unknown method: error=#{r["error"]["code"]} #{r["error"]["message"]}"
puts "notification unknown: #{rpc(mcp, nil, "notifications/cancelled").inspect}"
r = JSON.parse(mcp.handle("{not json"))
puts "bad json: error=#{r["error"]["code"]}"
r = rpc(mcp, "str-id", "ping")
puts "string id echoed: #{r["id"]}"
store.close
puts "ok"
