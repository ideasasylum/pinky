# frozen_string_literal: true
# Probe: can Spinel do what the pure-Ruby model2vec embedder needs, and how fast?
require "json"

$stdout.sync = true
dir = "#{ENV["HOME"]}/.pinky/models/potion-base-8M"

def ms(t0) = ((Time.now - t0) * 1000).round

t = Time.now
raw = File.binread("#{dir}/model.safetensors")
puts "binread #{raw.bytesize} bytes in #{ms(t)} ms"

n = raw.byteslice(0, 8).unpack1("Q<")
header = JSON.parse(raw.byteslice(8, n))
info = header["embeddings"]
puts "header #{n} bytes, dtype #{info["dtype"]}, shape #{info["shape"].inspect}, offsets #{info["data_offsets"].inspect}"
shape = info["shape"]
rows = shape[0].to_s.to_i
dim = shape[1].to_s.to_i
offsets = info["data_offsets"]
start = 8 + n + offsets[0].to_s.to_i

t = Time.now
floats = raw.byteslice(start, rows * dim * 4).unpack("e*")
puts "unpack #{floats.size} floats in #{ms(t)} ms; first #{(floats[0] * 10000).round} #{(floats[1] * 10000).round}, row 6598 first #{(floats[6598 * dim] * 10000).round}"

t = Time.now
tok = JSON.parse(File.read("#{dir}/tokenizer.json"))
vocab = tok["model"]["vocab"]
puts "tokenizer parsed in #{ms(t)} ms; vocab #{vocab.size}; hello=#{vocab["hello"]} ##s=#{vocab["##s"]}"

t = Time.now
lengths = vocab.keys.map { |k| k.size }.sort
puts "median token length #{lengths[lengths.size / 2]} in #{ms(t)} ms"

s = "Déjà vu: naïve CAFÉ 中文 🎉 a\tb\nc"
puts "chars #{s.chars.size} codepoints #{s.codepoints.size} first #{s.codepoints[0]} e-acute #{"é".ord}"
puts "downcase #{s.downcase}"
puts "pack U #{[233].pack("U")} #{[20013].pack("U")}"
puts "each_char #{s.each_char.to_a.size}"
puts "punct regex #{"a,b!c".scan(/[[:punct:]]/).inspect} space #{"a b\tc\nd".split(/\s+/).inspect}"
puts "alnum #{"héllo wörld 42".scan(/[[:alnum:]]+/).inspect}"
puts "slice #{"hello"[1, 3]} #{"hello"[1..2]} cp slice #{"héllo".chars[0, 2].join}"

# mean of a few rows + normalise, timed, as the embedder will do it
t = Time.now
ids = [4170, 17210, 1021, 1030, 1473, 6714, 1110, 7566, 1146, 31, 2863, 16704]
out = Array.new(dim, 0.0)
k = 0
while k < 1000
  i = 0
  while i < dim
    out[i] = 0.0
    i += 1
  end
  ids.each do |id|
    base = id * dim
    i = 0
    while i < dim
      out[i] += floats[base + i]
      i += 1
    end
  end
  i = 0
  while i < dim
    out[i] /= ids.size
    i += 1
  end
  norm = Math.sqrt(out.sum { |x| x * x })
  i = 0
  while i < dim
    out[i] /= norm
    i += 1
  end
  k += 1
end
puts "1000 embeds in #{ms(t)} ms; first #{(out[0] * 10000).round} #{(out[1] * 10000).round} #{(out[2] * 10000).round}"
puts "ok"
