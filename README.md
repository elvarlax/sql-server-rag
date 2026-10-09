# RAG on SQL Server 2025

![CI](https://github.com/elvarlax/sql-server-rag/actions/workflows/ci.yml/badge.svg)

A small chat app that answers questions about a set of documents, using SQL Server 2025 as the vector database. I built it to try out the new vector features in SQL Server and to find out, by measuring, what actually makes the answers good.

![Asking how many vacation days employees get, then a follow-up about how far in advance to apply. Both answers cite the staff handbook, and the sources show how the follow-up was rewritten for search.](assets/demo.gif)

The demo documents are 14 short policy documents (in Icelandic) for a made-up accounting firm. I generated them with an LLM and then reviewed and edited them. You can ask in Icelandic or English, and every answer cites the passages it used.

## How it works

```
ingest:  docs/ → 500-character chunks (50 overlap) → bge-m3 embeddings → SQL Server (VECTOR(1024) column)

ask:     question → rewrite if it's a follow-up → embed → search SQL Server → top 5 chunks → LLM → answer with [n] citations
```

- **Embeddings**: `bge-m3` in Ollama, running locally. It's multilingual, which matters for Icelandic.
- **Search**: hybrid by default, combining a vector ranking with full-text search (`FREETEXTTABLE`) through Reciprocal Rank Fusion. A vector-only mode uses a DiskANN index through `VECTOR_SEARCH`.
- **LLM**: any OpenAI-compatible API. It's told to answer only from the retrieved passages and to say so when the answer isn't there.
- **Database**: the schema is a SQL Database Project in [`database/`](database): the table, the full-text index and its stoplist, the three search queries as stored procedures, and two roles. `docker compose` builds it into a `.dacpac` and publishes it with SqlPackage, and CI builds it on every push.
- **Permissions**: the app connects as its own login, `rag_app`, which is a member of two roles: `rag_search` (EXECUTE on the three search procedures) and `rag_ingest` (SELECT, INSERT, DELETE and ALTER on `dbo.chunks`, so ingest can replace the rows and rebuild the vector index). It can't create or drop objects. `sa` is only used to deploy the schema and, in `evaluate.py`, to read Query Store.

## Getting started

You need Python 3.11+, [Docker Desktop](https://www.docker.com/products/docker-desktop/), [Ollama](https://ollama.com), the [ODBC Driver 18 for SQL Server](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server), and an API key for an LLM (or a local model in Ollama).

```bash
cp .env.example .env              # add your LLM key and pick two SQL passwords
docker compose up -d              # SQL Server 2025 with Full-Text Search
docker compose wait schema        # deploys the schema from database/ (exit code 0 when done)
ollama pull bge-m3                # the embedding model

python -m venv .venv
.venv\Scripts\activate            # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
streamlit run app.py
```

You don't need .NET locally; the schema is built inside Docker. Open http://localhost:8501, click **Ingest documents**, and ask something. To use your own documents, put them in `docs/` (pdf, txt, md or docx) and ingest again. To use another LLM provider, set `LLM_BASE_URL`, `LLM_API_KEY` and `LLM_MODEL` in `.env`; [`.env.example`](.env.example) has examples.

## Results

[`questions.csv`](questions.csv) has 120 test questions with known answers, and `python evaluate.py` scores both search modes on them. The held-out questions were written after all settings were frozen, so nothing was tuned to fit them.

| | Hybrid search (default) | Vector search |
|---|---|---|
| Correct answer, held-out questions | **95%** (18 of 19) | 89% (17 of 19) |
| Correct answer, tuning questions | 92% | 99% |
| Off-topic questions refused, held-out | 4 of 5 | 5 of 5 |

I wrote the questions myself with the documents in front of me, so treat these numbers as a sanity check rather than a benchmark. The LLM isn't deterministic, so a question or two changes between runs; the earlier run of the same retrieval code refused 5 of 5 held-out off-topic questions with hybrid search and got 94% on the tuning questions.

`evaluate.py` also compares the DiskANN index with exact search, and reads the cost of each search procedure from Query Store:

| | Avg. duration | Avg. logical reads |
|---|---|---|
| `search_exact` (every chunk) | 1.1 ms | 103 |
| `search_ann` (DiskANN) | 2.8 ms | 561 |
| `search_hybrid` | 6.9 ms | 511 |

DiskANN returned 596 of the 600 chunks (99%) that exact search returned. With only 101 chunks it's slower than scanning them all, so here the index is about learning how it works, not about speed.

## What I learned

- **The embedding model mattered most.** Switching from the English-focused `nomic-embed-text` to the multilingual `bge-m3` took correct answers from 81% to 97%.
- **Hybrid search needed an Icelandic stopword list.** SQL Server doesn't have one, so common words like "á" and "að" matched almost every chunk. A custom stoplist, plus fusing only the top 20 results from each ranking, took it from 84% to 95%.
- **Tuning numbers were too optimistic.** Vector search looked best on the tuning questions but dropped on held-out ones, while hybrid search held up. That's why hybrid is the default.
- **Plausible off-topic questions are the hard part.** They sit as close to the text as real ones, so a distance cut-off can't catch them. A stricter prompt ("related information about a different topic is not an answer") took refusals from 69% to 92% on the tuning questions.
- **Follow-up questions need rewriting** into standalone questions before searching. That took them from 75% to 100%.
- **Some ideas didn't help**, like sentence-aware chunking, so I left them out.

## SQL Server 2025 notes

The approximate search, from [`search_ann`](database/Procedures/search_ann.sql):

```sql
SELECT c.id, c.source, c.content, v.distance AS score
FROM VECTOR_SEARCH(TABLE = dbo.chunks AS c, COLUMN = embedding, SIMILAR_TO = @query_vector,
                   METRIC = 'cosine', TOP_N = @top_k) AS v
ORDER BY v.distance;
```

- `SIMILAR_TO` only accepts a variable, and table columns are read through the table alias.
- A DiskANN index needs at least 100 rows (the demo gives 101 chunks), and it makes the table read-only. So the index isn't part of the SQL project: ingest drops it, replaces the rows and builds it again. Below 100 chunks the app uses exact `VECTOR_DISTANCE` search.
- A stored procedure that uses `VECTOR_SEARCH` can't be created until the vector index exists, which is a problem when the schema is deployed before there's any data. `search_ann` runs the query as dynamic SQL instead, `WITH EXECUTE AS OWNER` so a login that's only in `rag_search` doesn't need access to the table.
- A SQL project can declare a full-text stoplist but not the words in it, so a post-deployment script adds the Icelandic stopwords.
- Microsoft Learn now shows `SELECT TOP (n) WITH APPROXIMATE` instead of `TOP_N`, but that syntax isn't available in SQL Server 2025 yet (it's Azure SQL only), so this project uses `TOP_N`.
- [`sql/sql_server_2025_examples.sql`](sql/sql_server_2025_examples.sql) has standalone examples of other new features: `AI_GENERATE_EMBEDDINGS`, calling a model with `sp_invoke_external_rest_endpoint`, JSON functions, regular expressions, fuzzy matching, graph tables, and ways to keep embeddings in sync with changing data.

## Project layout

```
app.py              Streamlit UI
rag/                config, database, embeddings, search and chat
evaluate.py         evaluation script
questions.csv       test questions (tuning and holdout)
tests/              unit tests (everything mocked) and integration tests (real SQL Server)
database/           SQL Database Project: table, full-text index, search procedures, roles
sql/                standalone T-SQL examples
docs/               demo documents
```

## Tests

```bash
pytest                                # unit tests, with SQL Server, Ollama and the LLM mocked
pytest -m integration                 # against the real database: deploy, ingest, search, permissions
docker compose run --rm schema drift  # fails if the database has drifted from the SQL project
```

The integration tests use generated embeddings, so they don't need Ollama, but they replace the chunks, so ingest the documents again afterwards. CI runs all three on every push, together with a build of the SQL project and its code analysis.

## Limitations

- The test set is small and self-written. Questions from real users would be a much better test.
- Plausible but unanswerable questions still sometimes get answered from related text (one in each set with hybrid search in the last run), so the prompt isn't perfect.
- 101 chunks is just enough for DiskANN, and at that size it's slower than exact search (see above). You'd need thousands of chunks to see it pay off, which I haven't measured.

## License

[MIT](LICENSE)
