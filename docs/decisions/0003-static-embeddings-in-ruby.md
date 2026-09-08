# 0003 Semantic search uses model2vec static embeddings computed in Ruby

Date: 2026-09-08. Status: accepted.

## Context

pinky must run as one Spinel-compiled binary with no cloud calls. Transformer embedding models need an
inference runtime (llama.cpp, ONNX Runtime) that is C++ and would have to be linked through Spinel's FFI
with a C shim; nobody has done that yet and it adds a cmake step and 5-10 MB to the binary. model2vec
"static" models reduce inference to WordPiece tokenisation, a table lookup and a mean, which needs no
runtime at all. The probe in `spike/02-model2vec` measured a 60 ms model load and under a millisecond per
fact under Spinel, and `test/embedder_test.rb` shows identical token ids and embeddings to the Python
library on 20 varied sentences.

## Decision

`Pinky::Model2Vec` (pure Ruby) with `minishlab/potion-base-8M` (MIT, 256 dimensions, 30 MB, fetched once by
`pinky setup` into `~/.pinky/models/`). Vectors live in a sqlite-vec `vec0` table with cosine distance.
Search is hybrid: FTS5 BM25 and vector KNN fused with reciprocal rank fusion, so exact terms still win when
the static embedding is weak.

## Consequences

- Retrieval quality is roughly two thirds of a small transformer model on benchmarks; paraphrase matching
  works (the search test finds "frozen string literals" from "the compiler makes text constants
  immutable") but word order and negation are invisible to the model.
- The embedder is an interface (`name`, `dim`, `embed(text)`); the model name and dimension are recorded
  in `meta`, a mismatch disables vector search until `pinky reindex`, and swapping in a llama.cpp-backed
  embedder later is a new class plus one reindex. Spinel's `--link` and spin's `[native] libs` are the
  route for that archive when the time comes.
- The tokenizer reimplements BERT normalisation by hand: accent folding covers Latin-1 and Latin
  Extended-A only, and Unicode punctuation is approximated by ranges. English technical text is exact.
