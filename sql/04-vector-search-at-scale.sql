-- ============================================================
-- 4 of 4: VECTOR SEARCH AT SCALE (sections 26–30)
-- The app's 101 chunks are too few to tell exact and approximate search apart. This file builds
-- about 20,000 vectors from them and compares, on the same data, exact search (VECTOR_DISTANCE)
-- with DiskANN (VECTOR_SEARCH), each with float32 and half-precision float16 vectors: storage,
-- index build time, query time and recall.
--
-- Connect as described in 01-app-searches.sql. Uses the scratch database from 02-design-and-develop.sql
-- (run section 8 of 02 first). Section 26 starts this file over. All of it takes a few minutes.
--
-- The vectors are the real bge-m3 embeddings plus random noise, so they cluster around real
-- documents, but they aren't real text: read the numbers as an indication, not a benchmark.
-- ============================================================

USE SqlServerRagScratch;
GO

-- ── 26. Setup: 20,000 vectors in float32 and float16 ───────────
-- float16 (2 bytes per number instead of 4) is a preview feature in SQL Server 2025; section 8 turned PREVIEW_FEATURES on
DROP TABLE IF EXISTS dbo.scale_vectors, dbo.scale_queries, dbo.scale_results, dbo.scale_timings;
CREATE TABLE dbo.scale_vectors (
    id          INT IDENTITY CONSTRAINT PK_scale_vectors PRIMARY KEY,
    embedding   VECTOR(1024)          NOT NULL,
    embedding16 VECTOR(1024, float16) NOT NULL
);
CREATE TABLE dbo.scale_queries (
    id  INT IDENTITY CONSTRAINT PK_scale_queries PRIMARY KEY,
    q   VECTOR(1024)          NOT NULL,
    q16 VECTOR(1024, float16) NOT NULL
);
CREATE TABLE dbo.scale_results (method VARCHAR(20) NOT NULL, query_id INT NOT NULL, id INT NOT NULL);
CREATE TABLE dbo.scale_timings (method VARCHAR(20) CONSTRAINT PK_scale_timings PRIMARY KEY, build_seconds INT NULL, query_ms DECIMAL(9, 2) NULL);
GO

-- Noisy copies of each chunk's embedding: every number gets up to ±0.05 of noise, then the vector is
-- normalized again. T-SQL has no vector arithmetic, so the vector goes through JSON: OPENJSON splits
-- it into numbers and STRING_AGG puts it back together. Copy 0 of the first 50 chunks becomes the test queries.
-- float32 can't be cast to float16 directly (Msg 42238), but both convert from the same JSON
DECLARE @copies INT = 200, @noise FLOAT = 0.05;

WITH copies AS (
    SELECT TOP (@copies + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS copy_no FROM sys.all_objects
),
noisy AS (
    SELECT c.id AS chunk_id, n.copy_no,
           N'[' + STRING_AGG(CAST(CAST(v.value AS FLOAT) + @noise * CHECKSUM(NEWID()) / 2147483648.0 AS NVARCHAR(MAX)), N',')
                  WITHIN GROUP (ORDER BY CAST(v.[key] AS INT)) + N']' AS json_vector
    FROM dbo.chunks AS c
    CROSS JOIN copies AS n
    CROSS APPLY OPENJSON(CAST(c.embedding AS NVARCHAR(MAX))) AS v
    GROUP BY c.id, n.copy_no
)
SELECT chunk_id, copy_no, CAST(VECTOR_NORMALIZE(CAST(json_vector AS VECTOR(1024)), 'norm2') AS NVARCHAR(MAX)) AS json_vector
INTO #noisy
FROM noisy;

INSERT INTO dbo.scale_vectors (embedding, embedding16)
SELECT CAST(json_vector AS VECTOR(1024)), CAST(json_vector AS VECTOR(1024, float16))
FROM #noisy
WHERE copy_no > 0;

INSERT INTO dbo.scale_queries (q, q16)
SELECT TOP (50) CAST(json_vector AS VECTOR(1024)), CAST(json_vector AS VECTOR(1024, float16))
FROM #noisy
WHERE copy_no = 0
ORDER BY chunk_id;

DROP TABLE #noisy;
SELECT (SELECT COUNT(*) FROM dbo.scale_vectors) AS vectors, (SELECT COUNT(*) FROM dbo.scale_queries) AS queries;
GO

-- ── 27. Storage: float16 halves it ─────────────────────────────
SELECT COUNT(*)                                             AS vectors,
       CAST(SUM(DATALENGTH(embedding))   / 1048576.0 AS DECIMAL(9, 1)) AS float32_mb,
       CAST(SUM(DATALENGTH(embedding16)) / 1048576.0 AS DECIMAL(9, 1)) AS float16_mb
FROM dbo.scale_vectors;
GO

-- A helper that runs one search for every test query, keeps the top 10 ids, and records the average time.
-- @search sees the query vector as @q (float32) and @q16 (float16), and the query number as @query_id.
-- Dynamic SQL, because a statement using VECTOR_SEARCH can't compile before its vector index exists
CREATE OR ALTER PROCEDURE dbo.scale_search_all
    @method VARCHAR(20),
    @search NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @query_id INT = 1, @n INT = (SELECT COUNT(*) FROM dbo.scale_queries),
            @q VECTOR(1024), @q16 VECTOR(1024, float16), @start DATETIME2 = SYSDATETIME();
    DECLARE @found TABLE (query_id INT NOT NULL, id INT NOT NULL);

    WHILE @query_id <= @n
    BEGIN
        SELECT @q = q, @q16 = q16 FROM dbo.scale_queries WHERE id = @query_id;
        INSERT INTO @found (query_id, id)
        EXEC sys.sp_executesql @search, N'@query_id INT, @q VECTOR(1024), @q16 VECTOR(1024, float16)', @query_id, @q, @q16;
        SET @query_id += 1;
    END;

    DELETE FROM dbo.scale_results WHERE method = @method;
    INSERT INTO dbo.scale_results (method, query_id, id) SELECT @method, query_id, id FROM @found;

    MERGE dbo.scale_timings AS t
    USING (SELECT @method AS method, CAST(DATEDIFF(MICROSECOND, @start, SYSDATETIME()) / 1000.0 / @n AS DECIMAL(9, 2)) AS query_ms) AS s
        ON t.method = s.method
    WHEN MATCHED THEN UPDATE SET query_ms = s.query_ms
    WHEN NOT MATCHED THEN INSERT (method, query_ms) VALUES (s.method, s.query_ms);
END;
GO

-- ── 28. Exact search (ENN): compares the query with every vector ─
-- The float32 results are the ground truth for recall in section 30
EXEC dbo.scale_search_all 'exact float32', N'
    SELECT TOP (10) @query_id, id FROM dbo.scale_vectors ORDER BY VECTOR_DISTANCE(''cosine'', embedding, @q);';
EXEC dbo.scale_search_all 'exact float16', N'
    SELECT TOP (10) @query_id, id FROM dbo.scale_vectors ORDER BY VECTOR_DISTANCE(''cosine'', embedding16, @q16);';
SELECT * FROM dbo.scale_timings;
GO

-- ── 29. DiskANN indexes, one per column, and approximate search (ANN) ─
-- Building an index takes a while and makes the table read-only (until newer vector indexes reach SQL Server)
DECLARE @start DATETIME2 = SYSDATETIME();
CREATE VECTOR INDEX ix_scale_vectors_float32 ON dbo.scale_vectors(embedding) WITH (METRIC = 'cosine', TYPE = 'DISKANN');
INSERT INTO dbo.scale_timings (method, build_seconds) VALUES ('DiskANN float32', DATEDIFF(SECOND, @start, SYSDATETIME()));

SET @start = SYSDATETIME();
CREATE VECTOR INDEX ix_scale_vectors_float16 ON dbo.scale_vectors(embedding16) WITH (METRIC = 'cosine', TYPE = 'DISKANN');
INSERT INTO dbo.scale_timings (method, build_seconds) VALUES ('DiskANN float16', DATEDIFF(SECOND, @start, SYSDATETIME()));
GO

EXEC dbo.scale_search_all 'DiskANN float32', N'
    SELECT @query_id, t.id
    FROM VECTOR_SEARCH(TABLE = dbo.scale_vectors AS t, COLUMN = embedding, SIMILAR_TO = @q, METRIC = ''cosine'', TOP_N = 10) AS s;';
EXEC dbo.scale_search_all 'DiskANN float16', N'
    SELECT @query_id, t.id
    FROM VECTOR_SEARCH(TABLE = dbo.scale_vectors AS t, COLUMN = embedding16, SIMILAR_TO = @q16, METRIC = ''cosine'', TOP_N = 10) AS s;';
GO

-- ── 30. Results: time per query and recall against exact float32 ─
-- Recall@10: the share of the exact float32 top 10 that a method also returns
SELECT t.method,
       t.build_seconds,
       t.query_ms,
       CAST(100.0 * COUNT(e.id) / (SELECT COUNT(*) FROM dbo.scale_results WHERE method = 'exact float32') AS DECIMAL(5, 1)) AS recall_pct
FROM dbo.scale_timings AS t
LEFT JOIN dbo.scale_results AS r ON r.method = t.method
LEFT JOIN dbo.scale_results AS e ON e.method = 'exact float32' AND e.query_id = r.query_id AND e.id = r.id
GROUP BY t.method, t.build_seconds, t.query_ms
ORDER BY t.method DESC;
GO
