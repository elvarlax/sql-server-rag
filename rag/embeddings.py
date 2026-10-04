import functools
import json

import ollama

from rag.config import EMBED_MODEL

# Vectors are passed to SQL Server as JSON array strings, so both functions return JSON.


@functools.lru_cache(maxsize=256)
def embed(text: str) -> str:
    """Embed one text (a question). Cached, so repeated questions skip Ollama."""
    return embed_many([text])[0]


def embed_many(texts: list[str]) -> list[str]:
    """Embed many texts in a single Ollama call (used for ingesting chunks)."""
    vectors = ollama.embed(model=EMBED_MODEL, input=texts)["embeddings"]
    if len(vectors) != len(texts):
        raise RuntimeError(f"Ollama returned no embeddings — run: ollama pull {EMBED_MODEL}")
    return [json.dumps(v) for v in vectors]
