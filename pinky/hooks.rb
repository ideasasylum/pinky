# frozen_string_literal: true
# Claude Code hook handlers. Each reads the hook's JSON from stdin and writes the JSON Claude Code expects:
# SessionStart and UserPromptSubmit add context, Stop may ask the model to save learnings before it ends.
require "json"
require "pinky/store"
require "pinky/identity"

module Pinky
  class Hooks
    SESSION_FACTS = 12
    SESSION_CHARS = 4000
    PROMPT_FACTS = 5
    MIN_PROMPT_CHARS = 40
    VEC_ONLY_MAX_DISTANCE = 0.55
    VEC_WITH_FTS_MAX_DISTANCE = 0.75
    NUDGE_TURNS = 8
    NUDGE_EDITS = 3

    def self.kind_rank(kind)
      case kind
      when "gotcha" then 0
      when "decision" then 1
      when "fact" then 2
      when "task" then 3
      else 4
      end
    end

    def initialize(store, out, err)
      @store = store
      @out = out
      @err = err
    end

    def run(event, input_json, now: Store.now)
      input = input_json.to_s.strip.empty? ? {} : JSON.parse(input_json)
      case event
      when "session-start" then session_start(input, now)
      when "prompt" then prompt(input, now)
      when "stop" then stop(input, now)
      else
        @err.puts "unknown hook event: #{event}"
        2
      end
    rescue JSON::ParserError => e
      @err.puts "brain hook: bad input JSON: #{e.message}"
      0
    end

    def session_start(input, now)
      cwd = input["cwd"].to_s
      cwd = Dir.pwd if cwd.empty?
      project = Identity.project(cwd)
      agent = Identity.agent(cwd)
      session_id = input["session_id"].to_s
      @store.record_session(session_id, project: project, agent: agent, now: now) unless session_id.empty?
      context = session_context(project)
      emit_context("SessionStart", context)
      0
    end

    def prompt(input, now)
      text = input["prompt"].to_s.strip
      session_id = input["session_id"].to_s
      @store.bump_session(session_id, now: now) unless session_id.empty?
      return 0 if text.size < MIN_PROMPT_CHARS || text.start_with?("/") || text.start_with?("!")
      cwd = input["cwd"].to_s
      cwd = Dir.pwd if cwd.empty?
      project = Identity.project(cwd)
      facts = relevant_facts(text, project)
      return 0 if facts.empty?
      lines = ["pinky recall: facts from the knowledge base that may be relevant to this request."]
      facts.each { |f| lines << fact_line(f, 240) }
      lines << "Show one in full with `brain show <id>`; search with `brain search \"...\"`."
      emit_context("UserPromptSubmit", lines.join("\n"))
      0
    end

    def stop(input, now)
      return 0 if input["stop_hook_active"] == true
      session_id = input["session_id"].to_s
      return 0 if session_id.empty?
      session = @store.session(session_id)
      if session.nil?
        cwd = input["cwd"].to_s
        cwd = Dir.pwd if cwd.empty?
        @store.record_session(session_id, project: Identity.project(cwd), agent: Identity.agent(cwd), now: now)
        session = @store.session(session_id)
      end
      return 0 if session.nil? || session["nudged_at"] || session["saved"].to_s.to_i > 0
      turns = session["turns"].to_s.to_i
      edits = count_edits(input["transcript_path"].to_s)
      return 0 unless turns >= NUDGE_TURNS || edits >= NUDGE_EDITS
      @store.mark_nudged(session_id, now: now)
      reason = "pinky: this session has done real work (#{turns} prompts, #{edits} file edits) and nothing was saved to " \
               "the shared knowledge base. If you learned anything durable that a future session or another project " \
               "would want (a gotcha, a decision and its reason, a non-obvious fact about this codebase or its tools), " \
               "save each one now with `brain add --kind gotcha|decision|fact|note --tags a,b --source #{session_id}` " \
               "and a short markdown body on stdin (heredoc). One fact per call; skip anything derivable from the " \
               "code or git history. If nothing is worth keeping, finish as normal. This reminder appears once per session."
      @out.puts JSON.generate({ "decision" => "block", "reason" => reason })
      0
    end

    # The digest injected at SessionStart: this project's facts, gotchas and decisions first, then the rest.
    def session_context(project)
      total = @store.count
      project_count = @store.count(project: project)
      recent = @store.list(project: project, limit: 40)
      facts = []
      [0, 1, 2, 3, 4].each do |rank|
        recent.each { |f| facts << f if Hooks.kind_rank(f["kind"].to_s) == rank }
      end
      facts = facts.first(SESSION_FACTS)
      lines = []
      if project_count == 0
        lines << "pinky knowledge base: no facts for project \"#{project}\" yet (#{total} facts across #{@store.projects.size} other projects)."
      else
        lines << "pinky knowledge base: #{project_count} facts for project \"#{project}\" (#{total} in total). The most important ones:"
        used = lines[0].size
        facts.each do |f|
          line = fact_line(f, 300)
          break if used + line.size > SESSION_CHARS
          lines << line
          used += line.size
        end
      end
      lines << "Search across all projects with `brain search \"<query>\" [--project P]` (hybrid full-text and semantic), " \
               "read one with `brain show <id>`, and save durable learnings with `brain add` (or the /pinky-remember skill)."
      lines.join("\n")
    end

    def relevant_facts(text, project)
      scoped = @store.search(text, project: project, limit: 8)
      global = @store.search(text, limit: 8)
      seen = {}
      picked = []
      (scoped + global).each do |f|
        id = f["id"].to_s.to_i
        next if seen[id]
        seen[id] = true
        picked << f if relevant?(f)
      end
      picked.first(PROMPT_FACTS)
    end

    def relevant?(f)
      distance = f["distance"]
      via = f["via"].to_s
      if distance.nil?
        via.include?("fts")
      elsif via.include?("fts")
        distance.to_f <= VEC_WITH_FTS_MAX_DISTANCE
      else
        distance.to_f <= VEC_ONLY_MAX_DISTANCE
      end
    end

    # One line per fact; a leading markdown heading that repeats the title is dropped from the body.
    def fact_line(f, max)
      title = f["title"].to_s
      lines = f["body"].to_s.split("\n")
      lines.shift if !lines.empty? && lines[0].to_s.strip.sub(/\A#+\s*/, "") == title
      body = lines.join(" ").gsub(/\s+/, " ").strip
      body = "#{body[0, max - 3]}..." if body.size > max
      tags = f["tags"].to_s.empty? ? "" : " [#{f["tags"]}]"
      "- ##{f["id"]} (#{f["kind"]}, #{f["project"]}#{tags}) #{f["title"]}: #{body}"
    end

    def count_edits(path)
      return 0 if path.empty? || !File.exist?(path)
      n = 0
      File.read(path).split("\n").each do |line|
        n += 1 if line.include?("\"name\":\"Edit\"") || line.include?("\"name\":\"Write\"") || line.include?("\"name\":\"MultiEdit\"") || line.include?("\"name\":\"NotebookEdit\"")
      end
      n
    end

    def emit_context(event, text)
      @out.puts JSON.generate({ "hookSpecificOutput" => { "hookEventName" => event, "additionalContext" => text } })
      nil
    end
  end
end
