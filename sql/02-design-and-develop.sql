-- ============================================================
-- 2 of 3: DESIGN AND DEVELOP (sections 8–18)
-- Tables and constraints, sequences, the json type, a view, functions and a trigger, CTEs and
-- window functions, regex, fuzzy matching, temporal/ledger/graph/in-memory tables, partitioning,
-- columnstore and error handling, all on the app's documents.
--
-- Connect as described in 01-app-searches.sql, then run one section at a time.
--
-- Files 2 and 3 create their own objects, so they run in a separate scratch database,
-- SqlServerRagScratch, with a copy of the app's chunks. The app's database stays untouched.
-- Section 8 (re)creates the scratch database: run it again any time to start over.
-- ============================================================

-- ── 8. Setup: a scratch database with a copy of the chunks ────
-- Starting over also removes the server audit from section 22, which lives outside the database
USE master;
IF EXISTS (SELECT * FROM sys.server_audits WHERE name = N'rag_scratch_audit')
BEGIN
    ALTER SERVER AUDIT rag_scratch_audit WITH (STATE = OFF);
    DROP SERVER AUDIT rag_scratch_audit;
END;
IF DB_ID(N'SqlServerRagScratch') IS NOT NULL
BEGIN
    ALTER DATABASE SqlServerRagScratch SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SqlServerRagScratch;
END;
CREATE DATABASE SqlServerRagScratch;
GO

USE SqlServerRagScratch;
-- JSON indexes and fuzzy string matching are preview features in SQL Server 2025
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

-- The same chunks, plus the department that owns each document (used for Row-Level Security in section 19).
-- The constraints keep the data valid: a primary key, NOT NULL, a CHECK on the allowed departments
CREATE TABLE dbo.chunks
(
    id         INT           CONSTRAINT PK_chunks PRIMARY KEY,
    source     NVARCHAR(500) NOT NULL,
    department VARCHAR(20)   NOT NULL CONSTRAINT CK_chunks_department CHECK (department IN ('HR', 'IT', 'Finance')),
    content    NVARCHAR(MAX) NOT NULL,
    embedding  VECTOR(1024)  NOT NULL
);

INSERT INTO dbo.chunks (id, source, department, content, embedding)
SELECT id, source,
       CASE WHEN source IN (N'Demo_IT_Reglur.pdf', N'Demo_Oryggi_og_neydaraaetlun.pdf',
                            N'Demo_Personuverndarstefna.pdf', N'Demo_Samfelluaaetlun.pdf') THEN 'IT'
            WHEN source IN (N'Demo_Innkaup_og_kostnadur.pdf', N'Demo_Thjonustulysing.pdf',
                            N'Demo_Verklagsreglur.pdf', N'Demo_Um_fyrirtaekid.pdf') THEN 'Finance'
            ELSE 'HR' END,
       content, embedding
FROM SqlServerRag.dbo.chunks;

SELECT department, COUNT(DISTINCT source) AS documents, COUNT(*) AS chunks
FROM dbo.chunks
GROUP BY department;
GO

-- ── 9. Vector functions ────────────────────────────────────────
-- Two neighbouring chunks of the same document, compared with each metric
DECLARE @a VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks ORDER BY id);
DECLARE @b VECTOR(1024) = (SELECT embedding FROM dbo.chunks WHERE id = (SELECT MIN(id) + 1 FROM dbo.chunks));

SELECT VECTOR_DISTANCE('cosine',    @a, @b) AS cosine,     -- 0 = same direction (what the app uses)
       VECTOR_DISTANCE('euclidean', @a, @b) AS euclidean,  -- straight-line distance
       VECTOR_DISTANCE('dot',       @a, @b) AS dot;        -- negative dot product (lower = more similar)

-- bge-m3 vectors have length 1, which is why cosine and dot rank them the same way
SELECT TOP (1)
    CAST(VECTORPROPERTY(embedding, 'Dimensions') AS INT)        AS dimensions,
    CAST(VECTORPROPERTY(embedding, 'BaseType') AS NVARCHAR(20)) AS base_type
FROM dbo.chunks;

-- VECTOR_NORMALIZE scales a vector to length 1 (norm2), like the ones above
DECLARE @v VECTOR(3) = '[3.0, 4.0, 0.0]';
SELECT VECTOR_NORMALIZE(@v, 'norm2') AS normalized;  -- [0.6, 0.8, 0]
GO

-- ── 10. A logged answer: SEQUENCE, constraints, the json type and a JSON index ──
-- A sequence hands out answer numbers (unlike IDENTITY, it isn't tied to one table)
CREATE SEQUENCE dbo.answer_number AS INT START WITH 1000 INCREMENT BY 1;

CREATE TABLE dbo.answers
(
    id       INT           NOT NULL CONSTRAINT DF_answers_id DEFAULT (NEXT VALUE FOR dbo.answer_number)
                                    CONSTRAINT PK_answers PRIMARY KEY,
    question NVARCHAR(500) NOT NULL,
    asked_at DATETIME2     NOT NULL CONSTRAINT DF_answers_asked_at DEFAULT (SYSUTCDATETIME()),
    details  JSON          NOT NULL  -- mode, top chunks and scores, as native json
);

-- Feedback on an answer: a foreign key to the answer, one rating per answer (UNIQUE), 1–5 (CHECK)
CREATE TABLE dbo.feedback
(
    id        INT IDENTITY CONSTRAINT PK_feedback PRIMARY KEY,
    answer_id INT NOT NULL CONSTRAINT FK_feedback_answers REFERENCES dbo.answers (id),
    rating    TINYINT NOT NULL CONSTRAINT CK_feedback_rating CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT UQ_feedback_answer UNIQUE (answer_id)
);
GO

-- Run the app's real hybrid search and log what it returned, as JSON
DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks WHERE source = N'Demo_Starfsmannahandbok.pdf' ORDER BY id);

CREATE TABLE #results (id INT, source NVARCHAR(500), content NVARCHAR(MAX), score FLOAT, closest FLOAT);
INSERT INTO #results
EXEC SqlServerRag.dbo.search_hybrid @query_vector = @q, @query_text = N'orlof', @top_k = 5, @candidates = 20;

INSERT INTO dbo.answers (question, details)
SELECT N'Hvað marga orlofsdaga á ári á starfsmaður rétt á?',
       JSON_OBJECT('mode': 'hybrid',
                   'closest_distance': MIN(closest),
                   'chunks': JSON_ARRAYAGG(JSON_OBJECT('source': source, 'score': ROUND(score, 4))))
FROM #results;
DROP TABLE #results;

-- The constraints at work: the first insert succeeds, the second breaks the CHECK
INSERT INTO dbo.feedback (answer_id, rating) SELECT MAX(id), 5 FROM dbo.answers;
BEGIN TRY
    INSERT INTO dbo.feedback (answer_id, rating) SELECT MAX(id), 9 FROM dbo.answers;
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS rejected;
END CATCH;

SELECT id, question, details FROM dbo.answers;
GO

-- ── 11. Querying JSON ──────────────────────────────────────────
-- A JSON index speeds up filters on paths inside a json column
CREATE JSON INDEX ix_answers_details ON dbo.answers (details) FOR ('$.mode', '$.chunks');
GO

-- JSON_VALUE reads one scalar
SELECT id, JSON_VALUE(details, '$.mode') AS mode, JSON_VALUE(details, '$.closest_distance') AS closest
FROM dbo.answers;

-- OPENJSON turns the array into rows: one row per chunk the answer used
SELECT a.id, c.source, c.score
FROM dbo.answers AS a
CROSS APPLY OPENJSON(a.details, '$.chunks') WITH (source NVARCHAR(500) '$.source', score FLOAT '$.score') AS c;

-- JSON_CONTAINS searches inside an array ([*] is required)
SELECT id, question
FROM dbo.answers
WHERE JSON_CONTAINS(details, N'Demo_Starfsmannahandbok.pdf', '$.chunks[*].source') = 1;

-- JSON_ARRAY builds an array from values
SELECT JSON_ARRAY('HR', 'IT', 'Finance') AS departments;
GO

-- ── 12. Programmability: a view, functions and a trigger ──────
-- A view: one row per document
CREATE OR ALTER VIEW dbo.document_stats
AS
SELECT source, department, COUNT(*) AS chunks, AVG(LEN(content)) AS avg_chunk_length
FROM dbo.chunks
GROUP BY source, department;
GO

-- A scalar function: hide email addresses before text leaves the database
CREATE OR ALTER FUNCTION dbo.redact_emails (@text NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN REGEXP_REPLACE(@text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]');
END;
GO

-- An inline table-valued function: the chunks most similar to a given chunk
CREATE OR ALTER FUNCTION dbo.similar_chunks (@chunk_id INT, @top_k INT)
RETURNS TABLE
AS
RETURN
    SELECT TOP (@top_k) c.id, c.source, VECTOR_DISTANCE('cosine', c.embedding, q.embedding) AS distance
    FROM dbo.chunks AS c
    CROSS JOIN (SELECT embedding FROM dbo.chunks WHERE id = @chunk_id) AS q
    WHERE c.id <> @chunk_id
    ORDER BY distance;
GO

-- A trigger: record every rating change in an audit table
CREATE TABLE dbo.feedback_changes
(
    feedback_id INT       NOT NULL,
    old_rating  TINYINT   NULL,
    new_rating  TINYINT   NOT NULL,
    changed_at  DATETIME2 NOT NULL DEFAULT (SYSUTCDATETIME())
);
GO

CREATE OR ALTER TRIGGER dbo.trg_feedback_changes ON dbo.feedback AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.feedback_changes (feedback_id, old_rating, new_rating)
    SELECT i.id, d.rating, i.rating
    FROM inserted AS i JOIN deleted AS d ON d.id = i.id;
END;
GO

SELECT * FROM dbo.document_stats ORDER BY chunks DESC;

SELECT TOP (1) dbo.redact_emails(content) AS redacted
FROM dbo.chunks
WHERE content LIKE N'%@%';

DECLARE @first INT = (SELECT MIN(id) FROM dbo.chunks);
SELECT * FROM dbo.similar_chunks(@first, 5);

UPDATE dbo.feedback SET rating = 4;
SELECT * FROM dbo.feedback_changes;
GO

-- ── 13. CTEs, window functions and a correlated subquery ───────
-- How much does the topic shift from one chunk to the next within a document?
-- ROW_NUMBER numbers the chunks per document; LAG reaches back to the previous one.
-- LAG doesn't accept the vector type, so it fetches the previous chunk's id instead
WITH ordered AS (
    SELECT source, id,
           ROW_NUMBER() OVER (PARTITION BY source ORDER BY id) AS position,
           LAG(id) OVER (PARTITION BY source ORDER BY id) AS previous_id
    FROM dbo.chunks
)
SELECT TOP (10) o.source, o.position,
       VECTOR_DISTANCE('cosine', c.embedding, p.embedding) AS shift_from_previous_chunk
FROM ordered AS o
JOIN dbo.chunks AS c ON c.id = o.id
JOIN dbo.chunks AS p ON p.id = o.previous_id
ORDER BY shift_from_previous_chunk DESC;

-- Running totals and ranks over the view from section 12. ROWS UNBOUNDED PRECEDING sets an explicit
-- frame; the default RANGE frame is slower and can't order by a key this long (900-byte limit)
SELECT department, source, chunks,
       SUM(chunks) OVER (PARTITION BY department ORDER BY source ROWS UNBOUNDED PRECEDING) AS running_total_in_department,
       RANK() OVER (ORDER BY chunks DESC) AS size_rank
FROM dbo.document_stats;

-- A correlated subquery: for each document, the closest chunk from a *different* document.
-- The inner query refers to the outer row (d), so it runs once per document
WITH first_chunks AS (
    SELECT c.source, c.embedding
    FROM dbo.chunks AS c
    WHERE c.id = (SELECT MIN(c2.id) FROM dbo.chunks AS c2 WHERE c2.source = c.source)
)
SELECT d.source,
       (SELECT TOP (1) o.source
        FROM dbo.chunks AS o
        WHERE o.source <> d.source
        ORDER BY VECTOR_DISTANCE('cosine', o.embedding, d.embedding)) AS closest_other_document
FROM first_chunks AS d
ORDER BY d.source;
GO

-- ── 14. Regular expressions on the documents ───────────────────
DECLARE @email NVARCHAR(100) = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}';

-- REGEXP_LIKE returns a boolean, so it goes in WHERE, CASE or CHECK
SELECT COUNT(*) AS chunks_with_an_email
FROM dbo.chunks
WHERE REGEXP_LIKE(content, @email);

-- REGEXP_SUBSTR: the first match; REGEXP_INSTR: where it starts (1-based)
SELECT DISTINCT REGEXP_SUBSTR(content, @email) AS email
FROM dbo.chunks
WHERE REGEXP_INSTR(content, @email) > 0;

-- REGEXP_MATCHES: one row per match. Amounts in Icelandic format, like 8.000 kr
SELECT TOP (10) c.source, m.match_value AS amount
FROM dbo.chunks AS c
CROSS APPLY REGEXP_MATCHES(c.content, '\d{1,3}(\.\d{3})+ kr') AS m
ORDER BY c.id;

-- REGEXP_COUNT: how many amounts each document mentions
SELECT source, SUM(REGEXP_COUNT(content, '\d{1,3}(\.\d{3})+ kr')) AS amounts
FROM dbo.chunks
GROUP BY source
ORDER BY amounts DESC;

-- REGEXP_REPLACE is used in dbo.redact_emails (section 12).
-- REGEXP_SPLIT_TO_TABLE: split the first chunk into its lines
SELECT ordinal, value AS line
FROM REGEXP_SPLIT_TO_TABLE((SELECT TOP (1) content FROM dbo.chunks ORDER BY id), '\n');
GO

-- ── 15. Fuzzy string matching: find a document from a typo ──────
-- These functions don't support SQL_* collations (the Docker default), hence COLLATE
WITH documents AS (
    SELECT DISTINCT REPLACE(REPLACE(source, 'Demo_', ''), '.pdf', '') COLLATE Latin1_General_100_CI_AS AS name
    FROM dbo.chunks
)
SELECT TOP (3)
    name,
    EDIT_DISTANCE(name, N'Starfsmanahandbók')            AS edit_distance,        -- edits needed
    EDIT_DISTANCE_SIMILARITY(name, N'Starfsmanahandbók') AS edit_similarity,      -- 0–100
    JARO_WINKLER_DISTANCE(name, N'Starfsmanahandbók')    AS jaro_winkler_distance -- 0 = identical
FROM documents
ORDER BY JARO_WINKLER_SIMILARITY(name, N'Starfsmanahandbók') DESC;
GO

-- ── 16. Specialized tables: temporal, ledger, graph and in-memory ──
-- Temporal: SQL Server keeps every earlier version of a row. Here a chunk's text is edited,
-- as if the source document changed, and the history keeps the old version
CREATE TABLE dbo.chunk_versions
(
    id         INT           CONSTRAINT PK_chunk_versions PRIMARY KEY,
    content    NVARCHAR(MAX) NOT NULL,
    valid_from DATETIME2 GENERATED ALWAYS AS ROW START,
    valid_to   DATETIME2 GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (valid_from, valid_to)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.chunk_versions_history));

INSERT INTO dbo.chunk_versions (id, content)
SELECT TOP (1) id, content FROM dbo.chunks WHERE content LIKE N'%24 daga orlofi%';

UPDATE dbo.chunk_versions SET content = REPLACE(content, N'24 daga orlofi', N'25 daga orlofi');

SELECT id, valid_from, valid_to,
       REGEXP_SUBSTR(content, '\d+ daga orlofi') AS vacation_days
FROM dbo.chunk_versions FOR SYSTEM_TIME ALL
ORDER BY valid_from;
GO

-- Ledger (append-only): a tamper-evident log of the questions asked
CREATE TABLE dbo.question_log
(
    id       INT IDENTITY,
    question NVARCHAR(500) NOT NULL,
    asked_at DATETIME2 NOT NULL DEFAULT (SYSUTCDATETIME())
)
WITH (LEDGER = ON (APPEND_ONLY = ON));
GO

INSERT INTO dbo.question_log (question) VALUES (N'Hvað marga orlofsdaga á ári á starfsmaður rétt á?');
SELECT * FROM dbo.question_log;
GO

-- Graph: documents and the departments that own them, built from the data, queried with MATCH
CREATE TABLE dbo.document_node   (name NVARCHAR(500) CONSTRAINT PK_document_node PRIMARY KEY) AS NODE;
CREATE TABLE dbo.department_node (name VARCHAR(20)   CONSTRAINT PK_department_node PRIMARY KEY) AS NODE;
CREATE TABLE dbo.owned_by AS EDGE;

INSERT INTO dbo.document_node (name) SELECT DISTINCT source FROM dbo.chunks;
INSERT INTO dbo.department_node (name) SELECT DISTINCT department FROM dbo.chunks;

-- Edges connect two $node_id values
INSERT INTO dbo.owned_by ($from_id, $to_id)
SELECT DISTINCT d.$node_id, p.$node_id
FROM dbo.chunks AS c
JOIN dbo.document_node AS d ON d.name = c.source
JOIN dbo.department_node AS p ON p.name = c.department;

-- Which other documents belong to the same department as the staff handbook?
SELECT other.name AS same_department_as_staff_handbook, dept.name AS department
FROM dbo.document_node AS handbook, dbo.owned_by AS o1, dbo.department_node AS dept,
     dbo.owned_by AS o2, dbo.document_node AS other
WHERE MATCH(handbook-(o1)->dept<-(o2)-other)
  AND handbook.name = N'Demo_Starfsmannahandbok.pdf' AND other.name <> handbook.name;
GO

-- In-memory OLTP: a memory-optimized table for chat sessions. SCHEMA_ONLY means the rows
-- aren't written to disk, which suits short-lived state. It needs a memory-optimized filegroup
ALTER DATABASE SqlServerRagScratch ADD FILEGROUP imoltp CONTAINS MEMORY_OPTIMIZED_DATA;
ALTER DATABASE SqlServerRagScratch
    ADD FILE (NAME = N'imoltp', FILENAME = N'/var/opt/mssql/data/SqlServerRagScratch_imoltp') TO FILEGROUP imoltp;
GO

CREATE TABLE dbo.chat_sessions
(
    session_id   UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_chat_sessions PRIMARY KEY NONCLUSTERED,
    last_message NVARCHAR(500)    NOT NULL,
    updated_at   DATETIME2        NOT NULL
)
WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY);
GO

INSERT INTO dbo.chat_sessions VALUES (NEWID(), N'Og með hve löngum fyrirvara þarf að sækja um?', SYSUTCDATETIME());
SELECT * FROM dbo.chat_sessions;
GO

-- ── 17. Partitioning and columnstore: a year of usage data ─────
-- A partition function splits rows by month; the scheme maps every partition to a filegroup
CREATE PARTITION FUNCTION pf_month (DATE)
    AS RANGE RIGHT FOR VALUES ('2026-02-01', '2026-03-01', '2026-04-01', '2026-05-01', '2026-06-01',
                               '2026-07-01', '2026-08-01', '2026-09-01', '2026-10-01', '2026-11-01', '2026-12-01');
CREATE PARTITION SCHEME ps_month AS PARTITION pf_month ALL TO ([PRIMARY]);
GO

-- A clustered columnstore index stores the table by column: good for scanning and aggregating millions of rows
CREATE TABLE dbo.search_usage
(
    used_on     DATE          NOT NULL,
    source      NVARCHAR(500) NOT NULL,
    mode        VARCHAR(10)   NOT NULL,
    duration_ms DECIMAL(9, 2) NOT NULL,
    INDEX cci_search_usage CLUSTERED COLUMNSTORE
) ON ps_month (used_on);

-- Simulated usage: 200,000 searches spread over 2026, against the real documents
WITH documents AS (
    SELECT source, ROW_NUMBER() OVER (ORDER BY source) - 1 AS n, COUNT(*) OVER () AS total
    FROM (SELECT DISTINCT source FROM dbo.chunks) AS d
)
INSERT INTO dbo.search_usage (used_on, source, mode, duration_ms)
SELECT DATEADD(DAY, s.value % 365, '2026-01-01'),
       d.source,
       CASE WHEN s.value % 3 = 0 THEN 'vector' ELSE 'hybrid' END,
       CASE WHEN s.value % 3 = 0 THEN 2.0 ELSE 7.0 END + (s.value % 100) / 50.0
FROM GENERATE_SERIES(1, 200000) AS s
JOIN documents AS d ON d.n = s.value % d.total;

-- Each month holds under 102,400 rows, so the rows wait in open (uncompressed) delta row groups.
-- REORGANIZE compresses them into columnstore segments; the row group view shows the result
ALTER INDEX cci_search_usage ON dbo.search_usage REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);

SELECT state_desc, COUNT(*) AS row_groups, SUM(total_rows) AS total_rows, SUM(size_in_bytes) / 1024 AS size_kb
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID(N'dbo.search_usage')
GROUP BY state_desc;

-- Rows per partition (one per month)
SELECT p.partition_number, p.rows
FROM sys.partitions AS p
WHERE p.object_id = OBJECT_ID(N'dbo.search_usage') AND p.index_id = 1
ORDER BY p.partition_number;

-- An analytic query the columnstore is built for
SELECT DATETRUNC(MONTH, used_on) AS month, mode, COUNT(*) AS searches, AVG(duration_ms) AS avg_ms
FROM dbo.search_usage
GROUP BY DATETRUNC(MONTH, used_on), mode
ORDER BY month, mode;
GO

-- ── 18. Error handling: TRY/CATCH and THROW ────────────────────
-- A ledger table is append-only, so an UPDATE fails. SQL Server rejects it while compiling the
-- statement, and CATCH can't catch compile errors in its own batch, so it runs in its own scope
BEGIN TRY
    EXEC sys.sp_executesql N'UPDATE dbo.question_log SET question = N''changed'';';
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
END CATCH;

-- THROW raises your own error, like the app refusing when no chunk is close enough.
-- The question is logged inside a transaction that CATCH rolls back, so nothing is half-saved
DECLARE @closest FLOAT = 0.7;  -- an off-topic question: its closest chunk is 0.7 away (the app's cut-off is 0.52)

BEGIN TRY
    BEGIN TRANSACTION;
    INSERT INTO dbo.question_log (question) VALUES (N'Hvað kostar að leigja fundarherbergi?');
    IF @closest > 0.52
        THROW 50001, N'No chunk is close enough to answer from.', 1;
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    SELECT ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS error_message;
END CATCH;

SELECT COUNT(*) AS logged_off_topic_questions  -- 0: the insert was rolled back
FROM dbo.question_log WHERE question = N'Hvað kostar að leigja fundarherbergi?';
GO
