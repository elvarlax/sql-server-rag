import logging

from rag.config import EMBED_DIMS, MAX_DISTANCE, RRF_CANDIDATES, TOP_K
from rag.db import VECTOR_PARAM, get_conn, has_fulltext_index, has_vector_index
from rag.embeddings import embed

log = logging.getLogger(__name__)

SEARCH_MODES = {"hybrid": "Hybrid", "vector": "Vector"}  # first is the default

# pyodbc sends long strings as ntext, which can't convert to VECTOR, so the procedures get a variable
DECLARE_QUERY_VECTOR = f"DECLARE @q VECTOR({EMBED_DIMS}) = {VECTOR_PARAM};"


def vector_search(conn, query: str) -> list:
    """Nearest chunks by cosine distance: ANN with the DiskANN index if it exists, otherwise exact (ENN)."""
    procedure = "dbo.search_ann" if has_vector_index(conn) else "dbo.search_exact"
    return conn.execute(f"{DECLARE_QUERY_VECTOR} EXEC {procedure} @query_vector = @q, @top_k = ?", embed(query), TOP_K).fetchall()


def hybrid_search(conn, query: str) -> list:
    """Vector and full-text rankings fused with Reciprocal Rank Fusion (see database/Procedures/search_hybrid.sql)."""
    return conn.execute(
        f"{DECLARE_QUERY_VECTOR} EXEC dbo.search_hybrid @query_vector = @q, @query_text = ?, @top_k = ?, @candidates = ?",
        embed(query), query, TOP_K, RRF_CANDIDATES,
    ).fetchall()


def retrieve(query: str, mode: str = "hybrid") -> tuple[list, str]:
    """Return (relevant rows, mode used). Each row has source, content and score:
    cosine distance for vector search, RRF score for hybrid.

    Nothing is returned when even the closest chunk is farther than MAX_DISTANCE, so clearly
    unrelated questions are refused without calling the LLM. Beyond that, vector results are
    filtered one by one, while hybrid results are kept as fused: RRF scores are rank-based, and a
    per-chunk cut-off in hybrid mode was measured (evaluate.py) to lower accuracy.
    """
    with get_conn() as conn:
        if mode == "hybrid":
            if has_fulltext_index(conn):
                rows = hybrid_search(conn, query)
                return (rows if rows and rows[0].closest <= MAX_DISTANCE else []), "hybrid"
            log.warning("No full-text index — using vector search instead of hybrid")
        rows = vector_search(conn, query)
    return [r for r in rows if r.score <= MAX_DISTANCE], "vector"
