import logging

from rag.config import EMBED_DIMS, MAX_DISTANCE, RRF_CANDIDATES, TOP_K
from rag.db import VECTOR_PARAM, get_conn, has_fulltext_index, has_vector_index
from rag.embeddings import embed

log = logging.getLogger(__name__)

SEARCH_MODES = {"hybrid": "Hybrid", "vector": "Vector"}  # first is the default


def vector_search(conn, query: str) -> list:
    """Nearest chunks by cosine distance: ANN with the DiskANN index if it exists, otherwise exact ENN."""
    if has_vector_index(conn):
        # SIMILAR_TO only accepts a variable or column, so the vector goes into @q first.
        # Table columns come from the TABLE alias (c), only distance from the function alias (v).
        sql = f"""
            SET NOCOUNT ON;
            DECLARE @q VECTOR({EMBED_DIMS}) = {VECTOR_PARAM};
            SELECT c.source, c.content, v.distance AS score
            FROM VECTOR_SEARCH(TABLE = chunks AS c, COLUMN = embedding, SIMILAR_TO = @q,
                               METRIC = 'cosine', TOP_N = {TOP_K}) AS v
            ORDER BY v.distance
        """
    else:
        sql = f"""
            SELECT TOP ({TOP_K}) source, content, VECTOR_DISTANCE('cosine', embedding, {VECTOR_PARAM}) AS score
            FROM chunks
            ORDER BY score
        """
    return conn.execute(sql, embed(query)).fetchall()


def hybrid_search(conn, query: str) -> list:
    """Take the top candidates by vector distance (ENN) and by full-text relevance (FREETEXTTABLE),
    then fuse the two lists with Reciprocal Rank Fusion: score = sum of 1/(60 + rank) per list."""
    return conn.execute(f"""
        WITH vector_ranks AS (
            SELECT TOP ({RRF_CANDIDATES}) id, distance, ROW_NUMBER() OVER (ORDER BY distance) AS rank
            FROM (SELECT id, VECTOR_DISTANCE('cosine', embedding, {VECTOR_PARAM}) AS distance FROM chunks) AS d
            ORDER BY rank
        ),
        fulltext_ranks AS (
            -- LANGUAGE 0 (neutral) matches how the full-text index was built
            SELECT TOP ({RRF_CANDIDATES}) [KEY] AS id, ROW_NUMBER() OVER (ORDER BY RANK DESC) AS rank
            FROM FREETEXTTABLE(chunks, content, ?, LANGUAGE 0)
            ORDER BY rank
        ),
        fused AS (
            SELECT COALESCE(v.id, f.id) AS id,
                ISNULL(1.0 / (60 + v.rank), 0) + ISNULL(1.0 / (60 + f.rank), 0) AS score
            FROM vector_ranks v
            FULL OUTER JOIN fulltext_ranks f ON f.id = v.id
        )
        SELECT TOP ({TOP_K}) c.source, c.content, CAST(fused.score AS FLOAT) AS score,
            (SELECT MIN(distance) FROM vector_ranks) AS closest
        FROM fused
        JOIN chunks c ON c.id = fused.id
        ORDER BY fused.score DESC
    """, embed(query), query).fetchall()


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
