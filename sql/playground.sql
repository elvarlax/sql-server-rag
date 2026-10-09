-- ============================================================
-- PLAYGROUND: try the app's searches yourself, in the SqlServerRag database
--
-- Connect with SSMS or VS Code (mssql extension):
--   Server:   tcp:localhost,1433   (tcp: makes sure you reach the Docker container)
--   Login:    sa, with SQL_PASSWORD from .env
--   Encrypt:  Mandatory, with "Trust server certificate" checked
-- Ingest the documents in the app first, then run one section at a time.
--
-- There's no embedding model in SQL here (the app embeds questions with bge-m3 in Ollama),
-- so an existing chunk's embedding stands in for a question.
-- ============================================================

USE SqlServerRag;
GO

-- ── 1. What's stored ───────────────────────────────────────────
-- One row per 500-character chunk, with its 1024-number embedding
SELECT TOP (10) id, source, LEFT(content, 80) AS content_start, embedding
FROM dbo.chunks
ORDER BY id;

SELECT source, COUNT(*) AS chunks
FROM dbo.chunks
GROUP BY source
ORDER BY chunks DESC;
GO

-- ── 2. Vector search: approximate (DiskANN) vs exact ───────────
-- Both should return the same chunks, the "question" chunk itself first with distance 0.
-- Press Ctrl+M (Include Actual Execution Plan) before running to compare the two plans.
DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks ORDER BY id);

EXEC dbo.search_ann   @query_vector = @q, @top_k = 5;  -- uses the DiskANN index
EXEC dbo.search_exact @query_vector = @q, @top_k = 5;  -- computes the distance to every chunk
GO

-- ── 3. Which documents are closest in meaning? ─────────────────
-- Cosine distance runs from 0 (same direction) to 2 (opposite); the app ignores anything above 0.52
DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks ORDER BY id);

SELECT source, MIN(VECTOR_DISTANCE('cosine', embedding, @q)) AS closest_distance
FROM dbo.chunks
GROUP BY source
ORDER BY closest_distance;
GO

-- ── 4. Full-text search and the Icelandic stoplist ─────────────
-- Full-text search matches words, not meaning, and with no Icelandic word breaker
-- only the exact word form matches (orlof, but not orlofs)
SELECT TOP (5) c.source, ft.RANK, LEFT(c.content, 80) AS content_start
FROM FREETEXTTABLE(dbo.chunks, content, N'orlof', LANGUAGE 0) AS ft
JOIN dbo.chunks AS c ON c.id = ft.[KEY]
ORDER BY ft.RANK DESC;

-- These words are in almost every chunk, but they're stopwords, so nothing matches
SELECT COUNT(*) AS matches
FROM FREETEXTTABLE(dbo.chunks, content, N'hvað og að', LANGUAGE 0);

SELECT s.stopword
FROM sys.fulltext_stopwords AS s
JOIN sys.fulltext_stoplists AS l ON l.stoplist_id = s.stoplist_id
WHERE l.name = N'icelandic'
ORDER BY s.stopword;
GO

-- ── 5. Hybrid search: meaning and words together ───────────────
-- Change the text and watch the ranking change; score is the RRF score (higher is better)
DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks ORDER BY id);

EXEC dbo.search_hybrid @query_vector = @q, @query_text = N'orlof', @top_k = 5, @candidates = 20;
GO

-- ── 6. What the app's login may do ─────────────────────────────
-- The app connects as rag_app. Impersonate it to see what it can and can't do.
EXECUTE AS LOGIN = 'rag_app';

SELECT SUSER_NAME() AS logged_in_as;

DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks ORDER BY id);
EXEC dbo.search_exact @query_vector = @q, @top_k = 3;  -- allowed: rag_search

BEGIN TRY
    DROP TABLE dbo.chunks;  -- not allowed
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS drop_table_result;
END CATCH;

REVERT;
GO

-- ── 7. What each search costs (Query Store) ────────────────────
-- Query Store records every query (capture mode ALL). search_ann runs its query as dynamic
-- SQL, which Query Store doesn't attribute to the procedure, so it's named here by its text.
SELECT TOP (10)
    COALESCE(OBJECT_NAME(q.object_id), N'search_ann') AS procedure_name,
    LEFT(t.query_sql_text, 70)      AS query,
    SUM(rs.count_executions)        AS runs,
    AVG(rs.avg_duration) / 1000     AS avg_ms,
    AVG(rs.avg_logical_io_reads)    AS avg_reads
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS t ON t.query_text_id = q.query_text_id
JOIN sys.query_store_plan AS p ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id = p.plan_id
WHERE q.object_id IN (OBJECT_ID(N'dbo.search_exact'), OBJECT_ID(N'dbo.search_hybrid'))
   OR t.query_sql_text LIKE N'%VECTOR_SEARCH(%'
GROUP BY q.object_id, t.query_sql_text
ORDER BY runs DESC;
GO
