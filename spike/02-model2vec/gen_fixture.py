import json, sys, inspect
import numpy as np
from model2vec import StaticModel

path = sys.argv[1]
out = sys.argv[2]
m = StaticModel.from_pretrained(path)
print("median_token_length", getattr(m, "median_token_length", None), file=sys.stderr)
print("unk_token_id", getattr(m, "unk_token_id", None), file=sys.stderr)
print("normalize", m.normalize, "dim", m.dim, file=sys.stderr)
src = inspect.getsource(StaticModel.encode)
print(src[:1500], file=sys.stderr)
try:
    print(inspect.getsource(StaticModel.tokenize)[:1200], file=sys.stderr)
except Exception as e:
    print("no tokenize source", e, file=sys.stderr)

sentences = [
    "String literals are always frozen under Spinel; build buffers with +\"\" and <<.",
    "Use WAL journal mode and a busy timeout when several processes share one SQLite file.",
    "Binary blobs go through a C shim because the :str FFI type stops at the first NUL byte.",
    "How do I compile Ruby to a single native binary?",
    "sqlite-vec KNN queries need `k = ?` in the WHERE clause",
    "The quick brown fox jumps over the lazy dog",
    "Déjà vu: naïve café résumé",
    "CamelCaseIdentifiers and snake_case_names, plus 3.14 and 2026-09-08",
    "hello",
    "   ",
    "",
    "!!! ??? ...",
    "Pneumonoultramicroscopicsilicovolcanoconiosisxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "Frozen strings",
    "frozen strings in spinel",
    "The agent should remember gotchas about the compiler",
    "中文 tokens and emoji 🎉 mixed with English",
    "UPPER lower Mixed",
    "a b c d e f g",
    "Reciprocal rank fusion combines BM25 and vector search results",
]
ids = m.tokenize(sentences) if hasattr(m, "tokenize") else None
emb = m.encode(sentences)
rows = []
for i, s in enumerate(sentences):
    toks = ids[i] if ids is not None else None
    if toks is not None and hasattr(toks, "tolist"):
        toks = toks.tolist()
    rows.append({"text": s, "token_ids": toks, "embedding": [float(x) for x in emb[i]]})
json.dump({"model": "minishlab/potion-base-8M", "dim": int(m.dim), "sentences": rows}, open(out, "w"))
print("wrote", out, len(rows), file=sys.stderr)
