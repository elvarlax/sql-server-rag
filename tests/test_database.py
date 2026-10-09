"""Integration tests against a real SQL Server, with the schema from database/ deployed.

They check what the unit tests can't: that the schema deploys, that ingest builds the DiskANN
index, that the search procedures return the right chunks, and what the app's login may do.
Ollama isn't needed: embeddings are generated from a hash of the text.

They replace the chunks with test data, so they only run when asked for (and in CI):
    docker compose up -d && docker compose wait schema
    pytest -m integration
Ingest the documents again afterwards.
"""
import hashlib
import json
import math
import random
import time
from unittest.mock import patch

import pyodbc
import pytest

from rag.config import DISKANN_MIN_ROWS, EMBED_DIMS, SQL_PASSWORD
from rag.db import get_conn, ingest, table_stats
from rag.retrieval import retrieve

pytestmark = pytest.mark.integration

N_DOCS = DISKANN_MIN_ROWS + 10  # enough chunks for a DiskANN index, one per document


def fake_embedding(text: str) -> str:
    """A deterministic unit vector for the text, as the JSON string the app sends to SQL Server."""
    rng = random.Random(hashlib.sha256(text.encode()).digest())
    vector = [rng.gauss(0, 1) for _ in range(EMBED_DIMS)]
    norm = math.sqrt(sum(x * x for x in vector))
    return json.dumps([x / norm for x in vector])


def document(i: int) -> str:
    # Every document has the same Icelandic stopwords and one word of its own
    return f"Hvað er þetta og að hverju er spurt? Prófunarskjal {i} með kóðaorðinu kodi{i:03}x."


def wait_for_fulltext(timeout: float = 60) -> None:
    """The full-text index follows new rows in the background (CHANGE_TRACKING AUTO)."""
    deadline = time.monotonic() + timeout
    with get_conn() as conn:
        while conn.execute(
            "SELECT CAST(OBJECTPROPERTYEX(OBJECT_ID('dbo.chunks'), 'TableFulltextPendingChanges') AS INT)"
            " + CAST(OBJECTPROPERTYEX(OBJECT_ID('dbo.chunks'), 'TableFulltextPopulateStatus') AS INT)"
        ).fetchone()[0]:
            assert time.monotonic() < deadline, "full-text index didn't catch up"
            time.sleep(1)


@pytest.fixture(scope="module", autouse=True)
def ingested(tmp_path_factory):
    docs = tmp_path_factory.mktemp("docs")
    for i in range(N_DOCS):
        (docs / f"doc{i:03}.txt").write_text(document(i), encoding="utf-8")
    with patch("rag.db.embed_many", side_effect=lambda texts: [fake_embedding(t) for t in texts]):
        ingest(docs)
    wait_for_fulltext()


def search(question: str, mode: str, query_vector_from: str | None = None):
    """retrieve() as the app calls it, with the question embedded like `query_vector_from` (default: itself)."""
    with patch("rag.retrieval.embed", return_value=fake_embedding(query_vector_from or question)):
        return retrieve(question, mode)


def test_ingest_loads_every_chunk_and_builds_the_diskann_index():
    assert table_stats() == (N_DOCS, True)


@pytest.mark.parametrize("mode", ["vector", "hybrid"])
def test_search_finds_the_chunk_closest_to_the_question(mode):
    rows, used = search(document(42), mode)
    assert used == mode
    assert rows[0].source == "doc042.txt"


def test_approximate_and_exact_search_agree_on_the_nearest_chunk():
    with get_conn() as conn:
        top = {}
        for procedure in ("dbo.search_ann", "dbo.search_exact"):
            sql = f"DECLARE @q VECTOR({EMBED_DIMS}) = CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR({EMBED_DIMS}));" \
                  f" EXEC {procedure} @query_vector = @q, @top_k = 5"
            top[procedure] = conn.execute(sql, fake_embedding(document(7))).fetchall()[0].source
    assert top == {"dbo.search_ann": "doc007.txt", "dbo.search_exact": "doc007.txt"}


def test_hybrid_search_finds_a_chunk_by_its_words_alone():
    # The query vector points at another chunk, so only full-text search can bring this one in
    vector_only, _ = search("kodi042x", "vector", query_vector_from=document(1))
    hybrid, _ = search("kodi042x", "hybrid", query_vector_from=document(1))
    assert "doc042.txt" not in {r.source for r in vector_only}
    assert "doc042.txt" in {r.source for r in hybrid}


def test_icelandic_stopwords_are_left_out_of_the_full_text_index():
    with get_conn() as conn:
        def matches(text: str) -> int:
            return conn.execute("SELECT COUNT(*) FROM FREETEXTTABLE(dbo.chunks, content, ?, LANGUAGE 0)", text).fetchone()[0]

        assert matches("hvað og að") == 0  # in every document, but stopwords
        assert matches("prófunarskjal") == N_DOCS


@pytest.mark.parametrize("statement", [
    "DROP TABLE dbo.chunks",
    "CREATE TABLE dbo.other (id INT)",
    "ALTER PROCEDURE dbo.search_exact AS SELECT 1",
    "DROP ROLE rag_search",
    "ALTER DATABASE CURRENT SET QUERY_STORE CLEAR",
])
def test_the_app_login_cannot_change_the_schema(statement):
    with get_conn() as conn, pytest.raises(pyodbc.Error, match="permission|does not exist"):
        conn.autocommit = True  # ALTER DATABASE can't run inside a transaction
        conn.execute(statement)


def test_the_app_login_is_not_sa_and_has_only_its_two_roles():
    with get_conn() as conn:
        assert tuple(conn.execute("SELECT SUSER_NAME(), IS_SRVROLEMEMBER('sysadmin')").fetchone()) == ("rag_app", 0)
        roles = {r.name for r in conn.execute(
            "SELECT r.name FROM sys.database_role_members m JOIN sys.database_principals r"
            " ON r.principal_id = m.role_principal_id WHERE m.member_principal_id = USER_ID()"
        )}
    assert roles == {"rag_search", "rag_ingest"}


def test_query_store_is_recording_queries():
    with get_conn("sa", SQL_PASSWORD) as conn:
        state, mode = conn.execute(
            "SELECT actual_state_desc, query_capture_mode_desc FROM sys.database_query_store_options"
        ).fetchone()
    assert (state, mode) == ("READ_WRITE", "ALL")
