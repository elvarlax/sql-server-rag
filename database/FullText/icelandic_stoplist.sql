-- SQL Server has no Icelandic stopword list, so without one, words like "á", "að" and "hvað"
-- match almost every chunk and drown out the real search terms. The project can declare the
-- stoplist but not its words, so Scripts/PostDeployment.sql adds them.
CREATE FULLTEXT STOPLIST icelandic;
