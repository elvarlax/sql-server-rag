-- Searching: the app can only run the search procedures, not read or change the table directly.
CREATE ROLE rag_search;
GO
GRANT EXECUTE ON dbo.search_ann TO rag_search;
GO
GRANT EXECUTE ON dbo.search_exact TO rag_search;
GO
GRANT EXECUTE ON dbo.search_hybrid TO rag_search;
