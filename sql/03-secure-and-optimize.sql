-- ============================================================
-- 3 of 3: SECURE AND OPTIMIZE (sections 19–25)
-- Row-Level Security, Dynamic Data Masking, column-level encryption, auditing, performance
-- (statistics, DMVs, blocking, isolation levels), Change Tracking, and calling models from T-SQL.
--
-- Connect with SSMS or VS Code (mssql extension):
--   Server:   tcp:localhost,1433   (tcp: makes sure you reach the Docker container)
--   Login:    sa, with SQL_PASSWORD from .env
--   Encrypt:  Mandatory, with "Trust server certificate" checked
-- Ingest the documents in the app first, then run one section at a time.
--
-- Uses the scratch database from 02-design-and-develop.sql: run that file first.
-- To run this file again, run section 8 in 02 first; it recreates the scratch database.
-- ============================================================

USE SqlServerRagWalkthrough;
GO

-- ── 19. Row-Level Security: each department sees only its own documents ──
-- Users without logins, one per department, to impersonate with EXECUTE AS USER
CREATE USER hr_user WITHOUT LOGIN;
CREATE USER it_user WITHOUT LOGIN;
CREATE TABLE dbo.user_departments (user_name SYSNAME CONSTRAINT PK_user_departments PRIMARY KEY, department VARCHAR(20) NOT NULL);
INSERT INTO dbo.user_departments VALUES (N'hr_user', 'HR'), (N'it_user', 'IT');
GRANT SELECT ON dbo.chunks TO hr_user, it_user;
GO

CREATE SCHEMA security;
GO

-- The predicate function returns a row when the current user may see a chunk. dbo sees everything
CREATE FUNCTION security.can_see_department (@department VARCHAR(20))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS allowed
    WHERE USER_NAME() = N'dbo'
       OR @department = (SELECT department FROM dbo.user_departments WHERE user_name = USER_NAME());
GO

CREATE SECURITY POLICY security.department_filter
    ADD FILTER PREDICATE security.can_see_department(department) ON dbo.chunks
    WITH (STATE = ON);
GO

-- The same query, run as each user
EXECUTE AS USER = N'hr_user';
SELECT USER_NAME() AS user_name, department, COUNT(*) AS visible_chunks FROM dbo.chunks GROUP BY department;
REVERT;

EXECUTE AS USER = N'it_user';
SELECT USER_NAME() AS user_name, department, COUNT(*) AS visible_chunks FROM dbo.chunks GROUP BY department;
REVERT;

-- RLS also applies to vector search: the HR user's nearest chunks only come from HR documents,
-- even when the question is closest to an IT document
DECLARE @it_question VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks WHERE department = 'IT' ORDER BY id);
EXECUTE AS USER = N'hr_user';
SELECT TOP (3) source, VECTOR_DISTANCE('cosine', embedding, @it_question) AS distance
FROM dbo.chunks ORDER BY distance;
REVERT;
GO

-- ── 20. Dynamic Data Masking: the email addresses in the documents ──
-- Pull the addresses out of the documents with regex, then mask them for users without UNMASK
CREATE TABLE dbo.contacts
(
    email  NVARCHAR(200) MASKED WITH (FUNCTION = 'email()') CONSTRAINT PK_contacts PRIMARY KEY,
    source NVARCHAR(500) NOT NULL
);

INSERT INTO dbo.contacts (email, source)
SELECT REGEXP_SUBSTR(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'), MIN(source)
FROM dbo.chunks
WHERE REGEXP_LIKE(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
GROUP BY REGEXP_SUBSTR(content, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

GRANT SELECT ON dbo.contacts TO hr_user;
GO

SELECT email, source FROM dbo.contacts;         -- dbo: the real addresses

EXECUTE AS USER = N'hr_user';
SELECT email, source FROM dbo.contacts;         -- hr_user: aXX@XXXX.com
REVERT;

-- Masking only hides values; UNMASK gives them back
GRANT UNMASK TO hr_user;
EXECUTE AS USER = N'hr_user';
SELECT email FROM dbo.contacts;
REVERT;
REVOKE UNMASK FROM hr_user;
GO

-- ── 21. Column-level encryption ────────────────────────────────
-- Encrypt a column inside the database with a symmetric key, protected by a certificate.
-- (Always Encrypted goes further: the keys stay with the client, so even sa can't read the data.
-- It needs client-side configuration, so it can't be shown in T-SQL alone.)
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'Walkthrough-Only-Passw0rd!';
CREATE CERTIFICATE contacts_cert WITH SUBJECT = N'Protects the contacts key';
CREATE SYMMETRIC KEY contacts_key WITH ALGORITHM = AES_256 ENCRYPTION BY CERTIFICATE contacts_cert;
GO

ALTER TABLE dbo.contacts ADD email_encrypted VARBINARY(256) NULL;
GO

OPEN SYMMETRIC KEY contacts_key DECRYPTION BY CERTIFICATE contacts_cert;
UPDATE dbo.contacts SET email_encrypted = ENCRYPTBYKEY(KEY_GUID(N'contacts_key'), email);

SELECT TOP (2) email_encrypted,
       CONVERT(NVARCHAR(200), DECRYPTBYKEY(email_encrypted)) AS decrypted
FROM dbo.contacts;
CLOSE SYMMETRIC KEY contacts_key;

-- Without the key open, decryption returns NULL
SELECT TOP (2) CONVERT(NVARCHAR(200), DECRYPTBYKEY(email_encrypted)) AS key_closed FROM dbo.contacts;
GO

-- ── 22. Auditing ───────────────────────────────────────────────
-- A server audit writes to a file; a database audit specification says what to record
USE master;
IF EXISTS (SELECT * FROM sys.server_audits WHERE name = N'rag_walkthrough_audit')
BEGIN
    ALTER SERVER AUDIT rag_walkthrough_audit WITH (STATE = OFF);
    DROP SERVER AUDIT rag_walkthrough_audit;
END;
CREATE SERVER AUDIT rag_walkthrough_audit TO FILE (FILEPATH = N'/var/opt/mssql/data/');
ALTER SERVER AUDIT rag_walkthrough_audit WITH (STATE = ON);
GO

USE SqlServerRagWalkthrough;
CREATE DATABASE AUDIT SPECIFICATION contacts_reads
    FOR SERVER AUDIT rag_walkthrough_audit
    ADD (SELECT ON OBJECT::dbo.contacts BY public)
    WITH (STATE = ON);
GO

EXECUTE AS USER = N'hr_user';
SELECT COUNT(*) AS contacts FROM dbo.contacts;
REVERT;
GO

-- Who read the contacts, and with which statement (the audit writes asynchronously, hence the wait)
WAITFOR DELAY '00:00:02';
SELECT event_time, database_principal_name, statement
FROM sys.fn_get_audit_file(N'/var/opt/mssql/data/rag_walkthrough_audit*.sqlaudit', DEFAULT, DEFAULT)
WHERE object_name = N'contacts'
ORDER BY event_time DESC;
GO

-- ── 23. Performance: statistics, plans, DMVs and isolation levels ──
-- STATISTICS IO/TIME show the reads and time per statement (in the Messages tab);
-- Ctrl+M in SSMS shows the actual execution plan
SET STATISTICS IO, TIME ON;
DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks ORDER BY id);
SELECT TOP (5) id, VECTOR_DISTANCE('cosine', embedding, @q) AS distance FROM dbo.chunks ORDER BY distance;
SET STATISTICS IO, TIME OFF;

-- DMVs: the most expensive queries in the plan cache right now, with their plans
SELECT TOP (5)
    qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000.0 AS avg_cpu_ms,
    qs.total_logical_reads / qs.execution_count        AS avg_reads,
    LEFT(st.text, 80)                                  AS query,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE st.dbid = DB_ID()
ORDER BY qs.total_worker_time DESC;

-- Blocking: requests waiting on another session (empty unless something is blocked).
-- To see it, start BEGIN TRAN; UPDATE dbo.feedback SET rating = 1; in another window and
-- SELECT * FROM dbo.feedback; in a third, then run this
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time, t.text
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0;

-- Isolation: with READ_COMMITTED_SNAPSHOT, readers see the last committed version instead of
-- waiting on writers. SNAPSHOT gives a transaction one consistent view from its start
ALTER DATABASE SqlServerRagWalkthrough SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
ALTER DATABASE SqlServerRagWalkthrough SET ALLOW_SNAPSHOT_ISOLATION ON;
SELECT name, is_read_committed_snapshot_on, snapshot_isolation_state_desc
FROM sys.databases WHERE name = DB_NAME();

SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRANSACTION;
    SELECT COUNT(*) AS chunks_in_my_snapshot FROM dbo.chunks;
COMMIT;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
GO

-- ── 24. Keeping embeddings in sync: Change Tracking ────────────
-- When a document changes, only the changed chunks need new embeddings. Change Tracking records
-- which rows changed (not the old values); a job reads the changes since its last sync and
-- re-embeds those rows. The Azure Functions SQL trigger binding uses it too.
-- Other options: a DML trigger (synchronous, slows down writes; see section 25), Change Data Capture
-- (before/after values, needs SQL Server Agent) and Change Event Streaming (pushes changes to Azure Event Hubs)
ALTER DATABASE SqlServerRagWalkthrough SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
ALTER TABLE dbo.chunks ENABLE CHANGE_TRACKING;
GO

DECLARE @last_sync BIGINT = CHANGE_TRACKING_CURRENT_VERSION();  -- a job saves this after each run

-- The remote work policy changes: two of its chunks are edited
UPDATE dbo.chunks SET content = content + N' (uppfært)'
WHERE id IN (SELECT TOP (2) id FROM dbo.chunks WHERE source = N'Demo_Fjarvinnustefna.pdf' ORDER BY id);

-- The chunks to re-embed since the last sync
SELECT c.id, c.source, ct.SYS_CHANGE_OPERATION AS operation
FROM CHANGETABLE(CHANGES dbo.chunks, @last_sync) AS ct
JOIN dbo.chunks AS c ON c.id = ct.id;
GO

-- ── 25. Embedding models inside SQL Server (needs an HTTPS endpoint) ──
-- SQL Server can call an embedding model itself, with no Python. The model must be behind HTTPS
-- (Azure OpenAI, OpenAI, or Ollama behind a TLS proxy), so this section is commented out:
-- fill in the placeholders, then select the block and run it.
/*
-- Allow calls to external REST endpoints (server-wide, needs sysadmin)
EXECUTE sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;

-- The API key lives in a database scoped credential (the database master key from section 21 protects it).
-- The credential's name must be the endpoint URL (without the path). With Azure SQL, a managed
-- identity can replace the key: IDENTITY = 'Managed Identity'
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
-- so these can't be searched against the bge-m3 chunks.
DECLARE @v VECTOR(1536) = AI_GENERATE_EMBEDDINGS(N'Hvað marga orlofsdaga á ári á starfsmaður rétt á?' USE MODEL AzureEmbeddings);
SELECT @v AS embedding;

-- A trigger that re-embeds a chunk whenever its text changes (simple, but every write waits for the model)
CREATE TABLE dbo.notes (id INT CONSTRAINT PK_notes PRIMARY KEY, body NVARCHAR(500) NOT NULL, embedding VECTOR(1536) NULL);
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

-- RAG's last step from T-SQL: send the retrieved chunks to a chat model with sp_invoke_external_rest_endpoint.
-- FOR JSON turns the rows into the JSON the API expects; the response body is in $.result
DECLARE @context NVARCHAR(MAX) = (SELECT TOP (3) content FROM dbo.chunks WHERE content LIKE N'%orlof%' FOR JSON PATH);
DECLARE @payload NVARCHAR(MAX) = JSON_OBJECT('messages': JSON_ARRAY(
    JSON_OBJECT('role': 'system', 'content': N'Answer only from these passages: ' + @context),
    JSON_OBJECT('role': 'user',   'content': N'Hvað marga orlofsdaga á ári á starfsmaður rétt á?')));
DECLARE @response NVARCHAR(MAX);
EXEC sp_invoke_external_rest_endpoint
    @url        = 'https://<your-resource>.openai.azure.com/openai/deployments/<chat-model>/chat/completions?api-version=2024-10-21',
    @method     = 'POST',
    @credential = [https://<your-resource>.openai.azure.com/],
    @payload    = @payload,
    @response   = @response OUTPUT;
SELECT JSON_VALUE(@response, '$.result.choices[0].message.content') AS answer;
*/

-- ── Clean up: drop the scratch database and the server audit ───
-- USE master;
-- ALTER SERVER AUDIT rag_walkthrough_audit WITH (STATE = OFF);
-- DROP SERVER AUDIT rag_walkthrough_audit;
-- ALTER DATABASE SqlServerRagWalkthrough SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE SqlServerRagWalkthrough;
