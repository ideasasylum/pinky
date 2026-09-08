# 02: model2vec static embeddings in pure Ruby under Spinel

Result (2026-09-08): feasible and fast. `pinky/embedder.rb` is the outcome; `test/embedder_test.rb` proves
parity with the Python `model2vec` library on 20 sentences (identical token ids, cosine 1.0).

Probe (`probe.rb`, compiled with `spinel probe.rb -o probe`):

| Step | CRuby 3.4 | Spinel |
|---|---|---|
| `File.binread` 30 MB | 7 ms | 11 ms |
| `unpack("e*")` 7.56M floats | 32 ms | 31 ms |
| `JSON.parse` tokenizer.json (684 kB) | 19 ms | 19 ms |
| 1000 mean+normalise embeds of 12 tokens | 171 ms | 17 ms |

So a process pays about 60 ms to load the model and well under a millisecond per fact. Good enough to load
the model in every hook invocation; no daemon needed.

What Spinel supported without fuss: `binread`, `byteslice`, `unpack1("Q<")`, `unpack("e*")`, `codepoints`,
`chars`, Unicode `downcase` ("CAFÉ" -> "café"), `[cp].pack("U")`, `[[:punct:]]` and `[[:alnum:]]` regexes,
`Array#sum` with a block. Not supported: `Integer#chr("UTF-8")` (compile error; use `pack("U")`) and
`String#each_codepoint` (compiles, NoMethodError at run time; use `codepoints.each`).

Tokenizer facts learnt from the fixture (`gen_fixture.py`, run with `uvx --from model2vec --with numpy`):
- model2vec cuts the text to `512 * median_token_length` characters (median is 6 for this vocab, computed
  over the vocab strings including the `##` prefix), tokenizes with `add_special_tokens=False`, drops
  `[UNK]` (id 1), then keeps the first 512 ids.
- BertNormalizer with `strip_accents: null` and `lowercase: true` does strip accents; a Latin-1 and
  Latin Extended-A folding table reproduces it for the letters that decompose.
- Every punctuation character is its own token; CJK characters are split one per token; an emoji is a
  word that misses the vocab and vanishes as UNK; a word over 100 characters is UNK as a whole.
- Empty input embeds to the zero vector (mean of nothing, normalisation skipped).
