# frozen_string_literal: true
# Command-line surface. Every command is a thin call into Store; output is text for people or JSON with
# --json for hooks, skills and scripts.
require "json"
require "pinky/args"
require "pinky/store"
require "pinky/identity"
require "pinky/embedder"
require "pinky/hooks"
require "pinky/install"
require "pinky/web"
require "pinky/mcp"

module Pinky
  class CLI
    USAGE = <<~TEXT
      pinky <command> [options]

      Commands:
        add        Add a fact (body from stdin or --file). Options: --title --kind --tags a,b --project --agent --source
        search     Search facts: brain search <query> [--mode hybrid|fts|vector] [--project P] [--agent A] [--tag T] [--kind K] [--limit N]
        show       Show one fact: brain show <id>
        list       List facts: [--project P] [--agent A] [--tag T] [--kind K] [--archived] [--limit N]
        edit       Update a fact: brain edit <id> [--title T] [--kind K] [--tags a,b] [--file F | --stdin]
        rm         Archive a fact (recoverable): brain rm <id>
        restore    Restore an archived fact: brain restore <id>
        purge      Delete a fact for good: brain purge <id>
        projects   List projects with fact counts
        agents     List agents with fact counts
        tags       List tags with fact counts
        setup      Create the database and download the embedding model (needs curl)
        reindex    Re-embed every fact with the current model
        install-hooks  Add the Claude Code hooks to ~/.claude/settings.json and install the skills [--bin PATH]
        hook       Claude Code hook entry point: brain hook session-start|prompt|stop (reads the hook JSON on stdin)
        serve      Web UI and JSON API on http://127.0.0.1:4242/ [--port N] [--host H]
        mcp        Model Context Protocol server over stdio (register: claude mcp add --scope user pinky -- brain mcp)
        doctor     Show paths, versions and counts
        help

      Global options: --db PATH (or PINKY_DB), --json
    TEXT

    VALUE_OPTIONS = ["db", "title", "kind", "tags", "tag", "project", "agent", "source", "file", "mode", "limit", "bin", "port", "host"].freeze
    FLAG_OPTIONS = ["json", "archived", "stdin"].freeze

    def self.run(argv, out: $stdout, err: $stderr, stdin: $stdin)
      new(out, err, stdin).run(argv)
    end

    def initialize(out, err, stdin)
      @out = out
      @err = err
      @stdin = stdin
      @json = false
      @db_path = ENV["PINKY_DB"] || Identity.default_db_path
    end

    def run(argv)
      args = argv.map(&:to_s)
      cmd = args.empty? ? "" : args.shift.to_s
      opts, rest = Args.parse(args, VALUE_OPTIONS, FLAG_OPTIONS)
      @json = !opts["json"].nil?
      @db_path = opts["db"] if opts["db"]
      dispatch(cmd, opts, rest)
    rescue Args::Error => e
      @err.puts e.message
      2
    rescue DBError, ArgumentError => e
      @err.puts "error: #{e.message}"
      1
    end

    private

    def dispatch(cmd, opts, rest)
      case cmd
      when "add" then cmd_add(opts)
      when "search" then cmd_search(rest.join(" "), opts)
      when "show" then cmd_show(rest[0].to_s)
      when "list" then cmd_list(opts)
      when "edit" then cmd_edit(rest[0].to_s, opts)
      when "rm" then cmd_archive(rest[0].to_s)
      when "restore" then cmd_restore(rest[0].to_s)
      when "purge" then cmd_purge(rest[0].to_s)
      when "projects" then cmd_group(store.projects, "project")
      when "agents" then cmd_group(store.agents, "agent")
      when "tags" then cmd_group(store.tags, "tag")
      when "setup" then cmd_setup
      when "reindex" then cmd_reindex
      when "hook" then Hooks.new(store, @out, @err).run(rest[0].to_s, @stdin.read.to_s)
      when "install-hooks" then cmd_install(opts)
      when "serve"
        port = opts["port"] ? opts["port"].to_s.to_i : 4242
        HTTP::Server.new(Web.new(store), opts["host"] || "127.0.0.1", port).run(@err)
        0
      when "mcp"
        MCP.new(store).run(@stdin, @out)
        0
      when "doctor", "" then cmd_doctor
      when "help", "-h", "--help"
        @out.puts USAGE
        0
      else
        @err.puts "unknown command: #{cmd}"
        @err.puts USAGE
        2
      end
    end

    def store = @store ||= Store.open(@db_path, embedder: Pinky.embedder)

    def read_body(opts)
      file = opts["file"]
      return File.read(file.to_s) if file
      @stdin.read.to_s
    end

    def cmd_add(opts)
      body = read_body(opts)
      project = opts["project"] || Identity.project
      agent = opts["agent"] || Identity.agent
      tags = opts["tags"].to_s.split(",")
      source = opts["source"]
      id, created = store.add(body, agent: agent, project: project, title: opts["title"], kind: opts["kind"] || "fact",
                                tags: tags, source: source)
      store.mark_saved(source.to_s) if created && source
      if @json
        @out.puts JSON.generate({ "id" => id, "created" => created })
      else
        @out.puts(created ? "added ##{id}" : "already present as ##{id}")
      end
      0
    end

    def cmd_search(query, opts)
      limit = opts["limit"] ? opts["limit"].to_s.to_i : 10
      results = store.search(query, mode: opts["mode"] || "hybrid", project: opts["project"], agent: opts["agent"],
                             kind: opts["kind"], tag: opts["tag"], limit: limit)
      if @json
        @out.puts JSON.generate(results)
      elsif results.empty?
        @out.puts "no matches"
      else
        results.each { |f| @out.puts summary_line(f) }
      end
      0
    end

    def cmd_show(id)
      fact = store.get(id.to_i)
      return not_found(id) unless fact
      if @json
        @out.puts JSON.generate(fact)
      else
        @out.puts "# #{fact["title"]}"
        @out.puts "id: #{fact["id"]}  kind: #{fact["kind"]}  project: #{fact["project"]}  agent: #{fact["agent"]}"
        @out.puts "tags: #{fact["tags"]}" unless fact["tags"].to_s.empty?
        archived = fact["archived_at"] ? "  archived: #{fact["archived_at"]}" : ""
        @out.puts "created: #{fact["created_at"]}  updated: #{fact["updated_at"]}#{archived}"
        @out.puts
        @out.puts fact["body"]
      end
      0
    end

    def cmd_list(opts)
      limit = opts["limit"] ? opts["limit"].to_s.to_i : 50
      rows = store.list(project: opts["project"], agent: opts["agent"], kind: opts["kind"], tag: opts["tag"],
                        archived: !opts["archived"].nil?, limit: limit)
      if @json
        @out.puts JSON.generate(rows)
      elsif rows.empty?
        @out.puts "no facts"
      else
        rows.each { |f| @out.puts summary_line(f) }
      end
      0
    end

    def cmd_edit(id, opts)
      body = opts["file"] || opts["stdin"] ? read_body(opts) : nil
      body = nil if body && body.strip.empty?
      tags = opts["tags"] ? opts["tags"].to_s.split(",") : nil
      fact = store.update(id.to_i, body: body, title: opts["title"], kind: opts["kind"], tags: tags)
      return not_found(id) unless fact
      @out.puts(@json ? JSON.generate(fact) : "updated ##{fact["id"]}")
      0
    end

    def cmd_archive(id)
      return not_found(id) unless store.archive(id.to_i)
      @out.puts "archived ##{id}"
      0
    end

    def cmd_restore(id)
      return not_found(id) unless store.restore(id.to_i)
      @out.puts "restored ##{id}"
      0
    end

    def cmd_purge(id)
      return not_found(id) unless store.delete(id.to_i)
      @out.puts "deleted ##{id}"
      0
    end

    def cmd_group(rows, column)
      if @json
        @out.puts JSON.generate(rows)
      else
        rows.each { |r| @out.puts "#{r[column]}  #{r["n"]}" }
      end
      0
    end

    def cmd_doctor
      @out.puts "pinky #{Pinky::VERSION}"
      @out.puts "db: #{@db_path}"
      @out.puts "model: #{Pinky.model_dir}#{Model2Vec.available?(Pinky.model_dir) ? "" : " (missing; run brain setup)"}"
      @out.puts "project: #{Identity.project}  agent: #{Identity.agent}"
      s = store
      sqlite = s.db.first("SELECT sqlite_version() AS v")
      vec = s.db.first("SELECT vec_version() AS v")
      @out.puts "sqlite #{sqlite ? sqlite["v"] : "?"}, sqlite-vec #{vec ? vec["v"] : "?"}, schema v#{s.meta("schema_version")}"
      e = s.embedder
      if e
        @out.puts "embedder: #{e.name} (#{e.dim} dims)"
      elsif s.stale_embedder
        @out.puts "embedder: database was embedded with #{s.stale_embedder}; run brain reindex (full-text search only until then)"
      else
        @out.puts "embedder: none (full-text search only)"
      end
      @out.puts "facts: #{s.count} active, #{s.count(archived: true)} archived"
      0
    end

    def cmd_reindex
      embedder = Pinky.embedder
      unless embedder
        @err.puts "no embedding model at #{Pinky.model_dir}; run brain setup first"
        return 1
      end
      n = store.reindex(embedder)
      @out.puts "re-embedded #{n} facts with #{embedder.name}"
      0
    end

    def cmd_install(opts)
      bin = opts["bin"] || "brain"
      unless opts["bin"] || system("command -v brain >/dev/null 2>&1")
        @err.puts "warning: no `brain` on PATH; the hooks will fail until it is installed (or pass --bin /full/path/to/pinky)"
      end
      Install.run(ENV["HOME"].to_s, bin, @out)
      0
    end

    def cmd_setup
      dir = Pinky.model_dir
      Dir.mkdir(File.dirname(dir)) unless Dir.exist?(File.dirname(dir))
      Dir.mkdir(dir) unless Dir.exist?(dir)
      Model2Vec::FILES.each do |f|
        target = "#{dir}/#{f}"
        if File.exist?(target)
          @out.puts "have #{f}"
          next
        end
        url = "https://huggingface.co/#{Model2Vec::MODEL_NAME}/resolve/main/#{f}"
        @out.puts "fetching #{f}"
        ok = system("curl -fsSL -o '#{target}.part' '#{url}' && mv '#{target}.part' '#{target}'")
        unless ok
          @err.puts "download failed: #{url}"
          return 1
        end
      end
      embedder = Model2Vec.load(dir)
      @out.puts "model #{embedder.name} loaded (#{embedder.dim} dims)"
      s = Store.open(@db_path, embedder: embedder)
      if s.stale_embedder
        @out.puts "re-embedding #{s.reindex(embedder)} facts"
      elsif s.count > 0 && s.db.first("SELECT count(*) AS n FROM facts_vec")["n"].to_s.to_i == 0
        @out.puts "embedding #{s.reindex(embedder)} existing facts"
      end
      @out.puts "ready: #{@db_path}"
      0
    end

    def not_found(id)
      @err.puts "no fact ##{id}"
      1
    end

    def summary_line(f)
      line = +""
      line << "##{f["id"]}  [#{f["kind"]}] #{f["title"]}  (#{f["project"]}"
      line << ", #{f["tags"]}" unless f["tags"].to_s.empty?
      line << ")"
      line << "  via #{f["via"]}" if f["via"]
      line
    end
  end
end
