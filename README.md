# RAG on SQL Server 2025

A small chat app that answers questions about a set of documents, using SQL Server 2025 as the vector database. It's a side project I built to try out the new vector features in SQL Server and to find out, by measuring, what actually makes the answers good.

![Asking how many days you can work from home. The answer cites the remote work policy and the sources are shown below it.](assets/screenshot.png)

You ask a question, the app finds the most relevant passages in SQL Server, and an LLM answers using only those passages. Every answer cites its sources, and you can open them to check.

The demo documents are 14 short policy documents (in Icelandic) for a made-up accounting firm. You can ask in Icelandic or English.

## Results

I wrote a set of test questions with known answers and a script that scores the app on them. The most useful number is the held-out set: questions I wrote after all the settings were frozen, so nothing was tuned to fit them.

| | Hybrid search (default) | Vector search |
|---|---|---|
| Correct answer, held-out questions | **95%** (18 of 19) | 89% (17 of 19) |
| Correct answer, tuning questions | 94% | 99% |
| Off-topic questions refused, held-out | 5 of 5 | 5 of 5 |
| Follow-up questions, held-out | 3 of 3 | 3 of 3 |

Each question costs about $0.0001 in LLM fees, and a response takes about 1.7 seconds.

The numbers come from a small set of questions that I wrote myself, the same person who wrote the documents. Treat them as a sanity check, not a benchmark.

## How it works

```
ingest:  docs/ → chunks of 500 characters → bge-m3 embeddings → SQL Server (VECTOR(1024) column)

ask:     question → rewrite if it's a follow-up → embed → search SQL Server → top 5 chunks → LLM → answer with [n] citations
```

- **Embeddings** are made locally with `bge-m3` in Ollama. It's multilingual, which matters a lot for Icelandic (more on that below).
- **Search** happens in SQL Server, in one of two modes:
  - **vector search** uses a DiskANN index through `VECTOR_SEARCH`, or exact `VECTOR_DISTANCE` when there's no index;
  - **hybrid search** combines vector ranking with full-text ranking (`FREETEXTTABLE`) using Reciprocal Rank Fusion. It's the default.
- **Follow-up questions** like "and the largest package?" are rewritten by the LLM into a standalone question before searching, because on their own they can't be searched for.
- **The LLM** gets the top 5 chunks, numbered, and is told to answer only from them, cite them, and say so if the answer isn't there. Any OpenAI-compatible API works; the default is `gpt-6-luna`.

## Getting started

You need Python 3.11+, [Docker Desktop](https://www.docker.com/products/docker-desktop/), [Ollama](https://ollama.com) and an API key for an LLM (or a local model in Ollama).

```bash
cp .env.example .env              # add your LLM key and pick a SQL password
docker compose up -d              # SQL Server 2025 with Full-Text Search
ollama pull bge-m3                # the embedding model

python -m venv .venv
.venv\Scripts\activate            # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
streamlit run app.py
```

Open http://localhost:8501, click **Ingest documents**, and ask something. To use your own documents, put them in `docs/` (pdf, txt, md or docx) and ingest again.

To use another LLM provider, set `LLM_BASE_URL`, `LLM_API_KEY` and `LLM_MODEL` in `.env`. That covers Azure OpenAI, Ollama, Mistral, Groq, Gemini and others; [`.env.example`](.env.example) has examples.

## What I learned

These are the changes that moved the numbers, roughly in the order I made them. Each one was measured with the evaluation script before I kept it.

**The embedding model mattered most.** I started with `nomic-embed-text`, which is mostly trained on English. Switching to the multilingual `bge-m3` took correct answers from 81% to 97%. English questions about the Icelandic documents went from 0 of 3 to 3 of 3.

**Hybrid search needed tuning before it helped.** When I went from 3 documents to 14, hybrid search dropped to 84%. Common Icelandic words like "á", "að" and "hvað" matched almost every chunk, and SQL Server has no Icelandic stopword list. Two changes fixed it:

| Hybrid search | Right passage found |
|---|---|
| As first built | 84% |
| With an Icelandic stopword list | 91% |
| Fusing only the top 20 results from each ranking | 95% |

**The tuning numbers were too optimistic.** On the questions I tuned with, vector search looked best at 98%. On my first set of held-out questions it fell to 85%, while hybrid search held at 95%. The vector cut-off, which drops chunks that are too far from the question, had been fitted to the tuning questions. That's why hybrid search is the default now.

**Plausible questions that the documents don't cover were the hardest.** Questions like "What does it cost to rent a meeting room?" sound like something the documents would answer. The LLM would answer them from loosely related passages instead of saying it didn't know. Measuring the distances showed these questions are as close to the text as real ones, so a distance cut-off can't catch them. A stricter prompt did ("related information about a different topic is not an answer"). Refusals went from 69% to 92% on the tuning questions, and to 5 of 5 on new held-out questions, without losing correct answers.

**Follow-up questions needed rewriting.** Searching for "What about the largest package?" finds nothing useful. Rewriting it first took follow-up questions from 75% to 100%.

**Some ideas didn't help, so I left them out:**
- Sentence-aware chunking (LlamaIndex `SentenceSplitter`) and adding the document title to each chunk both ranked the right passage first less often than plain 500-character chunks (85%).
- Giving full-text search a lower weight in hybrid search won one more question. I didn't keep it, because one extra setting that wins a single question is just fitting to the test.
- A cheaper LLM, `gpt-5-nano`, turned out to cost more in practice than `gpt-6-luna`, because it spends around 760 reasoning tokens per answer.

| LLM | Cost per 1,000 questions | Icelandic |
|---|---|---|
| `gpt-5-nano` | ~$0.35 | Good, but slow (3–8 s) |
| `gpt-4.1-nano` | ~$0.11 | Noticeably clumsier |
| `gpt-6-luna` (default) | ~$0.11 | Accurate, cites correctly |
| `gpt-6.1-sol` | ~$2.23 | Best, but 20× the price |

## Evaluation

`python evaluate.py` runs every question in [`questions.csv`](questions.csv) through both search modes and reports the two sets separately:

- **tuning** (96 questions): used while choosing models and settings, so its numbers flatter the app a bit;
- **holdout** (24 questions): written after the settings were frozen and never used to change anything.

Each row says which document holds the answer and what a correct answer has to contain. For follow-ups it also has the previous question, which gets asked first so there's a real conversation. Off-topic rows have no source and should be refused. Icelandic number words are normalised ("tveimur vikum" counts as "2 vik..."), so inflections don't count as wrong answers.

## Search in SQL

Vector search with the DiskANN index looks like this. Two things tripped me up: `SIMILAR_TO` only accepts a variable, and table columns have to be read through the table alias, not the function alias.

```sql
DECLARE @q VECTOR(1024) = CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR(1024));

SELECT c.source, c.content, v.distance
FROM VECTOR_SEARCH(TABLE = chunks AS c, COLUMN = embedding, SIMILAR_TO = @q,
                   METRIC = 'cosine', TOP_N = 5) AS v
ORDER BY v.distance;
```

SQL Server needs at least 100 rows before it will build a DiskANN index. The demo documents give 101 chunks, and the app falls back to exact search below that. The hybrid query, the stopword list and the ingest code are in [`rag/retrieval.py`](rag/retrieval.py) and [`rag/db.py`](rag/db.py).

[`sql/sql_server_2025_examples.sql`](sql/sql_server_2025_examples.sql) has standalone examples of other SQL Server 2025 features I tried along the way: `AI_GENERATE_EMBEDDINGS` with external models, JSON functions, regular expressions, fuzzy matching, graph tables, and ways to keep embeddings in sync with changing data.

## Project layout

```
app.py              Streamlit UI
rag/config.py       settings
rag/db.py           database setup and ingestion
rag/embeddings.py   embeddings via Ollama
rag/retrieval.py    vector and hybrid search
rag/chat.py         follow-up rewriting, prompt and LLM call
evaluate.py         evaluation script
questions.csv       test questions (tuning and holdout)
tests/              unit tests
sql/                standalone T-SQL examples
docs/               demo documents
```

## Tests

```bash
pytest          # 22 unit tests, with SQL Server, Ollama and the LLM mocked
ruff check .
```

The tests cover chunking, when ANN or exact search is used, the cut-off and the hybrid relevance check, follow-up rewriting, and the answer matching used by the evaluation.

## Limitations

- The test questions are few, and I wrote them myself after writing the documents. Questions from real users would be a much better test.
- 101 chunks is just enough for DiskANN. Seeing a real speed difference between ANN and exact search would take thousands.
- One plausible but unanswerable question in the tuning set still gets answered from related text, so the stricter prompt isn't perfect.
