-- Reading: see what's stored in dbo.chunks and which indexes it has, without changing anything.
-- For the MCP server's login, so an AI agent can search and check the status but never delete or change data.
CREATE ROLE rag_read;
GO
GRANT SELECT ON dbo.chunks TO rag_read;
