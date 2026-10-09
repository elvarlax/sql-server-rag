-- Approximate nearest neighbours (ANN) through the DiskANN index.
-- A procedure that uses VECTOR_SEARCH can't be created before the vector index exists, and the
-- index is only built by ingest (it needs 100+ rows), so the query runs as dynamic SQL.
-- EXECUTE AS OWNER lets that dynamic SQL read dbo.chunks, so a caller that's only in rag_search
-- needs no access to the table (ownership chaining doesn't reach dynamic SQL).
-- SIMILAR_TO only accepts a variable or column, and table columns come from the TABLE alias (c);
-- only distance comes from the function alias (v).
CREATE PROCEDURE dbo.search_ann
    @query_vector VECTOR(1024),
    @top_k        INT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    EXEC sys.sp_executesql N'
        SELECT c.id, c.source, c.content, v.distance AS score
        FROM VECTOR_SEARCH(TABLE = dbo.chunks AS c, COLUMN = embedding, SIMILAR_TO = @query_vector,
                           METRIC = ''cosine'', TOP_N = @top_k) AS v
        ORDER BY v.distance;',
        N'@query_vector VECTOR(1024), @top_k INT',
        @query_vector, @top_k;
END
