# frozen_string_literal: true
# Model Context Protocol server over stdio: newline-delimited JSON-RPC 2.0. Tools mirror the CLI, and
# each project is exposed as a resource holding the same digest the SessionStart hook injects.
require "json"
require "pinky/store"
require "pinky/hooks"
require "pinky/identity"

module Pinky
  class MCP
    PROTOCOL_VERSION = "2025-06-18"

    def initialize(store, cwd = Dir.pwd)
      @store = store
      @cwd = cwd
    end

    # Reads messages until EOF; each line is one request or notification.
    def run(input, output)
      output.sync = true
      while (line = input.gets)
        reply = handle(line)
        output.write(reply + "\n") if reply
      end
      nil
    end

    # One message in, one JSON string out (nil for notifications and for unparseable input without an id).
    def handle(line)
      msg = JSON.parse(line)
      id = msg["id"]
      method = msg["method"].to_s
      params = msg["params"].is_a?(Hash) ? msg["params"] : {}
      return nil if id.nil? && method.start_with?("notifications/")
      result = dispatch(method, params)
      return nil if id.nil?
      JSON.generate({ "jsonrpc" => "2.0", "id" => id, "result" => result })
    rescue JSON::ParserError => e
      JSON.generate({ "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32700, "message" => "parse error: #{e.message}" } })
    rescue MethodNotFound => e
      JSON.generate({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32601, "message" => e.message } })
    rescue ArgumentError, DBError => e
      JSON.generate({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => -32602, "message" => e.message } })
    end

    class MethodNotFound < StandardError; end

    def dispatch(method, params)
      case method
      when "initialize"
        requested = params["protocolVersion"].to_s
        { "protocolVersion" => requested.empty? ? PROTOCOL_VERSION : requested,
          "capabilities" => { "tools" => {}, "resources" => {} },
          "serverInfo" => { "name" => "pinky", "version" => Pinky::VERSION } }
      when "ping" then {}
      when "tools/list" then { "tools" => tools }
      when "tools/call" then call_tool(params["name"].to_s, params["arguments"].is_a?(Hash) ? params["arguments"] : {})
      when "resources/list" then { "resources" => resources }
      when "resources/read" then read_resource(params["uri"].to_s)
      when "prompts/list" then { "prompts" => [] }
      else raise MethodNotFound, "method not found: #{method}"
      end
    end

    def tools
      [
        tool("pinky_search", "Search the local cross-project knowledge base (hybrid full-text and semantic). Returns matching facts with ids; use pinky_get for the full text.",
             { "query" => str("What you are working on, the error you see, or keywords"), "project" => str("Limit to one project"),
               "kind" => str("fact | gotcha | decision | task | note"), "tag" => str("Limit to one tag"),
               "mode" => str("hybrid (default) | fts | vector"), "limit" => int("Max results, default 10") }, ["query"]),
        tool("pinky_get", "Read one fact in full (markdown) by id.", { "id" => int("Fact id") }, ["id"]),
        tool("pinky_add", "Save a durable learning: a gotcha and its workaround, a decision and its reason, a non-obvious fact. One fact per call, a few lines of markdown.",
             { "body" => str("Markdown body; the first line or heading becomes the title unless title is given"),
               "title" => str("Short title"), "kind" => str("fact (default) | gotcha | decision | task | note"),
               "tags" => str("Comma separated lower-case tags"), "project" => str("Defaults to the current repository"),
               "agent" => str("Defaults to repo/branch"), "source" => str("Session id or origin") }, ["body"]),
        tool("pinky_list", "List recent facts, optionally filtered.", { "project" => str("Project"), "kind" => str("Kind"), "tag" => str("Tag"),
                                                                         "archived" => bool("Show archived instead of active"), "limit" => int("Default 20") }, []),
        tool("pinky_projects", "List projects and agents with fact counts.", {}, []),
        tool("pinky_archive", "Archive a fact (recoverable with restore).", { "id" => int("Fact id"), "restore" => bool("Restore instead of archive") }, ["id"])
      ]
    end

    def call_tool(name, args)
      text = case name
             when "pinky_search" then tool_search(args)
             when "pinky_get" then tool_get(args)
             when "pinky_add" then tool_add(args)
             when "pinky_list" then tool_list(args)
             when "pinky_projects" then tool_projects
             when "pinky_archive" then tool_archive(args)
             else return { "content" => [{ "type" => "text", "text" => "unknown tool: #{name}" }], "isError" => true }
             end
      { "content" => [{ "type" => "text", "text" => text }] }
    rescue ArgumentError, DBError => e
      { "content" => [{ "type" => "text", "text" => "error: #{e.message}" }], "isError" => true }
    end

    def tool_search(args)
      limit = args["limit"].nil? ? 10 : args["limit"].to_s.to_i
      rows = @store.search(args["query"].to_s, mode: opt(args, "mode") || "hybrid", project: opt(args, "project"),
                           kind: opt(args, "kind"), tag: opt(args, "tag"), limit: limit)
      return "no matches" if rows.empty?
      rows.map { |f| fact_summary(f) }.join("\n")
    end

    def tool_get(args)
      f = @store.get(args["id"].to_s.to_i)
      return "no fact ##{args["id"]}" unless f
      out = +""
      out << "# #{f["title"]}\n"
      out << "id: #{f["id"]} · kind: #{f["kind"]} · project: #{f["project"]} · agent: #{f["agent"]}"
      out << " · tags: #{f["tags"]}" unless f["tags"].to_s.empty?
      out << "\ncreated: #{f["created_at"]} · updated: #{f["updated_at"]}"
      out << " · archived: #{f["archived_at"]}" if f["archived_at"]
      out << "\n\n" << f["body"].to_s
      out
    end

    def tool_add(args)
      tags_arg = args["tags"]
      tags = tags_arg.is_a?(Array) ? tags_arg.map(&:to_s) : tags_arg.to_s.split(",")
      id, created = @store.add(args["body"].to_s, title: opt(args, "title"), kind: opt(args, "kind") || "fact", tags: tags,
                               project: opt(args, "project") || Identity.project(@cwd), agent: opt(args, "agent") || Identity.agent(@cwd),
                               source: opt(args, "source") || "mcp")
      created ? "added ##{id}" : "already present as ##{id}"
    end

    def tool_list(args)
      limit = args["limit"].nil? ? 20 : args["limit"].to_s.to_i
      rows = @store.list(project: opt(args, "project"), kind: opt(args, "kind"), tag: opt(args, "tag"), archived: args["archived"] == true, limit: limit)
      return "no facts" if rows.empty?
      rows.map { |f| fact_summary(f) }.join("\n")
    end

    def tool_projects
      out = +""
      out << "projects:\n"
      @store.projects.each { |r| out << "  #{r["project"]}: #{r["n"]}\n" }
      out << "agents:\n"
      @store.agents.each { |r| out << "  #{r["agent"]}: #{r["n"]}\n" }
      out
    end

    def tool_archive(args)
      id = args["id"].to_s.to_i
      if args["restore"] == true
        @store.restore(id) ? "restored ##{id}" : "no archived fact ##{id}"
      else
        @store.archive(id) ? "archived ##{id}" : "no active fact ##{id}"
      end
    end

    def resources
      @store.projects.map do |r|
        name = r["project"].to_s
        { "uri" => "pinky://project/#{name}", "name" => "pinky facts: #{name}", "mimeType" => "text/markdown",
          "description" => "#{r["n"]} facts recorded for project #{name}" }
      end
    end

    def read_resource(uri)
      prefix = "pinky://project/"
      raise ArgumentError, "unknown resource: #{uri}" unless uri.start_with?(prefix)
      name = uri[prefix.size, uri.size - prefix.size].to_s
      digest = Hooks.new(@store, nil, nil).session_context(name)
      { "contents" => [{ "uri" => uri, "mimeType" => "text/markdown", "text" => digest }] }
    end

    def fact_summary(f)
      line = +""
      line << "##{f["id"]} [#{f["kind"]}] #{f["title"]} (#{f["project"]}"
      line << ", #{f["tags"]}" unless f["tags"].to_s.empty?
      line << ")"
      line << " via #{f["via"]}" if f["via"]
      line
    end

    def opt(args, key)
      v = args[key].to_s.strip
      v.empty? ? nil : v
    end

    def tool(name, description, properties, required)
      schema = { "type" => "object", "properties" => properties }
      schema["required"] = required unless required.empty?
      { "name" => name, "description" => description, "inputSchema" => schema }
    end

    def str(description) = { "type" => "string", "description" => description }
    def int(description) = { "type" => "integer", "description" => description }
    def bool(description) = { "type" => "boolean", "description" => description }
  end
end
