# frozen_string_literal: true
# Static (model2vec) sentence embeddings with no ML runtime: BERT WordPiece tokenize, look each token up in
# a [vocab, dim] float32 matrix, mean-pool, L2-normalise. Matches the Python model2vec library
# (verified by test/embedder_test.rb against test/fixtures/model2vec_expected.json).
#
# An Embedder is anything with `name`, `dim` and `embed(text) -> Array<Float>`; this is the only one so far.
require "json"

module Pinky
  class Model2Vec
    MODEL_NAME = "minishlab/potion-base-8M"
    FILES = ["config.json", "tokenizer.json", "model.safetensors"].freeze
    MAX_TOKENS = 512
    MAX_WORD_CHARS = 100

    attr_reader :dim, :name

    def self.default_dir = "#{ENV["HOME"]}/.pinky/models/potion-base-8M"

    def self.available?(dir) = FILES.all? { |f| File.exist?("#{dir}/#{f}") }

    def self.load(dir)
      new(File.binread("#{dir}/model.safetensors"), File.read("#{dir}/tokenizer.json"), File.read("#{dir}/config.json"))
    end

    def initialize(safetensors, tokenizer_json, config_json)
      config = JSON.parse(config_json)
      @normalize = config["normalize"] != false
      @name = MODEL_NAME
      load_weights(safetensors)
      load_tokenizer(tokenizer_json)
    end

    def embed(text)
      ids = tokenize(text)
      out = Array.new(@dim, 0.0)
      return out if ids.empty?
      ids.each do |id|
        base = id * @dim
        i = 0
        while i < @dim
          out[i] += @weights[base + i]
          i += 1
        end
      end
      n = ids.size.to_f
      i = 0
      while i < @dim
        out[i] /= n
        i += 1
      end
      if @normalize
        norm = Math.sqrt(out.sum { |x| x * x })
        if norm > 0.0
          i = 0
          while i < @dim
            out[i] /= norm
            i += 1
          end
        end
      end
      out
    end

    # Token ids as model2vec produces them: text cut to MAX_TOKENS * median token length characters,
    # WordPiece pieces, [UNK] dropped, then the first MAX_TOKENS ids.
    def tokenize(text)
      text = text.to_s
      text = text[0, @max_chars].to_s if text.size > @max_chars
      ids = []
      words(text).each do |w|
        wordpiece(w).each { |id| ids << id unless id == @unk_id }
      end
      ids.size > MAX_TOKENS ? ids[0, MAX_TOKENS] : ids
    end

    private

    def load_weights(raw)
      header_len = raw.byteslice(0, 8).to_s.unpack1("Q<").to_s.to_i
      header = JSON.parse(raw.byteslice(8, header_len).to_s)
      info = header["embeddings"]
      raise ArgumentError, "model.safetensors has no 'embeddings' tensor" if info.nil?
      raise ArgumentError, "unsupported dtype #{info["dtype"]}" unless info["dtype"].to_s == "F32"
      shape = info["shape"]
      @rows = shape[0].to_s.to_i
      @dim = shape[1].to_s.to_i
      offsets = info["data_offsets"]
      start = 8 + header_len + offsets[0].to_s.to_i
      @weights = raw.byteslice(start, @rows * @dim * 4).to_s.unpack("e*")
      raise ArgumentError, "model.safetensors is truncated" unless @weights.size == @rows * @dim
    end

    def load_tokenizer(json)
      tok = JSON.parse(json)
      model = tok["model"]
      raise ArgumentError, "tokenizer model is #{model["type"]}, expected WordPiece" unless model["type"].to_s == "WordPiece"
      @vocab = {}
      lengths = []
      model["vocab"].each do |k, v|
        key = k.to_s
        @vocab[key] = v.to_s.to_i
        lengths << key.size
      end
      @unk_id = @vocab[model["unk_token"].to_s] || 1
      lengths.sort!
      @max_chars = MAX_TOKENS * lengths[lengths.size / 2]
    end

    # BertNormalizer (clean text, isolate CJK characters, strip accents, lowercase) plus BertPreTokenizer
    # (split on whitespace, every punctuation character is its own word) in one pass over codepoints.
    def words(text)
      out = []
      cur = +""
      text.codepoints.each do |cp|
        if cp == 0 || cp == 0xFFFD || control?(cp) || combining_mark?(cp)
          next
        elsif whitespace?(cp)
          flush(out, cur)
          cur = +""
        elsif cjk?(cp) || punctuation?(cp)
          flush(out, cur)
          cur = +""
          out << [cp].pack("U")
        else
          folded = ACCENTS[cp]
          cur << (folded || [cp].pack("U"))
        end
      end
      flush(out, cur)
      out
    end

    def flush(out, cur)
      out << cur.downcase unless cur.empty?
      nil
    end

    def wordpiece(word)
      chars = word.chars
      return [@unk_id] if chars.size > MAX_WORD_CHARS
      ids = []
      start = 0
      while start < chars.size
        stop = chars.size
        found = -1
        while start < stop
          piece = chars[start, stop - start].join
          piece = "##" + piece if start > 0
          id = @vocab[piece]
          if id
            found = id
            break
          end
          stop -= 1
        end
        return [@unk_id] if found < 0
        ids << found
        start = stop
      end
      ids
    end

    def control?(cp)
      return false if cp == 9 || cp == 10 || cp == 13
      return true if cp < 32 || (cp >= 127 && cp <= 159)
      cp == 0xAD || (cp >= 0x200B && cp <= 0x200F) || (cp >= 0x202A && cp <= 0x202E) || (cp >= 0x2060 && cp <= 0x2064) || cp == 0xFEFF
    end

    def whitespace?(cp)
      cp == 32 || cp == 9 || cp == 10 || cp == 13 || cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) ||
        cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000
    end

    def combining_mark?(cp) = cp >= 0x300 && cp <= 0x36F

    def cjk?(cp)
      (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x20000 && cp <= 0x2A6DF) ||
        (cp >= 0x2A700 && cp <= 0x2B73F) || (cp >= 0x2B740 && cp <= 0x2B81F) || (cp >= 0x2B820 && cp <= 0x2CEAF) ||
        (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0x2F800 && cp <= 0x2FA1F)
    end

    def punctuation?(cp)
      (cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64) || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126) ||
        cp == 0xA1 || cp == 0xA7 || cp == 0xAB || cp == 0xB6 || cp == 0xB7 || cp == 0xBB || cp == 0xBF ||
        (cp >= 0x2010 && cp <= 0x2027) || (cp >= 0x2030 && cp <= 0x205E) ||
        (cp >= 0x3001 && cp <= 0x3003) || (cp >= 0x3008 && cp <= 0x3011) || (cp >= 0x3014 && cp <= 0x301F) ||
        (cp >= 0xFF01 && cp <= 0xFF0F) || (cp >= 0xFF1A && cp <= 0xFF20) || (cp >= 0xFF3B && cp <= 0xFF40) || (cp >= 0xFF5B && cp <= 0xFF65)
    end

    # Precomposed Latin letters that decompose to a base letter plus a combining mark, which BERT's
    # strip_accents removes. Letters with strokes or ligatures (ø, ł, æ, ß, đ) stay as they are.
    def self.accent_table
      table = {}
      [["àáâãäå", "a"], ["ÀÁÂÃÄÅ", "a"], ["ç", "c"], ["Ç", "c"], ["èéêë", "e"], ["ÈÉÊË", "e"],
       ["ìíîï", "i"], ["ÌÍÎÏ", "i"], ["ñ", "n"], ["Ñ", "n"], ["òóôõö", "o"], ["ÒÓÔÕÖ", "o"],
       ["ùúûü", "u"], ["ÙÚÛÜ", "u"], ["ýÿ", "y"], ["Ý", "y"],
       ["āăą", "a"], ["ĀĂĄ", "a"], ["ćĉċč", "c"], ["ĆĈĊČ", "c"], ["ď", "d"], ["Ď", "d"],
       ["ēĕėęě", "e"], ["ĒĔĖĘĚ", "e"], ["ĝğġģ", "g"], ["ĜĞĠĢ", "g"], ["ĥ", "h"], ["Ĥ", "h"],
       ["ĩīĭį", "i"], ["ĨĪĬĮİ", "i"], ["ĵ", "j"], ["Ĵ", "j"], ["ķ", "k"], ["Ķ", "k"],
       ["ĺļľ", "l"], ["ĹĻĽ", "l"], ["ńņň", "n"], ["ŃŅŇ", "n"], ["ōŏő", "o"], ["ŌŎŐ", "o"],
       ["ŕŗř", "r"], ["ŔŖŘ", "r"], ["śŝşš", "s"], ["ŚŜŞŠ", "s"], ["ţť", "t"], ["ŢŤ", "t"],
       ["ũūŭůűų", "u"], ["ŨŪŬŮŰŲ", "u"], ["ŵ", "w"], ["Ŵ", "w"], ["ŷ", "y"], ["ŶŸ", "y"],
       ["źżž", "z"], ["ŹŻŽ", "z"]].each do |pair|
        pair[0].codepoints.each { |cp| table[cp] = pair[1] }
      end
      table
    end

    ACCENTS = accent_table.freeze
  end
end
