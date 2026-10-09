-- ============================================================
-- WALKTHROUGH: SQL Server 2025 in this project, one section at a time
--   Part 1 (sections 1–7):  the app's own searches, in the SqlServerRag database
--   Part 2 (sections 8–15): more SQL Server 2025 features, tried on the same documents
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

-- ============================================================
-- PART 1: THE APP'S SEARCHES
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

-- ============================================================
-- PART 2: MORE SQL SERVER 2025 FEATURES
-- These sections create their own tables, so they run in a separate scratch database,
-- SqlServerRagWalkthrough, and read the app's chunks from SqlServerRag.dbo.chunks.
-- The app's database and its schema stay untouched. The last section drops the scratch database.
-- ============================================================

USE master;
IF DB_ID(N'SqlServerRagWalkthrough') IS NULL CREATE DATABASE SqlServerRagWalkthrough;
GO

USE SqlServerRagWalkthrough;
-- JSON indexes and fuzzy string matching are preview features in SQL Server 2025
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

-- ── 8. Vector functions ────────────────────────────────────────
-- Two neighbouring chunks of the same document, compared with each metric
DECLARE @a VECTOR(1024) = (SELECT TOP (1) embedding FROM SqlServerRag.dbo.chunks ORDER BY id);
DECLARE @b VECTOR(1024) = (SELECT embedding FROM SqlServerRag.dbo.chunks
                           WHERE id = (SELECT MIN(id) + 1 FROM SqlServerRag.dbo.chunks));

SELECT VECTOR_DISTANCE('cosine',    @a, @b) AS cosine,     -- 0 = same direction (what the app uses)
       VECTOR_DISTANCE('euclidean', @a, @b) AS euclidean,  -- straight-line distance
       VECTOR_DISTANCE('dot',       @a, @b) AS dot;        -- negative dot product (lower = more similar)

-- bge-m3 vectors have length 1, which is why cosine and dot rank them the same way
SELECT TOP (1)
    CAST(VECTORPROPERTY(embedding, 'Dimensions') AS INT)         AS dimensions,
    CAST(VECTORPROPERTY(embedding, 'BaseType') AS NVARCHAR(20))  AS base_type
FROM SqlServerRag.dbo.chunks;

-- VECTOR_NORMALIZE scales a vector to length 1 (norm2), like the ones above
DECLARE @v VECTOR(3) = '[3.0, 4.0, 0.0]';
SELECT VECTOR_NORMALIZE(@v, 'norm2') AS normalized;  -- [0.6, 0.8, 0]
GO

-- ── 9. JSON: the json type, a JSON index and the JSON functions ──
-- A log of what the app answered, stored as native json
DROP TABLE IF EXISTS dbo.answer_log;
CREATE TABLE dbo.answer_log
(
    id      INT IDENTITY CONSTRAINT PK_answer_log PRIMARY KEY,
    details JSON NOT NULL
);

-- JSON_OBJECT and JSON_ARRAY build JSON from values
INSERT INTO dbo.answer_log (details) VALUES
    (JSON_OBJECT('mode': 'hybrid', 'question': N'Hvað marga orlofsdaga?', 'sources': JSON_ARRAY('Demo_Starfsmannahandbok.pdf'))),
    (JSON_OBJECT('mode': 'vector', 'question': N'Hver er stefnan um fjarvinnu?', 'sources': JSON_ARRAY('Demo_Fjarvinnustefna.pdf', 'Demo_IT_Reglur.pdf'))),
    (JSON_OBJECT('mode': 'hybrid', 'question': N'Hvað kostar fundarherbergi?', 'sources': JSON_ARRAY()));

-- A JSON index speeds up filters on paths inside the json column
CREATE JSON INDEX ix_answer_log_details ON dbo.answer_log (details) FOR ('$.mode', '$.sources');

-- JSON_VALUE reads a scalar; JSON_CONTAINS searches inside an array ([*] is required)
SELECT JSON_VALUE(details, '$.question') AS question
FROM dbo.answer_log
WHERE JSON_VALUE(details, '$.mode') = 'hybrid'
  AND JSON_CONTAINS(details, 'Demo_Starfsmannahandbok.pdf', '$.sources[*]') = 1;

-- OPENJSON turns JSON into rows: one row per source used
SELECT JSON_VALUE(l.details, '$.question') AS question, s.value AS source
FROM dbo.answer_log AS l
CROSS APPLY OPENJSON(l.details, '$.sources') AS s;

-- JSON_ARRAYAGG aggregates rows into a JSON array: the documents behind the chunks
SELECT JSON_ARRAYAGG(source) AS documents
FROM (SELECT DISTINCT source FROM SqlServerRag.dbo.chunks) AS d;
GO

-- ── 10. Regular expressions on the documents ───────────────────
-- REGEXP_LIKE returns a boolean, so it goes in WHERE, CASE or CHECK
SELECT COUNT(*) AS chunks_with_an_email
FROM SqlServerRag.dbo.chunks
WHERE REGEXP_LIKE(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

-- REGEXP_SUBSTR: the first match; REGEXP_INSTR: where it starts (1-based)
SELECT DISTINCT
    REGEXP_SUBSTR(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') AS email
FROM SqlServerRag.dbo.chunks
WHERE REGEXP_INSTR(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') > 0;

-- REGEXP_MATCHES: one row per match. Amounts in Icelandic format, like 8.000 kr
SELECT TOP (10) c.source, m.match_value AS amount
FROM SqlServerRag.dbo.chunks AS c
CROSS APPLY REGEXP_MATCHES(c.content, '\d{1,3}(\.\d{3})+ kr') AS m
ORDER BY c.id;

-- REGEXP_COUNT: how many amounts each document mentions
SELECT source, SUM(REGEXP_COUNT(content, '\d{1,3}(\.\d{3})+ kr')) AS amounts
FROM SqlServerRag.dbo.chunks
GROUP BY source
ORDER BY amounts DESC;

-- REGEXP_REPLACE: redact email addresses before sending text anywhere
SELECT TOP (3) REGEXP_REPLACE(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]') AS redacted
FROM SqlServerRag.dbo.chunks
WHERE REGEXP_LIKE(content, '@');

-- REGEXP_SPLIT_TO_TABLE: split the first chunk into its lines
SELECT ordinal, value AS line
FROM REGEXP_SPLIT_TO_TABLE((SELECT TOP (1) content FROM SqlServerRag.dbo.chunks ORDER BY id), '\n');
GO

-- ── 11. Fuzzy string matching: find a document from a typo ──────
-- These functions don't support SQL_* collations (the Docker default), hence COLLATE
WITH documents AS (
    SELECT DISTINCT REPLACE(REPLACE(source, 'Demo_', ''), '.pdf', '') COLLATE Latin1_General_100_CI_AS AS name
    FROM SqlServerRag.dbo.chunks
)
SELECT TOP (3)
    name,
    EDIT_DISTANCE(name, N'Starfsmanahandbók')            AS edit_distance,        -- edits needed
    EDIT_DISTANCE_SIMILARITY(name, N'Starfsmanahandbók') AS edit_similarity,      -- 0–100
    JARO_WINKLER_DISTANCE(name, N'Starfsmanahandbók')    AS jaro_winkler_distance -- 0 = identical
FROM documents
ORDER BY JARO_WINKLER_SIMILARITY(name, N'Starfsmanahandbók') DESC;
GO

-- ── 12. Specialized tables: temporal, ledger and graph ─────────
-- Temporal: SQL Server keeps every earlier version of a row, e.g. when a chunk is re-embedded
IF OBJECT_ID(N'dbo.chunk_versions') IS NOT NULL
BEGIN
    ALTER TABLE dbo.chunk_versions SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE dbo.chunk_versions, dbo.chunk_versions_history;
END;
CREATE TABLE dbo.chunk_versions
(
    id         INT CONSTRAINT PK_chunk_versions PRIMARY KEY,
    content    NVARCHAR(MAX),
    embedding  VECTOR(3),
    valid_from DATETIME2 GENERATED ALWAYS AS ROW START,
    valid_to   DATETIME2 GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (valid_from, valid_to)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.chunk_versions_history));

INSERT INTO dbo.chunk_versions (id, content, embedding) VALUES (1, N'First version', '[0.1, 0.2, 0.3]');
UPDATE dbo.chunk_versions SET content = N'Second version', embedding = '[0.4, 0.5, 0.6]' WHERE id = 1;

SELECT id, content, embedding, valid_from, valid_to
FROM dbo.chunk_versions FOR SYSTEM_TIME ALL
ORDER BY valid_from;
GO

-- Ledger (append-only): a tamper-evident log of the questions asked.
-- Ledger tables can't be dropped for good, so this one is only created once.
IF OBJECT_ID(N'dbo.question_log') IS NULL
    CREATE TABLE dbo.question_log
    (
        id       INT IDENTITY,
        question NVARCHAR(500) NOT NULL,
        asked_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    )
    WITH (LEDGER = ON (APPEND_ONLY = ON));
GO

INSERT INTO dbo.question_log (question) VALUES (N'Hvað marga orlofsdaga á ári á starfsmaður rétt á?');
SELECT * FROM dbo.question_log;
GO

-- Graph: documents and the topics they're about, queried with MATCH
DROP TABLE IF EXISTS dbo.is_about, dbo.document_node, dbo.topic_node;
CREATE TABLE dbo.document_node (name NVARCHAR(200) PRIMARY KEY) AS NODE;
CREATE TABLE dbo.topic_node    (name NVARCHAR(100) PRIMARY KEY) AS NODE;
CREATE TABLE dbo.is_about AS EDGE;

INSERT INTO dbo.document_node (name) SELECT DISTINCT source FROM SqlServerRag.dbo.chunks;
INSERT INTO dbo.topic_node (name) VALUES (N'Employees'), (N'Security'), (N'Money');

-- Edges connect two $node_id values
INSERT INTO dbo.is_about ($from_id, $to_id)
SELECT d.$node_id, t.$node_id
FROM dbo.document_node AS d
JOIN (VALUES
    (N'Demo_Starfsmannahandbok.pdf',      N'Employees'),
    (N'Demo_Nylidahandbok.pdf',           N'Employees'),
    (N'Demo_Launa_og_starfsthroun.pdf',   N'Employees'),
    (N'Demo_Launa_og_starfsthroun.pdf',   N'Money'),
    (N'Demo_Innkaup_og_kostnadur.pdf',    N'Money'),
    (N'Demo_IT_Reglur.pdf',               N'Security'),
    (N'Demo_Oryggi_og_neydaraaetlun.pdf', N'Security'),
    (N'Demo_Personuverndarstefna.pdf',    N'Security')
) AS map (document, topic) ON map.document = d.name
JOIN dbo.topic_node AS t ON t.name = map.topic;

-- Which documents are about money, and what else are they about?
SELECT d.name AS document, other.name AS also_about
FROM dbo.document_node AS d, dbo.is_about AS a1, dbo.topic_node AS money,
     dbo.is_about AS a2, dbo.topic_node AS other
WHERE MATCH(money<-(a1)-d-(a2)->other)
  AND money.name = N'Money' AND other.name <> N'Money';
GO

-- ── 13. Error handling: TRY/CATCH and THROW ────────────────────
-- A ledger table is append-only, so an UPDATE fails. SQL Server rejects it while compiling the
-- statement, and CATCH can't catch compile errors in its own batch, so it runs in its own scope
BEGIN TRY
    EXEC sys.sp_executesql N'UPDATE dbo.question_log SET question = N''changed'';';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
END CATCH;

-- THROW raises your own error, like refusing when no chunk is close enough
DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM SqlServerRag.dbo.chunks ORDER BY id);
DECLARE @closest FLOAT = (SELECT MIN(VECTOR_DISTANCE('cosine', embedding, @q)) FROM SqlServerRag.dbo.chunks);

BEGIN TRY
    IF @closest > 0.52
        THROW 50001, N'No chunk is close enough to answer from.', 1;
    SELECT @closest AS closest_distance, N'close enough to answer' AS result;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
END CATCH;
GO

-- ── 14. Keeping embeddings in sync: Change Tracking ────────────
-- Change Tracking records which rows changed (not the old values). A job reads the changes
-- since its last sync and re-embeds only those rows. The Azure Functions SQL trigger uses it too.
-- Other options: a DML trigger (synchronous, slows down writes), Change Data Capture
-- (full before/after history, needs SQL Server Agent) and Change Event Streaming (pushes
-- changes to Azure Event Hubs). Section 15 has a trigger that calls an embedding model.
IF NOT EXISTS (SELECT * FROM sys.change_tracking_databases WHERE database_id = DB_ID())
    ALTER DATABASE SqlServerRagWalkthrough SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);

DROP TABLE IF EXISTS dbo.notes;
CREATE TABLE dbo.notes (id INT CONSTRAINT PK_notes PRIMARY KEY, body NVARCHAR(500) NOT NULL);
ALTER TABLE dbo.notes ENABLE CHANGE_TRACKING;
GO

DECLARE @last_sync BIGINT = CHANGE_TRACKING_CURRENT_VERSION();  -- a job saves this after each run

INSERT INTO dbo.notes VALUES (1, N'New note'), (2, N'Another note');
UPDATE dbo.notes SET body = N'Edited note' WHERE id = 1;

-- The rows to re-embed since the last sync (I = inserted; an update after an insert still counts as I)
SELECT n.id, n.body, ct.SYS_CHANGE_OPERATION AS operation
FROM CHANGETABLE(CHANGES dbo.notes, @last_sync) AS ct
JOIN dbo.notes AS n ON n.id = ct.id;
GO

-- ── 15. Embedding models inside SQL Server (needs an HTTPS endpoint) ──
-- SQL Server can call an embedding model itself, with no Python. The model must be behind HTTPS
-- (Azure OpenAI, OpenAI, or Ollama behind a TLS proxy), so this section is commented out:
-- fill in the placeholders, then select the block and run it.
/*
-- Allow calls to external REST endpoints (server-wide, needs sysadmin)
EXECUTE sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;

-- The API key lives in a database scoped credential, which needs a database master key.
-- The credential's name must be the endpoint URL (without the path).
IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong-password>';

CREATE DATABASE SCOPED CREDENTIAL [https://<your-resource>.openai.azure.com/]
    WITH IDENTITY = 'HTTPEndpointHeaders', SECRET = '{"api-key":"<your-api-key>"}';

-- Register the model. API_FORMAT: 'Azure OpenAI' | 'OpenAI' | 'Ollama' | 'ONNX Runtime'
CREATE EXTERNAL MODEL AzureEmbeddings
WITH (
    LOCATION   = 'https://<your-resource>.openai.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2024-02-01',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'text-embedding-3-small',
    CREDENTIAL = [https://<your-resource>.openai.azure.com/]
);

-- AI_GENERATE_EMBEDDINGS embeds text inline. Vectors from different models aren't comparable,
-- so don't search the app's bge-m3 chunks with these.
DECLARE @v VECTOR(1536) = AI_GENERATE_EMBEDDINGS(N'Hvað marga orlofsdaga á ári á starfsmaður rétt á?' USE MODEL AzureEmbeddings);
SELECT @v AS embedding;

-- A trigger that re-embeds a note whenever its text changes (simple, but every write waits for the model)
ALTER TABLE dbo.notes ADD embedding VECTOR(1536) NULL;
GO
CREATE OR ALTER TRIGGER dbo.trg_notes_embedding ON dbo.notes AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(body) RETURN;
    UPDATE n SET embedding = AI_GENERATE_EMBEDDINGS(n.body USE MODEL AzureEmbeddings)
    FROM dbo.notes AS n JOIN inserted AS i ON i.id = n.id;
END;
GO

-- sp_invoke_external_rest_endpoint calls any HTTPS endpoint, e.g. a chat model for the answer step.
-- The response body is in $.result.
DECLARE @response NVARCHAR(MAX);
EXEC sp_invoke_external_rest_endpoint
    @url      = 'https://<your-resource>.openai.azure.com/openai/deployments/<chat-model>/chat/completions?api-version=2024-10-21',
    @method   = 'POST',
    @headers  = '{"api-key": "<your-api-key>"}',
    @payload  = '{"messages": [{"role": "user", "content": "Say hello in Icelandic"}]}',
    @response = @response OUTPUT;
SELECT JSON_VALUE(@response, '$.result.choices[0].message.content') AS answer;
*/

-- ── Clean up: drop the scratch database when you're done ───────
-- USE master;
-- ALTER DATABASE SqlServerRagWalkthrough SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE SqlServerRagWalkthrough;
