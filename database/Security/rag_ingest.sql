-- Ingesting: replace the rows in dbo.chunks and drop/recreate its DiskANN index (ALTER).
-- Nothing else in the database, and no DROP TABLE or schema changes.
CREATE ROLE rag_ingest;
GO
GRANT SELECT, INSERT, DELETE, ALTER ON dbo.chunks TO rag_ingest;
