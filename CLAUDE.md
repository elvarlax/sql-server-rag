# RAG on SQL Server 2025 — Claude Code Instructions

## Project Overview
A portfolio side project (public on GitHub): a RAG chat app that uses SQL Server 2025 as the vector store. Keep it simple, clean and professional. Public-facing text (README, UI, comments) should read as a hands-on exploration of the technology, not a production product: plain, first-person, human, and credible, with no marketing tone and no overclaiming. Don't mention exams or certifications.

## Stack
- **LLM**: any OpenAI-compatible API (OpenAI, Azure OpenAI, Ollama, Mistral, ...) via one `OpenAI` client, configured with `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_MODEL`. Default `gpt-6-luna` — cheapest model with good Icelandic
- **Embeddings**: `bge-m3` via Ollama (local, multilingual, 1024 dims) — replaced `nomic-embed-text` after evaluation (81% → 97%)
- **Vector store**: SQL Server 2025 — `VECTOR(1024)` + DiskANN index (needs 100+ chunks; the 14 demo docs give 101)
- **Search**: hybrid is the default (won on both held-out sets) — Full-Text Search (`FREETEXTTABLE`, custom Icelandic stoplist) + Reciprocal Rank Fusion over the top 20 of each ranking; vector-only mode is also available
- **Ingestion**: LlamaIndex `SimpleDirectoryReader`
- **UI**: Streamlit (theme in `.streamlit/config.toml`)

## Pipeline
```
docs/ → 500-char chunks → bge-m3 → chunks.embedding VECTOR(1024)
question → (follow-up? LLM rewrites it as a standalone question) → embed → VECTOR_SEARCH (ANN) / VECTOR_DISTANCE (ENN) / hybrid RRF
         → nothing within MAX_DISTANCE? refuse without the LLM → numbered context → LLM (prompt refuses related-but-off-topic) → answer with [n] citations
```

## Key Files
- `app.py` — Streamlit UI (sidebar, example questions, chat, sources) and logging setup
- `rag/config.py` — constants and environment variables
- `rag/db.py` — DB setup; `ingest()` rebuilds the table, full-text index (with stoplist) and DiskANN index
- `rag/embeddings.py` — Ollama `embed()` (cached, for questions) and `embed_many()` (batched, for ingest)
- `rag/retrieval.py` — vector search (ANN if `sys.vector_indexes` has the index, else ENN), hybrid RRF; `retrieve()` refuses when even the closest chunk is beyond `MAX_DISTANCE`, and filters vector results per chunk
- `rag/chat.py` — rewrite follow-ups (`standalone_question`) → retrieve → prompt → LLM; returns an `Answer` NamedTuple (text, rows, mode, search_query)
- `sql/sql_server_2025_examples.sql` — standalone T-SQL examples, checked against Microsoft Learn
- `docker-compose.yml` + `Dockerfile.sqlserver` — SQL Server 2025 with Full-Text Search
- `docs/` — 14 demo PDFs for a fictional company; only `Demo_*.pdf` are committed (see .gitignore)
- `assets/screenshot.png` — README screenshot (taken with Playwright, outside the project venv)
- `questions.csv` — 120 evaluation questions (96 tuning, 24 holdout) in two sets (`set` column: `tuning` / `holdout`): question, source (`|` alternatives), expected answer text (`|` alternatives), previous question for follow-ups; the UI shows a few as examples
- `evaluate.py` — scores retrieval and answers for both search modes, per set (needs live services)
- **Never tune settings on the `holdout` set** — it measures how results carry over to new questions. Add new questions for tuning to the `tuning` set; if holdout results drive a change, write a fresh holdout set to confirm it
- `tests/test_rag.py` — unit tests, everything external is mocked

## SQL Server 2025 gotchas
- `VECTOR_SEARCH`: `SIMILAR_TO` must be a variable or column (declare `@q` first), and table columns come from the TABLE alias, not the function alias
- A DiskANN index needs 100+ rows and makes the table read-only — `ingest()` drops and recreates the whole table
- Fuzzy matching functions don't support `SQL_*` collations (the Docker default) — use `COLLATE`
- No Icelandic stoplist or word breaker — the full-text index and `FREETEXTTABLE` queries both use `LANGUAGE 0`, with a custom stoplist; `DROP FULLTEXT STOPLIST IF EXISTS` isn't supported (use `IF EXISTS (...) DROP ...;`) and stoplist statements need a `;`
- PDF text from justified paragraphs has runs of spaces — `split()` collapses them

## Coding Rules
- Keep it as simple as possible — no features beyond the RAG pipeline and its UI
- Measure retrieval/prompt changes with `python evaluate.py` before keeping them (e.g. a hybrid distance cut-off and sentence-aware chunking both measured worse, so neither is used); don't add tuning parameters that only win a single question
- Don't swallow errors to fall back silently — check state explicitly (e.g. `has_vector_index`, `has_fulltext_index`) so real failures surface
- No unnecessary abstractions
- English UI and English comments
- Secrets in `.env`, never hardcoded
- `EMBED_DIMS` must match `EMBED_MODEL`; `ingest()` recreates the table, so changing model just means re-ingesting
- `MAX_DISTANCE` (0.52) is calibrated for bge-m3 on the tuning set — recalibrate if the embedding model changes. Plausible off-topic questions sit as close as real ones, so refusing those is the prompt's job, not the cut-off's
- Search modes are `"hybrid"` (default) and `"vector"` (ANN with DiskANN, or exact ENN without the index); the demo corpus is just over 100 chunks, so `evaluate.py` prints whether DiskANN was used
- Vectors are sent to SQL Server as JSON array strings
- The `rag` package must not import streamlit
- Only SQL Server runs in Docker; the app runs locally so it can reach Ollama

## Running
```bash
docker compose up -d      # SQL Server
streamlit run app.py      # App on http://localhost:8501
pytest                    # Unit tests
python evaluate.py        # Quality evaluation (needs SQL Server, Ollama, LLM)
ruff check .              # Lint
```
