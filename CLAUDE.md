# RAG on SQL Server 2025 — Claude Code Instructions

## Project Overview
A portfolio side project (public on GitHub): a RAG chat app that uses SQL Server 2025 as the vector store. Keep it simple, clean and professional. Public-facing text (README, UI, comments) should read as a hands-on exploration of the technology, not a production product: plain, first-person, human, and credible, with no marketing tone and no overclaiming.

## Stack
- **LLM**: any OpenAI-compatible API (OpenAI, Azure OpenAI, Ollama, Mistral, ...) via one `OpenAI` client, configured with `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_MODEL`. Default `gpt-6-luna` — cheapest model with good Icelandic
- **Embeddings**: `bge-m3` via Ollama (local, multilingual, 1024 dims) — replaced `nomic-embed-text` after evaluation (81% → 97%)
- **Vector store**: SQL Server 2025 — `VECTOR(1024)` + DiskANN index (needs 100+ chunks; the 14 demo docs give 101)
- **Schema**: SDK-style SQL Database Project (`database/`, Microsoft.Build.Sql) — table, full-text index + stoplist, search stored procedures, roles; `docker compose` builds the .dacpac and publishes it with SqlPackage
- **Security**: the app logs in as `rag_app` (roles `rag_search`: EXECUTE on the search procedures; `rag_ingest`: SELECT/INSERT/DELETE/ALTER on `dbo.chunks`); `sa` only deploys the schema and reads Query Store in `evaluate.py`
- **Search**: hybrid is the default (won on both held-out sets) — Full-Text Search (`FREETEXTTABLE`, custom Icelandic stoplist) + Reciprocal Rank Fusion over the top 20 of each ranking; vector-only mode is also available
- **Ingestion**: LlamaIndex `SimpleDirectoryReader`
- **UI**: Streamlit (theme in `.streamlit/config.toml`)

## Pipeline
```
docs/ → 500-char chunks (50 overlap) → bge-m3 → chunks.embedding VECTOR(1024)
question → (follow-up? LLM rewrites it as a standalone question) → embed → EXEC search_ann (VECTOR_SEARCH) / search_exact (VECTOR_DISTANCE) / search_hybrid (RRF)
         → nothing within MAX_DISTANCE? refuse without the LLM → numbered context → LLM (prompt refuses related-but-off-topic) → answer with [n] citations
```

## Key Files
- `app.py` — Streamlit UI (sidebar, example questions, chat, sources) and logging setup
- `rag/config.py` — constants and environment variables
- `rag/db.py` — `get_conn()` (as `rag_app` by default, 5 s login timeout); `table_stats()` raises on database errors and `app.py` shows them in the main area; `ingest()` drops the DiskANN index, replaces the rows and recreates the index (the table itself comes from `database/`)
- `rag/embeddings.py` — Ollama `embed()` (cached, for questions) and `embed_many()` (batched, for ingest)
- `rag/retrieval.py` — calls the search procedures: `search_ann` if `sys.vector_indexes` has the index, else `search_exact`; `search_hybrid`; `retrieve()` refuses when even the closest chunk is beyond `MAX_DISTANCE`, and filters vector results per chunk
- `rag/chat.py` — rewrite follow-ups (`standalone_question`) → retrieve → prompt → LLM; returns an `Answer` NamedTuple (text, rows, mode, search_query)
- `sql/walkthrough.sql` — hands-on T-SQL for SSMS/VS Code, run one section at a time. Part 1 (sections 1–7) uses the app's database: stored data, ANN vs exact, full-text/stoplist, hybrid, `EXECUTE AS LOGIN = 'rag_app'`, Query Store. Part 2 (8–15) runs in a scratch database, `SqlServerRagWalkthrough`, so the app's schema and the drift check stay clean, and reads `SqlServerRag.dbo.chunks`: vector functions, json type + JSON index + JSON functions, regex, fuzzy matching, temporal/ledger/graph tables, TRY/CATCH/THROW, Change Tracking; section 15 (external model, `AI_GENERATE_EMBEDDINGS`, embedding trigger, `sp_invoke_external_rest_endpoint`) is commented out because it needs an HTTPS model endpoint. Every runnable section must stay re-runnable; run the whole file after changing the procedures, permissions or the walkthrough itself
- `database/` — SQL Database Project `SqlServerRag.sqlproj` (database `SqlServerRag`, named after the repo): `Tables/`, `FullText/`, `Procedures/` (search_ann, search_exact, search_hybrid; runnable examples are in `sql/walkthrough.sql`), `Security/` (roles), `Scripts/` (pre-deploy: PREVIEW_FEATURES; post-deploy: stopwords and the `rag_app` login); Query Store on (capture mode ALL) via project properties; `Dockerfile` builds and publishes it
- `docker-compose.yml` + `Dockerfile.sqlserver` — SQL Server 2025 with Full-Text Search, plus the one-off `schema` service that deploys `database/`
- `docs/` — 14 demo PDFs for a fictional company, generated with an LLM and then reviewed (the README says so); only `Demo_*.pdf` are committed (see .gitignore)
- `assets/demo.gif` — README demo: example question → follow-up → its sources (rewritten question) → off-topic question refused. Recorded with Playwright outside the project venv, converted with ffmpeg; re-record when the UI changes
- `questions.csv` — 120 evaluation questions (96 tuning, 24 holdout) in two sets (`set` column: `tuning` / `holdout`): question, source (`|` alternatives), expected answer text (`|` alternatives), previous question for follow-ups; the UI shows a few as examples
- `evaluate.py` — scores retrieval and answers for both search modes, per set; then ANN recall vs exact search and a Query Store cost report per procedure (clears Query Store first, connects as `sa` for that) — needs live services
- **Never tune settings on the `holdout` set** — it measures how results carry over to new questions. Add new questions for tuning to the `tuning` set; if holdout results drive a change, write a fresh holdout set to confirm it
- `tests/test_rag.py` — 22 unit tests, everything external is mocked
- `tests/test_database.py` — integration tests (`pytest -m integration`, excluded by default): real SQL Server with the schema deployed, generated embeddings (no Ollama); they replace the chunks, so re-ingest afterwards
- `database/deploy.sh` — entrypoint of the schema container: `publish` (default) or `drift` (DeployReport; fails on any difference)
- `.github/workflows/ci.yml` — on `ubuntu-24.04` (pinned: `ubuntu-latest` moves to 26, which can break the ODBC driver install), on push and PRs: `ruff` + unit tests; SQL project build with code analysis, uploaded as the `SqlServerRag-dacpac` artifact; then an integration job that starts SQL Server with docker compose, deploys the schema, runs `pytest -m integration` and the drift check (badge in the README)
- `README.md` — its results table comes from `python evaluate.py`; update it (and the "What I learned" numbers) whenever a change moves them
- `LICENSE` — MIT
- `requirements.txt` — exact versions (`==`); `.github/dependabot.yml` proposes weekly updates for pip and GitHub Actions, and CI tests them

## SQL Server 2025 gotchas
- `VECTOR_SEARCH`: `SIMILAR_TO` must be a variable or column (declare `@q` first), and table columns come from the TABLE alias, not the function alias
- A DiskANN index needs 100+ rows and makes the table read-only — `ingest()` drops the index, replaces the rows and recreates it; it's not in the SQL project, and publishing uses `DropIndexesNotInSource=False` so it survives
- A procedure using `VECTOR_SEARCH` can't be created before the vector index exists (Msg 42227) — `search_ann` runs it as dynamic SQL, `WITH EXECUTE AS OWNER` so a caller that's only in `rag_search` needs no table access
- SQL Server 2025 (CU9) uses `VECTOR_SEARCH(..., TOP_N = n)`; the newer `SELECT TOP (n) WITH APPROXIMATE` syntax on Microsoft Learn is Azure SQL only for now (syntax error here)
- pyodbc sends long strings as `ntext`, which can't convert to `VECTOR` — declare `@q VECTOR(1024)` from the JSON string first, then `EXEC proc @query_vector = @q`
- DacFx models a full-text stoplist but not its words (`ALTER FULLTEXT STOPLIST ... ADD` fails to build) — the post-deploy script adds missing words and repopulates the index
- `docker compose up --wait` doesn't wait for the one-off `schema` service to finish — use `docker compose wait schema`
- ODBC Driver 18 retries a failed connection for ~15 s, even to a closed local port — `get_conn()` sets `timeout=5` and `ConnectRetryCount=0` (the timeout alone isn't enough)
- In SSMS, `localhost` can reach a local Windows SQL Server instance over shared memory instead of the container — use `tcp:localhost,1433`
- Fuzzy matching functions don't support `SQL_*` collations (the Docker default) — use `COLLATE`
- An UPDATE on an append-only ledger table fails at compile time (37359), which TRY/CATCH can't catch in the same batch — run it through `sp_executesql`
- `VECTORPROPERTY` returns `sql_variant`, which pyodbc can't read — `CAST` it
- Ledger tables can't really be dropped (they're kept as dropped ledger tables), so the walkthrough creates `question_log` only once
- No Icelandic stoplist or word breaker — the full-text index and `FREETEXTTABLE` queries both use `LANGUAGE 0`, with a custom stoplist; `DROP FULLTEXT STOPLIST IF EXISTS` isn't supported (use `IF EXISTS (...) DROP ...;`) and stoplist statements need a `;`
- PDF text from justified paragraphs has runs of spaces — `split()` collapses them

## Coding Rules
- Keep it as simple as possible — no features beyond the RAG pipeline and its UI. Database practices around it (SQL project, stored procedures, least-privilege login, Query Store) are in scope
- Measure retrieval/prompt changes with `python evaluate.py` before keeping them (e.g. a hybrid distance cut-off and sentence-aware chunking both measured worse, so neither is used); don't add tuning parameters that only win a single question
- Don't swallow errors to fall back silently — check state explicitly (e.g. `has_vector_index`, `has_fulltext_index`) so real failures surface
- No unnecessary abstractions
- English UI and English comments
- Secrets in `.env`, never hardcoded
- `EMBED_DIMS` must match `EMBED_MODEL` and `VECTOR(1024)` in `database/` (table and procedures); changing model means editing those, redeploying and re-ingesting
- `MAX_DISTANCE` (0.52) is calibrated for bge-m3 on the tuning set — recalibrate if the embedding model changes. Plausible off-topic questions sit as close as real ones, so refusing those is the prompt's job, not the cut-off's
- Search modes are `"hybrid"` (default) and `"vector"` (ANN with DiskANN, or exact ENN without the index); the demo corpus is just over 100 chunks, so `evaluate.py` prints whether DiskANN was used
- Vectors are sent to SQL Server as JSON array strings
- The `rag` package must not import streamlit
- Only SQL Server (and the one-off schema deploy) runs in Docker; the app runs locally so it can reach Ollama
- Schema changes go in `database/`, never in Python; the app's login can't create or drop objects
- Secrets: `SQL_PASSWORD` (sa) is only for docker compose and evaluate.py's Query Store report; the app uses `SQL_APP_PASSWORD`

## Running
```bash
docker compose up -d      # SQL Server + schema deploy
docker compose wait schema  # wait for the deploy (exit 0 = done)
dotnet build database -c Release  # build/validate the SQL project locally (optional)
streamlit run app.py      # App on http://localhost:8501
pytest                    # Unit tests
pytest -m integration     # Integration tests (needs the database; replaces the chunks)
docker compose run --rm schema drift  # Schema drift check
python evaluate.py        # Quality evaluation (needs SQL Server, Ollama, LLM)
ruff check .              # Lint
```
