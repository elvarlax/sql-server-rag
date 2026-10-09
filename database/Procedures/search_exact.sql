-- Exact nearest neighbours (ENN/kNN): computes the distance to every chunk. Used when there's no DiskANN index.
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
