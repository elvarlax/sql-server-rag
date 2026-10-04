-- ============================================================
-- SQL SERVER 2025 AI & VECTOR FEATURES — T-SQL EXAMPLES
-- Run in SSMS or VS Code (mssql extension) on localhost,1433.
-- Each section is standalone; placeholders like <your-resource> must be filled in.
-- ============================================================

USE RagDemo;
GO

-- ============================================================
-- 0. SETUP
-- ============================================================

-- Preview features: vector indexes, VECTOR_SEARCH and fuzzy string matching (database-scoped)
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

-- sp_invoke_external_rest_endpoint (server-scoped, needs sysadmin)
EXECUTE sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
GO

-- ============================================================
-- 1. VECTOR TYPE AND VECTOR_DISTANCE
-- ============================================================

CREATE TABLE products (
    id        INT IDENTITY PRIMARY KEY,
    name      NVARCHAR(200),
    embedding VECTOR(3)  -- 3 dimensions to keep the examples readable
);

-- Vectors are written as JSON arrays
INSERT INTO products (name, embedding) VALUES
('Laptop',   '[0.9, 0.1, 0.1]'),
('Phone',    '[0.8, 0.2, 0.1]'),
('Desk mat', '[0.1, 0.9, 0.1]'),
('Desk',     '[0.1, 0.8, 0.2]');

-- VECTOR_DISTANCE — exact distance between two vectors (metrics: cosine, euclidean, dot)
DECLARE @query VECTOR(3) = '[0.85, 0.15, 0.1]';

SELECT name, VECTOR_DISTANCE('cosine', embedding, @query) AS distance
FROM products
ORDER BY distance;  -- Laptop and Phone come first

-- VECTOR_NORMALIZE — scale to length 1 (norm types: norm1, norm2, norminf)
DECLARE @v VECTOR(3) = '[3.0, 4.0, 0.0]';
SELECT VECTOR_NORMALIZE(@v, 'norm2') AS normalized;  -- [0.6, 0.8, 0.0]

-- VECTORPROPERTY — vector metadata
SELECT VECTORPROPERTY(embedding, 'Dimensions') AS dims,
       VECTORPROPERTY(embedding, 'BaseType')   AS base_type
FROM products
WHERE id = 1;
GO

-- ============================================================
-- 2. DISKANN VECTOR INDEX AND VECTOR_SEARCH (ANN vs ENN)
-- ============================================================

-- A vector index needs an INT clustered primary key
CREATE TABLE articles (
    id        INT PRIMARY KEY,
    title     NVARCHAR(100),
    embedding VECTOR(3)
);

-- A vector index needs at least 100 rows with non-NULL vectors, so load mock data first
INSERT INTO articles (id, title, embedding)
SELECT value,
       CONCAT('Article ', value),
       CAST(JSON_ARRAY(SIN(value), COS(value), (value % 10) * 0.1) AS VECTOR(3))
FROM GENERATE_SERIES(1, 100);

CREATE VECTOR INDEX idx_articles_vector ON articles(embedding)
WITH (METRIC = 'cosine', TYPE = 'DiskANN');
GO

DECLARE @q VECTOR(3) = '[0.5, 0.5, 0.3]';

-- ANN — approximate, uses the DiskANN index.
-- Table columns must come from the TABLE alias (a); only distance comes from the function alias (v).
SELECT a.id, a.title, v.distance
FROM VECTOR_SEARCH(
    TABLE      = articles AS a,
    COLUMN     = embedding,
    SIMILAR_TO = @q,
    METRIC     = 'cosine',
    TOP_N      = 5
) AS v
ORDER BY v.distance;

-- Azure SQL Database has a newer index version where TOP_N is removed:
--   SELECT TOP (5) WITH APPROXIMATE a.id, a.title, v.distance
--   FROM VECTOR_SEARCH(TABLE = articles AS a, COLUMN = embedding, SIMILAR_TO = @q, METRIC = 'cosine') AS v
--   ORDER BY v.distance;

-- ENN — exact, scans every row. No index needed.
SELECT TOP (5) id, title, VECTOR_DISTANCE('cosine', embedding, @q) AS distance
FROM articles
ORDER BY distance;

-- ANN: VECTOR_SEARCH + DiskANN index — approximate, fast on large tables
-- ENN: ORDER BY VECTOR_DISTANCE    — exact, full scan, fine for small tables

-- In SQL Server 2025 a table with a vector index is read-only.
-- Drop the index before INSERT/UPDATE/DELETE, then recreate it:
-- DROP INDEX idx_articles_vector ON articles;
GO

-- ============================================================
-- 3. HYBRID SEARCH — VECTOR + FULL-TEXT + RECIPROCAL RANK FUSION
-- ============================================================

-- Full-text index KEY INDEX must reference a named, unique, single-column index
CREATE TABLE documents (
    id        INT IDENTITY CONSTRAINT PK_documents PRIMARY KEY,
    source    NVARCHAR(500),
    content   NVARCHAR(MAX),
    embedding VECTOR(768)
);

IF NOT EXISTS (SELECT * FROM sys.fulltext_catalogs) CREATE FULLTEXT CATALOG ft_catalog AS DEFAULT;
CREATE FULLTEXT INDEX ON documents(content) KEY INDEX PK_documents WITH STOPLIST = OFF;
GO

DECLARE @query_text NVARCHAR(500) = 'artificial intelligence and automation';
DECLARE @query_vec  VECTOR(768)   = '[...]';  -- replace with a real 768-dim embedding (see section 10)

-- Rank every row twice (vector + full-text), then fuse: score = 1/(60 + rank) from each list
WITH vector_results AS (
    SELECT id,
           ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', embedding, @query_vec)) AS rank
    FROM documents
),
fulltext_results AS (
    -- FREETEXTTABLE: natural-language search (stemming, inflections)
    -- CONTAINSTABLE: precise boolean / prefix / proximity search
    SELECT d.id,
           ROW_NUMBER() OVER (ORDER BY ft.RANK DESC) AS rank
    FROM documents d
    JOIN FREETEXTTABLE(documents, content, @query_text) AS ft ON d.id = ft.[KEY]
),
rrf AS (
    SELECT COALESCE(v.id, f.id) AS id,
           1.0 / (60 + ISNULL(v.rank, 1000)) +
           1.0 / (60 + ISNULL(f.rank, 1000)) AS rrf_score
    FROM vector_results v
    FULL OUTER JOIN fulltext_results f ON v.id = f.id
)
SELECT TOP (5) d.source, d.content, r.rrf_score
FROM rrf r
JOIN documents d ON r.id = d.id
ORDER BY r.rrf_score DESC;
GO

-- ============================================================
-- 4. SP_INVOKE_EXTERNAL_REST_ENDPOINT — CALL AZURE OPENAI FROM T-SQL
-- ============================================================

DECLARE @url      NVARCHAR(4000) = 'https://<your-resource>.openai.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2024-02-01';
DECLARE @payload  NVARCHAR(MAX)  = JSON_OBJECT('input': 'What is retrieval-augmented generation?');
DECLARE @response NVARCHAR(MAX);
DECLARE @status   INT;

EXEC @status = sp_invoke_external_rest_endpoint
    @url      = @url,
    @method   = 'POST',
    @headers  = '{"api-key": "<your-api-key>"}',
    @payload  = @payload,
    @response = @response OUTPUT;

-- The HTTP response body is wrapped in $.result.
-- JSON_QUERY, not JSON_VALUE: the embedding is an array and JSON_VALUE only returns scalars.
SELECT @status AS return_code,
       JSON_QUERY(@response, '$.result.data[0].embedding') AS embedding;
GO

-- ============================================================
-- 5. JSON FUNCTIONS
-- ============================================================

-- JSON_OBJECT — build JSON
SELECT JSON_OBJECT('model': 'gpt-4o-mini', 'tokens': 1234, 'response': 'Answer here') AS log_entry;

-- JSON_ARRAYAGG — aggregate rows into a JSON array
SELECT JSON_ARRAYAGG(name) AS all_names FROM products;

-- OPENJSON — parse an LLM response into rows
DECLARE @llm_response NVARCHAR(MAX) = '{"choices":[{"message":{"content":"Answer"}}]}';

SELECT *
FROM OPENJSON(@llm_response, '$.choices')
WITH (content NVARCHAR(MAX) '$.message.content');

-- JSON_VALUE for scalars, JSON_CONTAINS to search inside arrays ([*] is required for arrays)
DECLARE @doc NVARCHAR(MAX) = '{"type":"rag","sources":["doc1.pdf","doc2.pdf"]}';

SELECT JSON_VALUE(@doc, '$.type')                          AS doc_type,    -- rag
       JSON_CONTAINS(@doc, 'doc1.pdf', '$.sources[*]')     AS has_source;  -- 1
GO

-- ============================================================
-- 6. FUZZY STRING MATCHING (preview — needs PREVIEW_FEATURES)
-- ============================================================

-- These functions don't support SQL_* collations (the Docker default),
-- so a Windows collation is applied with COLLATE
SELECT EDIT_DISTANCE('Reykjavik' COLLATE Latin1_General_100_CI_AS, 'Reykjavík')            AS edit_distance,  -- 1
       EDIT_DISTANCE_SIMILARITY('Colour' COLLATE Latin1_General_100_CI_AS, 'Color')         AS edit_similarity, -- 83 (0–100)
       JARO_WINKLER_DISTANCE('Colour' COLLATE Latin1_General_100_CI_AS, 'Color')            AS jw_distance,     -- 0.033 (0 = identical)
       JARO_WINKLER_SIMILARITY('Colour' COLLATE Latin1_General_100_CI_AS, 'Color')          AS jw_similarity;   -- 96 (0–100)
GO

-- ============================================================
-- 7. RAG RETRIEVAL IN A STORED PROCEDURE
-- ============================================================

-- The retrieval step of RAG as a procedure over the app's chunks table (ENN)
CREATE OR ALTER PROCEDURE dbo.rag_query
    @query_vec VECTOR(1024),
    @top_k     INT = 5
AS
BEGIN
    SELECT TOP (@top_k)
        source,
        content,
        VECTOR_DISTANCE('cosine', embedding, @query_vec) AS distance
    FROM chunks
    ORDER BY distance;
END;
GO

-- EXEC dbo.rag_query @query_vec = '[...]', @top_k = 5;

-- ============================================================
-- 8. TEMPORAL TABLES — KEEP EMBEDDING HISTORY
-- ============================================================

-- SQL Server keeps every previous version of a row in an automatic history table
CREATE TABLE embedding_versions (
    id         INT PRIMARY KEY,
    content    NVARCHAR(MAX),
    embedding  VECTOR(3),
    valid_from DATETIME2 GENERATED ALWAYS AS ROW START,
    valid_to   DATETIME2 GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (valid_from, valid_to)
)
WITH (SYSTEM_VERSIONING = ON);

INSERT INTO embedding_versions (id, content, embedding) VALUES (1, 'First version', '[0.1, 0.2, 0.3]');
UPDATE embedding_versions SET content = 'Second version', embedding = '[0.4, 0.5, 0.6]' WHERE id = 1;

-- All versions, current and old
SELECT id, content, embedding, valid_from, valid_to
FROM embedding_versions FOR SYSTEM_TIME ALL
ORDER BY valid_from;
GO

-- ============================================================
-- 9. REGULAR EXPRESSIONS (needs compatibility level 170 — the SQL Server 2025 default)
-- ============================================================

-- REGEXP_LIKE returns a boolean, so it goes in WHERE / CASE / CHECK, not directly in SELECT
SELECT CASE WHEN REGEXP_LIKE('Hello World', 'world', 'i') THEN 1 ELSE 0 END AS match_found;  -- 1 ('i' = case-insensitive)

-- REGEXP_REPLACE — replace matches
SELECT REGEXP_REPLACE('Call 555-1234 or 555-5678', '\d{3}-\d{4}', '***-****') AS redacted;

-- REGEXP_SUBSTR — first match
SELECT REGEXP_SUBSTR('Price: $42.50 and $17.99', '\$\d+\.\d{2}') AS first_price;  -- $42.50

-- REGEXP_INSTR — position of first match (1-based)
SELECT REGEXP_INSTR('abc123def456', '\d+') AS first_digit_pos;  -- 4

-- REGEXP_COUNT — number of matches
SELECT REGEXP_COUNT('one two three four', '\w+') AS word_count;  -- 4

-- REGEXP_MATCHES — one row per match (match_id, start_position, end_position, match_value, substring_matches)
SELECT match_value
FROM REGEXP_MATCHES('Prices: $10.00, $25.50, $3.99', '\$\d+\.\d{2}');

-- REGEXP_SPLIT_TO_TABLE — split on a pattern (columns: value, ordinal)
SELECT value, ordinal
FROM REGEXP_SPLIT_TO_TABLE('apple, banana;cherry', '[,;]\s*');

-- Practical: find chunks that contain an email address
SELECT source, content
FROM chunks
WHERE REGEXP_LIKE(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
GO

-- ============================================================
-- 10. EXTERNAL MODELS AND AI_GENERATE_EMBEDDINGS
-- ============================================================

-- CREATE EXTERNAL MODEL registers an embedding endpoint in SQL Server
-- API_FORMAT: 'Azure OpenAI' | 'OpenAI' | 'Ollama' | 'ONNX Runtime'
-- MODEL_TYPE: only EMBEDDINGS is supported (no chat/completion models)

-- The API key lives in a database scoped credential, which needs a database master key
IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong-password>';

-- Credential name must be the endpoint URL (no query string)
CREATE DATABASE SCOPED CREDENTIAL [https://<your-resource>.openai.azure.com/]
    WITH IDENTITY = 'HTTPEndpointHeaders', SECRET = '{"api-key":"<your-api-key>"}';
GO

-- dimensions = 768 so the vectors fit the VECTOR(768) column in the documents table
CREATE EXTERNAL MODEL [AzureEmbeddings]
WITH (
    LOCATION   = 'https://<your-resource>.openai.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2024-02-01',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'text-embedding-3-small',
    CREDENTIAL = [https://<your-resource>.openai.azure.com/],
    PARAMETERS = '{"dimensions": 768}'
);
GO

-- AI_GENERATE_EMBEDDINGS — generate embeddings inline in T-SQL, no Python needed
DECLARE @v VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'What is retrieval-augmented generation?' USE MODEL AzureEmbeddings);
SELECT @v AS embedding;

-- Bulk generate and store embeddings.
-- Vectors from different models aren't comparable, even with the same dimensions —
-- don't mix these with the bge-m3 vectors in the app's chunks table.
UPDATE documents
SET embedding = AI_GENERATE_EMBEDDINGS(content USE MODEL AzureEmbeddings)
WHERE embedding IS NULL;

-- Semantic search with the question embedded inline
DECLARE @query NVARCHAR(500) = 'artificial intelligence automation';
DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(@query USE MODEL AzureEmbeddings);

SELECT TOP (5) source, content, VECTOR_DISTANCE('cosine', embedding, @qv) AS distance
FROM documents
ORDER BY distance;

-- SELECT * FROM sys.external_models;
-- DROP EXTERNAL MODEL [AzureEmbeddings];
GO

-- ============================================================
-- 11. GRAPH TABLES AND MATCH
-- ============================================================

-- Node tables hold entities, edge tables hold relationships
CREATE TABLE Person   (id INT PRIMARY KEY, name  NVARCHAR(100)) AS NODE;
CREATE TABLE Document (id INT PRIMARY KEY, title NVARCHAR(200)) AS NODE;
CREATE TABLE Topic    (id INT PRIMARY KEY, name  NVARCHAR(100)) AS NODE;

CREATE TABLE CreatedBy AS EDGE;  -- Person -> Document
CREATE TABLE IsAbout   AS EDGE;  -- Document -> Topic

INSERT INTO Person   (id, name)  VALUES (1, 'Anna'), (2, 'Jon');
INSERT INTO Document (id, title) VALUES (1, 'AI Policy'), (2, 'Data Strategy');
INSERT INTO Topic    (id, name)  VALUES (1, 'AI'), (2, 'Data');

-- Edges connect two $node_id values ($from_id, $to_id)
INSERT INTO CreatedBy VALUES
    ((SELECT $node_id FROM Person WHERE id = 1), (SELECT $node_id FROM Document WHERE id = 1)),
    ((SELECT $node_id FROM Person WHERE id = 2), (SELECT $node_id FROM Document WHERE id = 2));
INSERT INTO IsAbout VALUES
    ((SELECT $node_id FROM Document WHERE id = 1), (SELECT $node_id FROM Topic WHERE id = 1)),
    ((SELECT $node_id FROM Document WHERE id = 2), (SELECT $node_id FROM Topic WHERE id = 2));

-- MATCH — who wrote which document, and what is it about?
SELECT p.name AS author, d.title AS document, t.name AS topic
FROM Person p, CreatedBy cb, Document d, IsAbout ia, Topic t
WHERE MATCH(p-(cb)->d-(ia)->t);

-- DROP TABLE CreatedBy, IsAbout, Person, Document, Topic;
GO

-- ============================================================
-- 12. KEEPING EMBEDDINGS IN SYNC WITH THE SOURCE DATA
-- ============================================================

-- ── Option 1: DML trigger (simple, synchronous) ───────────────────────────
-- Good for low volume. Trade-off: every INSERT/UPDATE waits for the embedding API.
CREATE OR ALTER TRIGGER trg_update_embedding
ON documents
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(content) RETURN;  -- only re-embed when the text changed

    UPDATE d
    SET d.embedding = AI_GENERATE_EMBEDDINGS(d.content USE MODEL AzureEmbeddings)
    FROM documents d
    JOIN inserted i ON d.id = i.id;
END;
GO

-- ── Option 2: Change Tracking (lightweight, batch) ────────────────────────
-- Records which rows changed (not the old values). A job polls and re-embeds them.
-- This is also what the Azure Functions SQL trigger binding uses.
ALTER DATABASE RagDemo SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
ALTER TABLE documents ENABLE CHANGE_TRACKING;
GO

DECLARE @last_sync BIGINT = 0;  -- store CHANGE_TRACKING_CURRENT_VERSION() between runs

SELECT d.id, d.content
FROM documents d
JOIN CHANGETABLE(CHANGES documents, @last_sync) AS ct ON d.id = ct.id
WHERE ct.SYS_CHANGE_OPERATION IN ('I', 'U');
GO

-- ── Option 3: Change Data Capture (full change history) ───────────────────
-- Captures before/after values into change tables. Needs SQL Server Agent
-- (in Docker: set MSSQL_AGENT_ENABLED=true).
EXEC sys.sp_cdc_enable_db;
EXEC sys.sp_cdc_enable_table
    @source_schema = 'dbo',
    @source_name   = 'documents',
    @role_name     = NULL;

-- SQL Server 2025 also has Change Event Streaming, which pushes row changes
-- to Azure Event Hubs so a separate service can re-embed them.

-- ── Summary ───────────────────────────────────────────────────────────────
-- Trigger          → synchronous, simplest, slows down writes
-- Change Tracking  → async polling, lightweight, no old values
-- CDC              → async, full before/after history, more overhead
-- Change Streaming → push-based, event-driven pipelines
GO
