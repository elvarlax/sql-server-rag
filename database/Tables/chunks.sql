-- Chunks of the source documents and their embeddings.
-- VECTOR(1024) must match EMBED_DIMS for the embedding model in rag/config.py.
-- The DiskANN index isn't declared here: SQL Server needs 100+ rows to build one,
-- so ingest() in rag/db.py creates it after loading the data.
CREATE TABLE dbo.chunks
(
    id        INT IDENTITY CONSTRAINT PK_chunks PRIMARY KEY,  -- named, because the full-text index uses it as its key
    source    NVARCHAR(500) NOT NULL,
    content   NVARCHAR(MAX) NOT NULL,
    embedding VECTOR(1024)  NOT NULL
);
