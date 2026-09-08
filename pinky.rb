# frozen_string_literal: true
require "json"
require "pinky/db"
require "pinky/schema"
require "pinky/identity"
require "pinky/embedder"
require "pinky/store"
require "pinky/hooks"
require "pinky/install"
require "pinky/markdown"
require "pinky/http"
require "pinky/web"
require "pinky/mcp"
require "pinky/cli"

module Pinky
  VERSION = "0.1.0"

  def self.model_dir = ENV["PINKY_MODEL_DIR"] || Model2Vec.default_dir

  # The embedder used for vector search, loaded once; nil when the model files are absent, which leaves
  # search full-text only until `pinky setup` fetches them.
  def self.embedder
    unless @embedder_checked
      @embedder_checked = true
      @embedder = Model2Vec.available?(model_dir) ? Model2Vec.load(model_dir) : nil
    end
    @embedder
  end
end
