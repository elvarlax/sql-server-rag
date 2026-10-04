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
    SQL_PASSWORD,
    SQL_SERVER,
)
from rag.embeddings import embed_many

log = logging.getLogger(__name__)

# SQL for a vector passed in as a JSON array string parameter
VECTOR_PARAM = f"CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR({EMBED_DIMS}))"

# Common Icelandic function words, excluded from full-text search
ICELANDIC_STOPWORDS = """
á að af aðeins allt alltaf annað annars auk eða eftir ef eiga ekki ég eins en enda er eru fá fær fæ fyrir
frá geta getur get gera hafa hann hefur hér hjá hún hvað hvaða hvar hvenær hver hverjar hverjir hvernig
hvort hversu í inn já má með meðan mig mér mín mun nei nú og okkar sem sé sig sín sinn sitt svo til um
undir upp úr út var vera verður við yfir þá það þær þann þar þarf þegar þeir þess þessi þetta þig þú þín
"""


def get_conn(db: str = DB_NAME):
    """A pyodbc connection to SQL Server, closed when the `with` block ends."""
    return closing(pyodbc.connect(
        f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={SQL_SERVER};"
        f"DATABASE={db};UID=sa;PWD={SQL_PASSWORD};TrustServerCertificate=yes;"
    ))


def _has_index(conn, catalog_view: str) -> bool:
    return conn.execute(f"SELECT COUNT(*) FROM sys.{catalog_view} WHERE object_id = OBJECT_ID('chunks')").fetchone()[0] > 0


def has_vector_index(conn) -> bool:
    return _has_index(conn, "vector_indexes")


def has_fulltext_index(conn) -> bool:
    return _has_index(conn, "fulltext_indexes")


def table_stats() -> tuple[int, bool]:
    """(number of chunks, whether a DiskANN index exists); (0, False) if the table doesn't exist yet."""
    try:
        with get_conn() as conn:
            return conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0], has_vector_index(conn)
    except pyodbc.Error:
        return 0, False


def setup_db() -> None:
    """Create the database and enable preview features (needed for vector indexes and VECTOR_SEARCH)."""
    # CREATE DATABASE can't run inside a transaction, so use autocommit
    with get_conn("master") as conn:
        conn.autocommit = True
        conn.execute(f"IF DB_ID('{DB_NAME}') IS NULL CREATE DATABASE {DB_NAME}")
    with get_conn() as conn:
        conn.autocommit = True
        conn.execute("ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON")


def split(text: str) -> list[str]:
    """Overlapping fixed-size chunks; tiny fragments are dropped."""
    text = re.sub(r"[ \t]+", " ", text)  # PDF text extraction leaves runs of spaces in justified text
    step = CHUNK_SIZE - CHUNK_OVERLAP
    chunks = (text[i:i + CHUNK_SIZE].strip() for i in range(0, len(text), step))
    return [c for c in chunks if len(c) >= 20]


def create_fulltext_index(conn) -> None:
    """Full-text index for hybrid search, with an Icelandic stoplist.

    SQL Server has no built-in Icelandic stopwords, so without this list common words like
    "á", "að" and "hvað" match almost every chunk and drown out the real search terms.
    LANGUAGE 0 (neutral) indexes words as-is, since there's no Icelandic word breaker either;
    queries must use the same language (see retrieval.hybrid_search).
    """
    conn.execute("IF NOT EXISTS (SELECT * FROM sys.fulltext_catalogs) CREATE FULLTEXT CATALOG ft_rag AS DEFAULT;")
    # Recreated on every ingest so changes to the word list apply
    conn.execute("IF EXISTS (SELECT * FROM sys.fulltext_stoplists WHERE name = 'icelandic') DROP FULLTEXT STOPLIST icelandic;")
    conn.execute("CREATE FULLTEXT STOPLIST icelandic;")
    conn.execute("".join(f"ALTER FULLTEXT STOPLIST icelandic ADD '{w}' LANGUAGE 0;" for w in ICELANDIC_STOPWORDS.split()))
    conn.execute("CREATE FULLTEXT INDEX ON chunks(content LANGUAGE 0) KEY INDEX PK_chunks WITH STOPLIST = icelandic;")


def create_vector_index(conn, n_rows: int) -> None:
    """DiskANN index for approximate (ANN) search. SQL Server needs 100+ rows to build it."""
    if n_rows < DISKANN_MIN_ROWS:
        log.info("DiskANN needs %d+ chunks (have %d) — vector search will be exact (ENN)", DISKANN_MIN_ROWS, n_rows)
        return
    conn.execute("CREATE VECTOR INDEX idx_chunks_vector ON chunks(embedding) WITH (TYPE = 'DISKANN', METRIC = 'cosine')")
    log.info("DiskANN index created")


def ingest(docs_path: Path) -> None:
    """Rebuild the chunks table: load docs, split into chunks, embed them and build the indexes.

    The table is recreated on every ingest, so its VECTOR size always matches the current
    embedding model and vectors from different models can never be mixed.
    """
    # Embed first (the slow part), so the existing table stays usable until the new data is ready
    documents = SimpleDirectoryReader(str(docs_path)).load_data()
    rows = []
    for doc in documents:
        chunks = split(doc.text)
        if chunks:
            source = doc.metadata.get("file_name", "unknown")
            rows += [(source, chunk, vector) for chunk, vector in zip(chunks, embed_many(chunks))]

    with get_conn() as conn:
        # Dropping the table also drops its full-text and DiskANN indexes
        conn.execute("DROP TABLE IF EXISTS chunks")
        # Named PK is required by the full-text index (KEY INDEX)
        conn.execute(f"""
            CREATE TABLE chunks (
                id        INT IDENTITY CONSTRAINT PK_chunks PRIMARY KEY,
                source    NVARCHAR(500) NOT NULL,
                content   NVARCHAR(MAX),
                embedding VECTOR({EMBED_DIMS})
            )
        """)
        if rows:
            conn.cursor().executemany(f"INSERT INTO chunks (source, content, embedding) VALUES (?, ?, {VECTOR_PARAM})", rows)
        conn.commit()
        log.info("Inserted %d chunks from %d documents", len(rows), len(documents))

        # Index creation can't run inside a transaction
        conn.autocommit = True
        try:
            create_fulltext_index(conn)
        except pyodbc.Error as e:
            log.warning("Full-text index failed (%s) — hybrid search will use vector search", e)
        try:
            create_vector_index(conn, len(rows))
        except pyodbc.Error as e:
            log.warning("DiskANN index failed (%s) — vector search will be exact (ENN)", e)
