"""Unit tests for the RAG pipeline. SQL Server, Ollama and the LLM are mocked, so no services are needed."""
from itertools import pairwise
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from evaluate import contains
from rag.chat import NOT_FOUND, chat, standalone_question
from rag.config import CHUNK_OVERLAP, CHUNK_SIZE, HISTORY_MESSAGES, MAX_DISTANCE
from rag.db import split
from rag.embeddings import embed, embed_many
from rag.retrieval import retrieve, vector_search


def row(source, content, score):
    return SimpleNamespace(source=source, content=content, score=score)


def llm_replying(*replies):
    """A mock LLM client that returns the given replies in order."""
    client = MagicMock()
    client.chat.completions.create.side_effect = [
        MagicMock(choices=[MagicMock(message=MagicMock(content=reply))]) for reply in replies
    ]
    return client


# ── Chunking ──────────────────────────────────────────────────────────────────

def test_chunks_overlap_so_text_at_a_boundary_is_never_lost():
    text = "".join(f"{i:04d} " for i in range(400))  # 2000 characters of unique tokens
    chunks = split(text)

    assert all(len(c) <= CHUNK_SIZE for c in chunks)
    for first, second in pairwise(chunks):
        assert first[-CHUNK_OVERLAP + 1:] in second  # the end of each chunk is repeated in the next


def test_chunking_collapses_the_extra_spaces_pdf_extraction_leaves():
    assert split("Fyrstu  3   mánuðirnir\teru reynslutími.") == ["Fyrstu 3 mánuðirnir eru reynslutími."]


def test_chunking_drops_tiny_leftover_fragments():
    text = "a" * (CHUNK_SIZE - CHUNK_OVERLAP + 10)  # the second window would hold only 10 characters
    assert split(text) == [text]


# ── Embeddings ────────────────────────────────────────────────────────────────

@patch("ollama.embed", return_value={"embeddings": [[0.1, 0.2, 0.3]]})
def test_question_embeddings_are_cached_as_json(mock_ollama):
    embed.cache_clear()
    assert embed("hello") == "[0.1, 0.2, 0.3]"
    embed("hello")
    assert mock_ollama.call_count == 1


@patch("ollama.embed", return_value={"embeddings": []})
def test_missing_embedding_model_gives_a_clear_error(_ollama):
    with pytest.raises(RuntimeError, match="ollama pull"):
        embed_many(["text"])


# ── Retrieval ─────────────────────────────────────────────────────────────────

@pytest.mark.parametrize(("has_index", "procedure"), [(True, "dbo.search_ann"), (False, "dbo.search_exact")])
@patch("rag.retrieval.embed", return_value="[0.1]")
def test_vector_search_uses_diskann_only_when_the_index_exists(_embed, has_index, procedure):
    conn = MagicMock()
    with patch("rag.retrieval.has_vector_index", return_value=has_index):
        vector_search(conn, "question")

    sql = conn.execute.call_args.args[0]
    assert f"EXEC {procedure} " in sql  # ANN with the index, exact ENN without it


@patch("rag.retrieval.get_conn")
@patch("rag.retrieval.vector_search", return_value=[row("near", "", 0.10), row("edge", "", MAX_DISTANCE), row("far", "", 0.90)])
def test_vector_results_beyond_the_distance_cutoff_are_dropped(_search, _conn):
    rows, mode = retrieve("question", mode="vector")
    assert [r.source for r in rows] == ["near", "edge"]
    assert mode == "vector"


def hybrid_rows(closest):
    """Two fused hybrid results; `closest` is the distance of the nearest chunk in the table."""
    return [SimpleNamespace(source=s, content="", score=score, closest=closest) for s, score in [("a", 0.03), ("b", 0.01)]]


@patch("rag.retrieval.get_conn")
@patch("rag.retrieval.has_fulltext_index", return_value=True)
@patch("rag.retrieval.hybrid_search", return_value=hybrid_rows(closest=0.30))
def test_hybrid_results_are_not_filtered_one_by_one(_search, _fts, _conn):
    # RRF scores are ranks, not relevance, so hybrid keeps every fused result
    rows, mode = retrieve("question", mode="hybrid")
    assert [r.source for r in rows] == ["a", "b"]
    assert mode == "hybrid"


@patch("rag.retrieval.get_conn")
@patch("rag.retrieval.has_fulltext_index", return_value=True)
@patch("rag.retrieval.hybrid_search", return_value=hybrid_rows(closest=MAX_DISTANCE + 0.1))
def test_hybrid_returns_nothing_when_no_chunk_is_close(_search, _fts, _conn):
    # Clearly unrelated questions are refused before the LLM is called
    rows, _ = retrieve("question", mode="hybrid")
    assert rows == []


@patch("rag.retrieval.get_conn")
@patch("rag.retrieval.has_fulltext_index", return_value=False)
@patch("rag.retrieval.vector_search", return_value=[row("a", "", 0.1)])
def test_hybrid_falls_back_to_vector_search_without_a_full_text_index(_search, _fts, _conn):
    rows, mode = retrieve("question", mode="hybrid")
    assert mode == "vector"  # reported, so callers can see the fallback
    assert len(rows) == 1


# ── Chat ──────────────────────────────────────────────────────────────────────

@patch("rag.chat.retrieve", return_value=([row("a.pdf", "chunk one", 0.1), row("b.pdf", "chunk two", 0.2)], "vector"))
@patch("rag.chat.client", new_callable=lambda: llm_replying("Answer [1]"))
def test_chat_sends_numbered_chunks_and_returns_answer(client, retrieve):
    answer = chat("question", [])

    system_prompt = client.chat.completions.create.call_args.kwargs["messages"][0]["content"]
    assert answer.text == "Answer [1]"
    assert "[1] (a.pdf)\nchunk one" in system_prompt
    assert "[2] (b.pdf)\nchunk two" in system_prompt
    retrieve.assert_called_once_with("question", mode="hybrid")  # no history, so no rewrite


@patch("rag.chat.retrieve", return_value=([row("a.pdf", "chunk", 0.1)], "vector"))
@patch("rag.chat.client", new_callable=lambda: llm_replying("What does the large package cost?", "150.000 kr [1]"))
def test_follow_up_is_rewritten_before_searching(client, retrieve):
    history = [{"role": "user", "content": f"old {i}"} for i in range(20)]
    answer = chat("And the large one?", history)

    retrieve.assert_called_once_with("What does the large package cost?", mode="hybrid")
    assert answer.search_query == "What does the large package cost?"
    assert answer.text == "150.000 kr [1]"
    answer_messages = client.chat.completions.create.call_args.kwargs["messages"]
    assert answer_messages[-1]["content"] == "And the large one?"  # the LLM still answers the user's own words
    assert len(answer_messages) == HISTORY_MESSAGES + 2  # system prompt + recent history + question


@patch("rag.chat.client", new_callable=lambda: llm_replying(""))
def test_rewrite_falls_back_to_the_original_question_if_the_llm_returns_nothing(_client):
    assert standalone_question("And the large one?", [{"role": "user", "content": "earlier"}]) == "And the large one?"


@patch("rag.chat.retrieve", return_value=([], "vector"))
@patch("rag.chat.client")
def test_chat_skips_the_llm_when_nothing_is_relevant(client, _retrieve):
    answer = chat("unrelated question", [])
    assert answer.text == NOT_FOUND
    assert answer.rows == []
    client.chat.completions.create.assert_not_called()


# ── Evaluation scoring ────────────────────────────────────────────────────────

@pytest.mark.parametrize(("answer", "expected"), [
    ("Sækja þarf um tveimur vikum fyrirfram", "2 vik"),  # number word in any inflection
    ("Uppsagnarfrestur er sex mánuðir", "6 mán"),
    ("Það kostar 85.000 kr", "70.000|85.000"),          # any of several accepted answers
    ("VPN er KRAFIST", "kraf"),                          # case-insensitive
])
def test_answer_matching_accepts_correct_answers(answer, expected):
    assert contains(answer, expected)


@pytest.mark.parametrize(("answer", "expected"), [
    ("Sextíu manns", "6"),      # part of a longer word isn't a number word
    ("Eins og áður", "1 "),     # "eins" also means "like", so it isn't mapped to 1
    ("Það kostar 58.000 kr", "85.000"),
])
def test_answer_matching_rejects_wrong_answers(answer, expected):
    assert not contains(answer, expected)
