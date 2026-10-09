-- Hybrid search: take the top candidates by vector distance (exact) and by full-text relevance
-- (FREETEXTTABLE), then fuse the two lists with Reciprocal Rank Fusion: score = sum of 1/(60 + rank).
-- Also returns the distance of the closest chunk, so the app can refuse when nothing is close.
CREATE PROCEDURE dbo.search_hybrid
    @query_vector VECTOR(1024),
    @query_text   NVARCHAR(4000),
    @top_k        INT,
    @candidates   INT
AS
BEGIN
    SET NOCOUNT ON;

    WITH vector_ranks AS (
        SELECT TOP (@candidates) id, distance, ROW_NUMBER() OVER (ORDER BY distance) AS rank
        FROM (SELECT id, VECTOR_DISTANCE('cosine', embedding, @query_vector) AS distance FROM dbo.chunks) AS d
        ORDER BY rank
    ),
    fulltext_ranks AS (
        -- LANGUAGE 0 (neutral) matches how the full-text index was built
        SELECT TOP (@candidates) [KEY] AS id, ROW_NUMBER() OVER (ORDER BY RANK DESC) AS rank
        FROM FREETEXTTABLE(dbo.chunks, content, @query_text, LANGUAGE 0)
        ORDER BY rank
    ),
    fused AS (
        SELECT COALESCE(v.id, f.id) AS id,
            ISNULL(1.0 / (60 + v.rank), 0) + ISNULL(1.0 / (60 + f.rank), 0) AS score
        FROM vector_ranks AS v
        FULL OUTER JOIN fulltext_ranks AS f ON f.id = v.id
    )
    SELECT TOP (@top_k) c.id, c.source, c.content, CAST(fused.score AS FLOAT) AS score,
        (SELECT MIN(distance) FROM vector_ranks) AS closest
    FROM fused
    JOIN dbo.chunks AS c ON c.id = fused.id
    ORDER BY fused.score DESC;
END
