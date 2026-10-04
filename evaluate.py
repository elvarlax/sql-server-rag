"""Measure retrieval and answer quality on questions.csv, for both search modes.

For each question the CSV holds the document the answer is in and the text a correct
answer must contain (alternatives separated by |). Questions with no source are off-topic
and should be refused; follow-up questions also hold the previous question.

Results are reported separately for the two sets in the CSV:
  tuning  — questions used while choosing settings (models, cut-off, hybrid tuning)
  holdout — questions written after the settings were frozen, never used for tuning

Needs SQL Server, Ollama and the LLM, with documents ingested.
Usage: python evaluate.py
"""
import csv
import re
import time

from rag.chat import chat
from rag.config import EMBED_MODEL, LLM_MODEL, QUESTIONS_PATH
from rag.db import table_stats
from rag.embeddings import embed
from rag.retrieval import SEARCH_MODES

# Icelandic number words 1–12 in all inflections -> digits, so "tveimur vikum" matches the key "2 vik"
NUMBER_WORDS = {
    "1": "einn eina einum ein eitt einni einnar",  # not "eins", which also means "like"
    "2": "tveir tvo tveimur tveggja tvær tvö",
    "3": "þrír þrjá þremur þriggja þrjár þrjú",
    "4": "fjórir fjóra fjórum fjögurra fjórar fjögur",
    "5": "fimm", "6": "sex", "7": "sjö", "8": "átta", "9": "níu", "10": "tíu", "11": "ellefu", "12": "tólf",
}
NUMBER_PATTERNS = [(re.compile(rf"\b({'|'.join(words.split())})\b"), digit) for digit, words in NUMBER_WORDS.items()]


def normalize(text: str) -> str:
    text = text.lower()
    for pattern, digit in NUMBER_PATTERNS:
        text = pattern.sub(digit, text)
    return text


def contains(text: str, expected: str) -> bool:
    text = normalize(text)
    return any(normalize(option) in text for option in expected.split("|"))


def ratio(k: int, n: int) -> str:
    return f"{k}/{n} ({k / n:.0%})" if n else "–"


def history_for(q: dict, mode: str) -> list[dict]:
    """For a follow-up question, ask the previous question first so there's a real conversation."""
    if not q["previous"]:
        return []
    return [{"role": "user", "content": q["previous"]},
            {"role": "assistant", "content": chat(q["previous"], [], mode=mode).text}]


def evaluate(mode: str, questions: list[dict]) -> tuple[dict, list[str]]:
    """Return (metrics, failures) for one search mode."""
    embed.cache_clear()  # so both modes pay for embedding the question and response times compare fairly
    retrieved, answered, followups_answered, refused = 0, 0, 0, 0
    latencies, failures = [], []

    for q in questions:
        history = history_for(q, mode)
        start = time.perf_counter()
        result = chat(q["question"], history, mode=mode)
        latencies.append(time.perf_counter() - start)
        if result.mode != mode:
            failures.append(f"ran as {result.mode}, not {mode}: {q['question']}")

        if q["source"]:
            # Retrieval: was a chunk with the answer, from the right document, sent to the LLM?
            sources = q["source"].split("|")
            hit = any(r.source in sources and contains(r.content, q["expected"]) for r in result.rows)
            correct = contains(result.text, q["expected"])
            retrieved += hit
            answered += correct
            followups_answered += correct and bool(q["previous"])
            if not (hit and correct):
                failures.append(f"{'answer' if hit else 'retrieval'} miss: {q['question']} (searched: {result.search_query})")
        else:
            # Off-topic: refused if the answer cites nothing
            ok = "[" not in result.text
            refused += ok
            if not ok:
                failures.append(f"answered off-topic: {q['question']}")

    n_answerable = sum(1 for q in questions if q["source"])
    n_followups = sum(1 for q in questions if q["previous"])
    metrics = {
        "Right chunk retrieved": ratio(retrieved, n_answerable),
        "Correct answer": ratio(answered, n_answerable),
        "…of which follow-up questions": ratio(followups_answered, n_followups),
        "Off-topic refused": ratio(refused, len(questions) - n_answerable),
        "Avg. response time": f"{sum(latencies) / len(latencies):.1f} s",
    }
    return metrics, failures


def print_table(title: str, metrics: dict[str, dict]) -> None:
    labels = list(metrics)
    print(f"\n{title}\n")
    print("| Metric | " + " | ".join(labels) + " |")
    print("|---" * (len(labels) + 1) + "|")
    for name in metrics[labels[0]]:
        print(f"| {name} | " + " | ".join(metrics[label][name] for label in labels) + " |")


if __name__ == "__main__":
    with QUESTIONS_PATH.open(encoding="utf-8") as f:
        questions = list(csv.DictReader(f))

    n_chunks, has_diskann = table_stats()
    print(f"\n{n_chunks} chunks · {'DiskANN (ANN)' if has_diskann else 'exact ENN'} · {EMBED_MODEL} · {LLM_MODEL}")

    for set_name in ("tuning", "holdout"):
        subset = [q for q in questions if q["set"] == set_name]
        metrics, failures = {}, {}
        for mode, label in SEARCH_MODES.items():
            metrics[label], failures[label] = evaluate(mode, subset)
        print_table(f"## {set_name} set: {len(subset)} questions", metrics)
        for label, items in failures.items():
            if items:
                print(f"\n{label} failures:")
                for failure in items:
                    print(f"  - {failure}")
