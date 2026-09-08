# frozen_string_literal: true
# Compares our tokenizer and embeddings with the Python model2vec library's output for the same model
# (fixture generated once by spike/02-model2vec/gen_fixture.py). Needs the model under ~/.pinky/models.
require "pinky"

$stdout.sync = true
dir = ENV["PINKY_MODEL_DIR"] || Pinky::Model2Vec.default_dir
unless Pinky::Model2Vec.available?(dir)
  puts "model not present at #{dir}; run brain setup"
  puts "ok"
  exit 0
end

fixture = JSON.parse(File.read("test/fixtures/model2vec_expected.json"))
model = Pinky::Model2Vec.load(dir)
puts "model #{model.name} dim #{model.dim} fixture dim #{fixture["dim"]}"

def cosine(a, b)
  dot = 0.0
  na = 0.0
  nb = 0.0
  i = 0
  while i < a.size
    x = a[i].to_f
    y = b[i].to_f
    dot += x * y
    na += x * x
    nb += y * y
    i += 1
  end
  return 1.0 if na == 0.0 && nb == 0.0
  return 0.0 if na == 0.0 || nb == 0.0
  dot / (Math.sqrt(na) * Math.sqrt(nb))
end

failures = 0
fixture["sentences"].each do |row|
  text = row["text"].to_s
  expected_ids = row["token_ids"].map { |x| x.to_s.to_i }
  ids = model.tokenize(text)
  vec = model.embed(text)
  cos = cosine(vec, row["embedding"])
  tokens_ok = ids == expected_ids
  vec_ok = cos > 0.99999
  failures += 1 unless tokens_ok && vec_ok
  label = text.size > 40 ? "#{text[0, 40]}..." : text
  puts "#{tokens_ok && vec_ok ? "match" : "DIFF "} #{label.inspect} tokens=#{ids.size}#{tokens_ok ? "" : " expected #{expected_ids.inspect} got #{ids.inspect}"} cos=#{(cos * 100000).round}"
end
puts "failures #{failures}"

t = Time.now
200.times { model.embed("String literals are always frozen under Spinel; build buffers with +\"\" and <<.") }
elapsed = Time.now - t
puts "200 embeds under #{elapsed < 2.0 ? "2s" : "#{elapsed.round}s"}"
puts "ok"
