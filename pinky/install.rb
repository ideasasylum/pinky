# frozen_string_literal: true
# Installs the Claude Code integration: three hook entries merged into ~/.claude/settings.json and two
# skills under ~/.claude/skills. Idempotent; reports what it changed.
require "json"

module Pinky
  module Install
    EVENTS = { "SessionStart" => "session-start", "UserPromptSubmit" => "prompt", "Stop" => "stop" }.freeze

    REMEMBER_SKILL = <<~'MD'
      ---
      name: pinky-remember
      description: Save durable learnings from this session to pinky, the local cross-project knowledge base. Use after finishing a piece of work, when a gotcha or decision came up, or when asked to remember something.
      ---

      # Remember

      Write the learnings from this session into pinky so other sessions and other projects benefit.

      ## What to save

      Only things a future session could not derive from the code, git history or CLAUDE.md:
      - **gotcha**: a trap and its workaround (a tool or library behaving unexpectedly, a build quirk).
      - **decision**: a choice and the reason behind it, especially when the alternative looked reasonable.
      - **fact**: a non-obvious property of the project, its tools, its environment or its people's preferences.
      - **task**: an open piece of work worth resuming later, with enough context to pick it up.
      - **note**: anything else worth keeping.

      One fact per entry. Two to eight lines of markdown: what, why it matters, how to apply it. Name concrete
      files, commands or versions. Prefer specific over general. Skip what is already there:
      `brain search "<topic>"` first.

      ## How

      ```bash
      brain add --kind gotcha --tags spinel,ffi --source "$CLAUDE_SESSION_ID" <<'EOF'
      # Spinel :str FFI results stop at the first NUL
      `ffi_func` return type `:str` builds the String with strlen. Blobs must go through a C shim that binds
      them directly (see native/pinky_shim.c), never through a Ruby String.
      EOF
      ```

      `--project` and `--agent` default to the current repository and branch; pass them only to file a
      fact under another project. Tags are lower-case, comma separated. After saving, list what you added.
    MD

    RECALL_SKILL = <<~'MD'
      ---
      name: pinky-recall
      description: Search pinky, the local cross-project knowledge base, for gotchas, decisions and facts recorded by other sessions and projects. Use before starting on an unfamiliar tool, library or area, or when asked what is known about something.
      ---

      # Recall

      Query the knowledge base and bring the relevant facts into this conversation.

      ```bash
      brain search "<what you are about to do or the error you see>"            # all projects, hybrid search
      brain search "<query>" --project <name>                                   # one project
      brain search "<query>" --tag spinel --limit 20                            # by tag
      brain show <id>                                                            # full text of one fact
      brain list --project <name> --kind gotcha                                  # browse
      ```

      Search is hybrid (full-text plus semantic), so describe the problem in plain words; exact identifiers
      also work. Read the top hits with `brain show`, then summarise for the user what applies and cite the
      fact ids so they can be corrected or archived (`brain rm <id>`) if wrong.
    MD

    def self.hook_entry(bin, event)
      { "hooks" => [{ "type" => "command", "command" => "#{bin} hook #{EVENTS[event]}", "timeout" => 10 }] }
    end

    # Returns the events that were added (the others were already present).
    def self.merge_hooks(settings, bin)
      hooks = settings["hooks"]
      unless hooks.is_a?(Hash)
        hooks = {}
        settings["hooks"] = hooks
      end
      added = []
      EVENTS.each_key do |event|
        entries = hooks[event]
        unless entries.is_a?(Array)
          entries = []
          hooks[event] = entries
        end
        next if entries.any? { |e| hook_present?(e) }
        entries << hook_entry(bin, event)
        added << event
      end
      added
    end

    def self.hook_present?(entry)
      return false unless entry.is_a?(Hash)
      list = entry["hooks"]
      return false unless list.is_a?(Array)
      list.any? { |h| h.is_a?(Hash) && h["command"].to_s.include?(" hook ") && (h["command"].to_s.include?("brain") || h["command"].to_s.include?("pinky")) }
    end

    def self.run(home, bin, out)
      claude_dir = "#{home}/.claude"
      Dir.mkdir(claude_dir) unless Dir.exist?(claude_dir)
      settings_path = "#{claude_dir}/settings.json"
      settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
      settings = {} unless settings.is_a?(Hash)
      added = merge_hooks(settings, bin)
      if added.empty?
        out.puts "hooks already present in #{settings_path}"
      else
        write(settings_path, JSON.pretty_generate(settings) + "\n")
        out.puts "added #{added.join(", ")} hooks to #{settings_path}"
      end
      skills_dir = "#{claude_dir}/skills"
      Dir.mkdir(skills_dir) unless Dir.exist?(skills_dir)
      { "pinky-remember" => REMEMBER_SKILL, "pinky-recall" => RECALL_SKILL }.each do |name, content|
        dir = "#{skills_dir}/#{name}"
        Dir.mkdir(dir) unless Dir.exist?(dir)
        path = "#{dir}/SKILL.md"
        if File.exist?(path) && File.read(path) == content
          out.puts "skill #{name} up to date"
        else
          write(path, content)
          out.puts "wrote #{path}"
        end
      end
      nil
    end

    def self.write(path, content)
      f = File.open(path, "w")
      f.write(content)
      f.close
      nil
    end
  end
end
