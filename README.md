# RAG on SQL Server 2025

![CI](https://github.com/elvarlax/sql-server-rag/actions/workflows/ci.yml/badge.svg)

A small chat app that answers questions about a set of documents, using SQL Server 2025 as the vector database. I built it to try out the new vector features in SQL Server and to find out, by measuring, what makes the answers good.

**In short:** hybrid search (vector + full-text) answered 95% of held-out questions correctly, against 89% for vector search alone ([Results](#results)). At 20,000 vectors, a DiskANN index made search 2.5 to 5.5 times faster than exact search (it varied between runs) while finding about 99% of the same results, and half-precision vectors halved the storage ([`sql/04`](sql/04-vector-search-at-scale.sql)).

![Asking how many vacation days employees get, then a follow-up question; the sources show how the follow-up was rewritten for search. A question the documents don't answer is refused.](assets/demo.gif)

The demo documents are 14 short policy documents (in Icelandic) for a made-up company. I generated them with an LLM and reviewed them. You can ask in Icelandic or English, and every answer cites its sources.

## How it works

```
ingest:  docs/ → 500-character chunks → bge-m3 embeddings → SQL Server (VECTOR column)
ask:     question → embed → search SQL Server → top 5 chunks → LLM → answer with [n] citations
```

- **Embeddings**: `bge-m3` in Ollama, running locally. It's multilingual, which matters for Icelandic.
- **Search**: hybrid by default, combining vector search and full-text search. Vector-only search uses a DiskANN index.
- **LLM**: any OpenAI-compatible API, told to answer only from the retrieved passages.
- **Database**: the schema is a SQL Database Project in [`database/`](database), with the searches as stored procedures. The app connects with its own login that can only search and load documents, and the MCP server (below) with one that can only search and read.

## Getting started

You need Python 3.11+, [Docker](https://www.docker.com/products/docker-desktop/), [Ollama](https://ollama.com), the [ODBC Driver 18 for SQL Server](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server), and an LLM API key.

```bash
cp .env.example .env          # add your LLM key and three SQL passwords
docker compose up -d          # start SQL Server
docker compose wait schema    # wait until the database is set up
ollama pull bge-m3

python -m venv .venv
.venv\Scripts\activate        # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
streamlit run app.py
```

Open http://localhost:8501, click **Ingest documents**, and ask something.

## Try it in SQL

Connect with SSMS or VS Code to `tcp:localhost,1433` as `sa` (password in `.env`, with "Trust server certificate" checked). The database is called `SqlServerRag`. The [`sql/`](sql) folder has four scripts to run section by section. They're my way of exploring the material for Microsoft's [DP-800](https://learn.microsoft.com/credentials/certifications/resources/study-guides/dp-800) exam (Developing AI-Enabled Database Solutions), on the app's own documents:

| Script | What it covers |
|---|---|
| [`01-app-searches.sql`](sql/01-app-searches.sql) | The app's own searches: what's stored, vector search with and without the DiskANN index, full-text and hybrid search, the app login's permissions, and what each search costs in Query Store |
| [`02-design-and-develop.sql`](sql/02-design-and-develop.sql) | Constraints and sequences, the `json` type and JSON indexes, views, functions and triggers, CTEs and window functions, regular expressions, fuzzy matching, temporal, ledger, graph and in-memory tables, partitioning, columnstore, and error handling |
| [`03-secure-and-optimize.sql`](sql/03-secure-and-optimize.sql) | Row-Level Security (also in vector search), Dynamic Data Masking, column-level encryption, auditing, execution statistics, DMVs, isolation levels, Change Tracking for keeping embeddings in sync, and calling a model from T-SQL |
| [`04-vector-search-at-scale.sql`](sql/04-vector-search-at-scale.sql) | Exact search against DiskANN, and float32 against half-precision float16 vectors, on 20,000 vectors made from the real embeddings plus noise: storage, index build time, query time and recall |

Scripts 2 to 4 work on a copy of the documents in a separate scratch database, so the app's database stays as it is. Every section has been run against the database.

## Use it from Claude Code (MCP)

[`mcp_server.py`](mcp_server.py) is a small adapter that lets Claude Code (or any [MCP](https://modelcontextprotocol.io) client) use the project's search. Claude Code calls a tool, the tool calls the same Python function as the chat app, and Claude writes the answer from the passages it gets back:

```
Claude Code → mcp_server.py → retrieve() → SQL Server (as rag_mcp)
```

| Tool | Calls | Returns |
|---|---|---|
| `search_documents` | `retrieve()` | Up to 5 numbered passages with their sources (none when nothing is close enough to the question) |
| `database_status` | `table_stats()` | Number of chunks and whether vector search uses the DiskANN index |

Claude Code never writes SQL here: the tools only run the fixed searches. The server also has its own login, `rag_mcp`, which can run the search procedures and read the table but not insert, change or delete anything, and the server refuses to start as any other login. It needs SQL Server and Ollama running, but no LLM key.

Compared with the chat app, the documents can be searched from the editor, and the agent can rephrase a question and search again. Retrieval is the same `retrieve()`, so the retrieval scores from `evaluate.py` still apply; the answer scores don't, since a different model writes the answers.

The repo's [`.mcp.json`](.mcp.json) registers the server with Claude Code on Windows. On macOS or Linux, register it for yourself instead (a local registration takes precedence over the project's):

```bash
claude mcp add sql-server-rag --scope local --env SQL_LOGIN=rag_mcp -- .venv/bin/python mcp_server.py
```

Then open the project in Claude Code and ask something like *"Hvað marga orlofsdaga á ári á starfsmaður rétt á?"*.

## Results

I wrote 120 test questions with known answers. The held-out questions were written after all settings were frozen, so nothing was tuned to fit them. `python evaluate.py` runs them.

| | Hybrid search (default) | Vector search |
|---|---|---|
| Correct answer, held-out questions | **95%** | 89% |
| Correct answer, tuning questions | 93% | 99% |
| Off-topic questions refused, held-out | 5 of 5 | 5 of 5 |

I wrote the questions myself, so treat these numbers as a sanity check, not a benchmark.

## What I learned

- **The embedding model mattered most.** Switching to the multilingual `bge-m3` took correct answers from 81% to 97%.
- **Hybrid search needed an Icelandic stopword list.** SQL Server doesn't have one, and without it, words like "á" and "að" matched almost everything.
- **Tuning numbers were too optimistic.** Vector search looked best on the tuning questions but dropped on the held-out ones. That's why hybrid is the default.
- **Icelandic word forms trip up full-text search.** Without an Icelandic word breaker, "fjarvinnu" doesn't match "Fjarvinna". Matching word prefixes instead fixed every tuning miss, but found fewer right chunks on the held-out questions (13 of 16 against 15), so I didn't keep it.
- **Off-topic questions that sound plausible are the hardest.** A stricter prompt handled most of them.
- **DiskANN doesn't pay off on small data.** With 101 chunks it was slower than exact search, though it found 99% of the same results. At 20,000 vectors it was 2.5 to 5.5 times faster over four runs (6–12 ms against 32–36 ms per query), still finding about 99% (98.8–99.6%) of the exact results. Those vectors are the real embeddings plus noise, not real text, so treat that as an indication.
- **Half-precision vectors are nearly free.** `VECTOR(1024, float16)` (a preview in SQL Server 2025) halved the storage (40 MB against 79 MB for 20,000 vectors) and kept 99.8–100% of the exact results. It can't be cast from float32 directly, only through the JSON form.

## Tests

```bash
pytest                  # unit tests
pytest -m integration   # tests against the real database
```

The integration tests also check what each login may do, for example that the MCP server's login can't change or delete anything. CI runs both on every push. It also builds the SQL project into a `.dacpac`, deploys it to SQL Server in Docker, checks the database for schema drift, and saves the `.dacpac` as a downloadable artifact.

## License

[MIT](LICENSE)
