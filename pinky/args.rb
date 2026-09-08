# frozen_string_literal: true
# Minimal command-line option parsing shared by both runtimes (Spinel's optparse is a stub).
# Long options only: `--name value`, `--name=value`, and boolean `--flag`. Everything else is positional.
module Pinky
  module Args
    class Error < StandardError; end

    # Returns [opts (Hash{String => String}), positional (Array<String>)]. Boolean flags map to "1".
    def self.parse(argv, values, flags)
      opts = {}
      rest = []
      i = 0
      while i < argv.size
        arg = argv[i].to_s
        if arg == "--"
          i += 1
          while i < argv.size
            rest << argv[i].to_s
            i += 1
          end
        elsif arg.start_with?("--")
          name = arg[2, arg.size - 2].to_s
          value = nil
          eq = name.index("=")
          if eq
            value = name[eq + 1, name.size - eq - 1].to_s
            name = name[0, eq].to_s
          end
          if values.include?(name)
            if value.nil?
              i += 1
              raise Error, "--#{name} needs a value" if i >= argv.size
              value = argv[i].to_s
            end
            opts[name] = value
          elsif flags.include?(name)
            raise Error, "--#{name} takes no value" if value
            opts[name] = "1"
          else
            raise Error, "unknown option --#{name}"
          end
        else
          rest << arg
        end
        i += 1
      end
      [opts, rest]
    end
  end
end
