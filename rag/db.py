import logging
import re
from contextlib import closing
from pathlib import Path

import pyodbc
from llama_index.core import SimpleDirectoryReader

from rag.config import (
    CHUNK_OVERLAP,
    CHUNK_SIZE,
    DB_NAME,
    DISKANN_MIN_ROWS,
    EMBED_DIMS,
    SQL_APP_PASSWORD,
    SQL_APP_USER,
    SQL_SERVER,
)
from rag.embeddings import embed_many

log = logging.getLogger(__name__)

# SQL for a vector passed in as a JSON array string parameter
VECTOR_PARAM = f"CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR({EMBED_DIMS}))"


def get_conn(user: str = SQL_APP_USER, password: str = SQL_APP_PASSWORD):
    """A pyodbc connection to the database, closed when the `with` block ends.

    The app connects as rag_app, which can only run the search procedures and replace the
    chunks (see database/Security). The schema itself is deployed from the SQL project in database/.
    """
    return closing(pyodbc.connect(
        f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={SQL_SERVER};"
        f"DATABASE={DB_NAME};UID={user};PWD={password};TrustServerCertificate=yes;ConnectRetryCount=0;",
        timeout=5,  # fail after 5 s when SQL Server isn't reachable; without both settings the driver retries for ~15 s
    ))


def _has_index(conn, catalog_view: str) -> bool:
    return conn.execute(f"SELECT COUNT(*) FROM sys.{catalog_view} WHERE object_id = OBJECT_ID('chunks')").fetchone()[0] > 0


def has_vector_index(conn) -> bool:
    return _has_index(conn, "vector_indexes")


def has_fulltext_index(conn) -> bool:
    return _has_index(conn, "fulltext_indexes")


def table_stats() -> tuple[int, bool]:
    """(number of chunks, whether a DiskANN index exists)."""
    with get_conn() as conn:
        return conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0], has_vector_index(conn)


def split(text: str) -> list[str]:
    """Overlapping fixed-size chunks; tiny fragments are dropped."""
    text = re.sub(r"[ \t]+", " ", text)  # PDF text extraction leaves runs of spaces in justified text
    step = CHUNK_SIZE - CHUNK_OVERLAP
    chunks = (text[i:i + CHUNK_SIZE].strip() for i in range(0, len(text), step))
    return [c for c in chunks if len(c) >= 20]


def create_vector_index(conn, n_rows: int) -> None:
    """DiskANN index for approximate (ANN) search. SQL Server needs 100+ rows to build it."""
    if n_rows < DISKANN_MIN_ROWS:
        log.info("DiskANN needs %d+ chunks (have %d) — vector search will be exact (ENN)", DISKANN_MIN_ROWS, n_rows)
        return
    conn.execute("CREATE VECTOR INDEX idx_chunks_vector ON chunks(embedding) WITH (TYPE = 'DISKANN', METRIC = 'cosine')")
    log.info("DiskANN index created")


def ingest(docs_path: Path) -> None:
    """Replace the chunks: load docs, split into chunks, embed them and rebuild the DiskANN index.

    The table, its full-text index and the search procedures come from the SQL project in
    database/; the full-text index follows the new rows by itself (CHANGE_TRACKING AUTO).
    """
    # Embed first (the slow part), so the existing chunks stay searchable until the new data is ready
    documents = SimpleDirectoryReader(str(docs_path)).load_data()
    rows = []
    for doc in documents:
        chunks = split(doc.text)
        if chunks:
            source = doc.metadata.get("file_name", "unknown")
            rows += [(source, chunk, vector) for chunk, vector in zip(chunks, embed_many(chunks))]

    with get_conn() as conn:
        # A table with a DiskANN index is read-only, so drop the index before replacing the rows
        conn.execute("DROP INDEX IF EXISTS idx_chunks_vector ON chunks")
        conn.execute("DELETE FROM chunks")
        if rows:
            conn.cursor().executemany(f"INSERT INTO chunks (source, content, embedding) VALUES (?, ?, {VECTOR_PARAM})", rows)
        conn.commit()
        log.info("Inserted %d chunks from %d documents", len(rows), len(documents))

        # Index creation can't run inside a transaction
        conn.autocommit = True
        create_vector_index(conn, len(rows))
