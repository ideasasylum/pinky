# frozen_string_literal: true
require "pinky"

$stdout.sync = true
exit Pinky::CLI.run(ARGV)
