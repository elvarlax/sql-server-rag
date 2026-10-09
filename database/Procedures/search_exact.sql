-- Exact nearest neighbours (ENN/kNN): computes the distance to every chunk. Used when there's no DiskANN index.
--
-- Example (in SSMS). The app embeds the question with bge-m3; here an existing chunk's
-- embedding stands in for it, so its own chunk should come back first with distance 0:
--   DECLARE @q VECTOR(1024) = (SELECT TOP (1) embedding FROM dbo.chunks ORDER BY id);
--   EXEC dbo.search_exact @query_vector = @q, @top_k = 5;  -- same chunks as search_ann
CREATE PROCEDURE dbo.search_exact
    @query_vector VECTOR(1024),
    @top_k        INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@top_k) id, source, content, VECTOR_DISTANCE('cosine', embedding, @query_vector) AS score
    FROM dbo.chunks
    ORDER BY score;
END
