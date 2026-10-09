-- ── Icelandic stopwords ─────────────────────────────────────────────────────────
-- Common function words, excluded from full-text search. LANGUAGE 0 (neutral), because there's
-- no Icelandic word breaker either; the index and FREETEXTTABLE use the same language.
-- Only missing words are added, and the index is repopulated so they apply to existing rows too.
DECLARE @add_words NVARCHAR(MAX) = N'';

SELECT @add_words += N'ALTER FULLTEXT STOPLIST icelandic ADD N''' + w.value + N''' LANGUAGE 0;'
FROM STRING_SPLIT(N'á að af aðeins allt alltaf annað annars auk eða eftir ef eiga ekki ég eins en enda er eru '
    + N'fá fær fæ fyrir frá geta getur get gera hafa hann hefur hér hjá hún hvað hvaða hvar hvenær hver hverjar '
    + N'hverjir hvernig hvort hversu í inn já má með meðan mig mér mín mun nei nú og okkar sem sé sig sín sinn '
    + N'sitt svo til um undir upp úr út var vera verður við yfir þá það þær þann þar þarf þegar þeir þess þessi '
    + N'þetta þig þú þín', N' ') AS w
WHERE NOT EXISTS (
    SELECT * FROM sys.fulltext_stopwords AS s
    JOIN sys.fulltext_stoplists AS l ON l.stoplist_id = s.stoplist_id
    WHERE l.name = N'icelandic' AND s.language_id = 0
      AND s.stopword COLLATE Latin1_General_BIN2 = w.value COLLATE Latin1_General_BIN2
);

IF @add_words <> N''
BEGIN
    EXEC sys.sp_executesql @add_words;
    ALTER FULLTEXT INDEX ON dbo.chunks START FULL POPULATION;
END
GO

-- ── App login ───────────────────────────────────────────────────────────────────
-- The app's own login (instead of sa), with only the two roles it needs.
-- The password comes from SQL_APP_PASSWORD in .env, passed in as a SQLCMD variable.
IF SUSER_ID(N'rag_app') IS NULL
    CREATE LOGIN rag_app WITH PASSWORD = N'$(AppPassword)';
ELSE
    ALTER LOGIN rag_app WITH PASSWORD = N'$(AppPassword)';

IF USER_ID(N'rag_app') IS NULL
    CREATE USER rag_app FOR LOGIN rag_app;

ALTER ROLE rag_search ADD MEMBER rag_app;
ALTER ROLE rag_ingest ADD MEMBER rag_app;
