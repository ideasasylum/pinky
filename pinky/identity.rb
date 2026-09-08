# frozen_string_literal: true
# Who is writing and where: project and agent names derived from the working directory's git checkout.
# PINKY_PROJECT and PINKY_AGENT override; otherwise project is the repository directory name and agent is
# "<project>/<branch>". No env var carries the orca pane name, so this is the best stable identity we have.
module Pinky
  module Identity
    def self.default_db_path = "#{ENV["HOME"]}/.pinky/pinky.db"

    def self.project(cwd = Dir.pwd)
      env = ENV["PINKY_PROJECT"]
      return env if env && !env.empty?
      root = git_root(cwd)
      File.basename(root || cwd)
    end

    def self.agent(cwd = Dir.pwd)
      env = ENV["PINKY_AGENT"]
      return env if env && !env.empty?
      branch = git_branch(cwd)
      branch ? "#{project(cwd)}/#{branch}" : project(cwd)
    end

    # The main checkout for a worktree is what names the project, so worktrees of one repo share it.
    def self.git_root(cwd)
      out = `cd "#{cwd}" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null`.strip
      return nil if out.empty?
      common = out.end_with?("/.git") ? out[0, out.size - 5] : File.dirname(out)
      common.empty? ? nil : common
    end

    def self.git_branch(cwd)
      out = `cd "#{cwd}" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
      out.empty? || out == "HEAD" ? nil : out
    end
  end
end
