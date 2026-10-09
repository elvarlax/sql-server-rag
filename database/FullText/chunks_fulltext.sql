-- Full-text index for hybrid search. CHANGE_TRACKING AUTO keeps it up to date when ingest replaces the rows.
CREATE FULLTEXT INDEX ON dbo.chunks (content LANGUAGE 0)
    KEY INDEX PK_chunks ON ft_rag
    WITH STOPLIST = icelandic, CHANGE_TRACKING AUTO;
