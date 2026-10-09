import csv
import logging
from urllib.parse import urlparse

import streamlit as st

from rag.chat import Answer, chat
from rag.config import (
    DISKANN_MIN_ROWS,
    DOCS_PATH,
    EMBED_MODEL,
    LLM_BASE_URL,
    LLM_MODEL,
    LLM_READY,
    QUESTIONS_PATH,
    SQL_APP_PASSWORD,
)
from rag.db import ingest, table_stats
from rag.retrieval import SEARCH_MODES

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s")

st.set_page_config(page_title="RAG on SQL Server 2025", page_icon=":material/manage_search:")

if not (LLM_READY and SQL_APP_PASSWORD):
    st.error("Set SQL_APP_PASSWORD and an LLM (LLM_API_KEY, plus LLM_BASE_URL for providers other than OpenAI) in .env")
    st.stop()

if "messages" not in st.session_state:
    st.session_state.messages = []

AVATARS = {"user": ":material/person:", "assistant": ":material/auto_awesome:"}


@st.cache_data(ttl=30)
def cached_table_stats() -> tuple[int, bool]:
    # Cached so widget clicks and chat turns don't each open a SQL Server connection
    return table_stats()


@st.cache_data
def example_questions() -> list[str]:
    """A few example questions: the first for each document in questions.csv, skipping follow-ups."""
    first_per_source = {}
    with QUESTIONS_PATH.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["set"] == "tuning" and row["source"] and not row["previous"]:
                first_per_source.setdefault(row["source"], row["question"])
    return list(first_per_source.values())[:4]


def show_sources(answer: Answer, question: str) -> None:
    if not answer.rows:
        return
    score_label = "cosine distance (lower is better)" if answer.mode == "vector" else "RRF score (higher is better)"
    with st.expander(f"Sources · {len(answer.rows)} chunks · {SEARCH_MODES[answer.mode]} search"):
        if answer.search_query != question:
            st.caption(f":material/edit: Follow-up rewritten for search: *{answer.search_query}*")
        for i, r in enumerate(answer.rows, 1):
            with st.container(border=True):
                st.markdown(f"**[{i}]** {r.source}")
                st.caption(f"{score_label}: {r.score:.4f}")
                st.text(r.content)


# In the main area, so the error is visible even when the sidebar is collapsed
try:
    n_chunks, has_diskann = cached_table_stats()
except Exception as e:
    st.error(f"Can't reach the database. Is SQL Server running, with the schema deployed? {e}")
    st.stop()


# ── Sidebar ───────────────────────────────────────────────────────────────────

with st.sidebar:
    st.markdown("### :material/manage_search: RAG on SQL Server 2025")
    st.caption("Vector search, hybrid search and grounded answers")
    st.divider()

    st.subheader("Knowledge base")

    files =sorted(f.name for f in DOCS_PATH.glob("*") if f.is_file() and not f.name.startswith("."))

    col1, col2 = st.columns(2)
    col1.metric("Documents", len(files))
    col2.metric("Chunks", n_chunks)

    with st.expander("Files in ./docs"):
        for name in files:
            st.markdown(f":material/description: {name}")

    if st.button("Ingest documents", icon=":material/upload_file:", type="primary", use_container_width=True):
        with st.spinner("Chunking, embedding and storing in SQL Server…"):
            try:
                ingest(DOCS_PATH)
                cached_table_stats.clear()
                st.rerun()
            except Exception as e:
                st.error(f"Ingest failed: {e}")

    st.subheader("Search")
    search_mode = st.segmented_control(
        "Search mode",
        options=list(SEARCH_MODES),
        format_func=SEARCH_MODES.get,
        default="hybrid",
        required=True,
        help="Vector: semantic similarity (VECTOR_SEARCH / VECTOR_DISTANCE).  \n"
             "Hybrid: vector + full-text ranking, fused with Reciprocal Rank Fusion.",
    )
    show_chunks = st.toggle("Show sources", value=True)

    st.subheader("Pipeline")
    index = "DiskANN (approximate)" if has_diskann else f"Exact ENN — DiskANN needs {DISKANN_MIN_ROWS}+ chunks"
    st.caption(
        f"**Embeddings** · {EMBED_MODEL} (Ollama)  \n"
        f"**Vector store** · SQL Server 2025  \n"
        f"**Vector index** · {index}  \n"
        f"**LLM** · {LLM_MODEL} ({urlparse(LLM_BASE_URL).hostname if LLM_BASE_URL else 'OpenAI'})"
    )

    if st.session_state.messages and st.button("Clear chat", icon=":material/delete:", use_container_width=True):
        st.session_state.messages = []
        st.rerun()

# ── Chat ──────────────────────────────────────────────────────────────────────

st.badge("SQL Server 2025 · Vector search · RAG", icon=":material/database:", color="blue")
st.title("Ask your documents")
st.caption("Answers come only from the indexed documents, with numbered citations to the passages used.")

if n_chunks == 0:
    st.info("No documents indexed yet. Add files to `./docs` and click **Ingest documents** "
            "(Ollama must be running).", icon=":material/info:")
    st.stop()

for msg in st.session_state.messages:
    with st.chat_message(msg["role"], avatar=AVATARS[msg["role"]]):
        st.markdown(msg["content"])
        if show_chunks and "answer" in msg:
            show_sources(msg["answer"], msg["question"])


def _pick_example():
    st.session_state.pending = st.session_state.example
    st.session_state.example = None


if not st.session_state.messages:
    st.pills("Try asking", example_questions(), key="example", on_change=_pick_example)

query = st.chat_input("Ask a question about the documents…") or st.session_state.pop("pending", None)

if query:
    history = [{"role": m["role"], "content": m["content"]} for m in st.session_state.messages]
    with st.chat_message("user", avatar=AVATARS["user"]):
        st.markdown(query)

    with st.chat_message("assistant", avatar=AVATARS["assistant"]):
        try:
            with st.spinner("Searching and generating…"):
                answer = chat(query, history, mode=search_mode)
        except Exception as e:
            # Don't save the question, so a failed turn isn't resent as history
            st.error(f"Something went wrong: {e}")
            st.stop()
        st.markdown(answer.text)
        if show_chunks:
            show_sources(answer, query)

    st.session_state.messages += [
        {"role": "user", "content": query},
        {"role": "assistant", "content": answer.text, "answer": answer, "question": query},
    ]
    st.rerun()  # hides the example questions once the chat has started
