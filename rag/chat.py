from typing import NamedTuple

from openai import OpenAI

from rag.config import HISTORY_MESSAGES, LLM_API_KEY, LLM_BASE_URL, LLM_MODEL
from rag.retrieval import retrieve

# One client for every provider: they all expose the OpenAI chat completions API
client = OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY or "not-needed")

NOT_FOUND = "No information about this topic was found in the documents."

ANSWER_PROMPT = (
    "You answer questions using only the numbered context below.\n"
    "- Cite the chunks you used, e.g. [1] or [2][3].\n"
    "- Answer only what the question asks. Related information about a different topic is not an answer.\n"
    "- If the context doesn't contain the answer, say you couldn't find it in the documents and don't cite anything. Do not guess.\n"
    "- If the context only partly answers the question, share that part and say what's missing.\n"
    "- Answer in the same language as the question.\n\n"
    "Context:\n{context}"
)

REWRITE_PROMPT = (
    "Rewrite the user's last message as a standalone question that can be understood without "
    "the conversation. Keep the same language. Return only the question."
)


class Answer(NamedTuple):
    text: str
    rows: list         # chunks sent to the LLM, each with source, content and score
    mode: str          # search mode actually used
    search_query: str  # what was searched for: the question itself, or its standalone rewrite


def complete(messages: list[dict]) -> str:
    response = client.chat.completions.create(model=LLM_MODEL, messages=messages)
    return (response.choices[0].message.content or "") if response.choices else ""


def standalone_question(query: str, history: list) -> str:
    """Rewrite a follow-up like "and for part-time staff?" into a question that can be searched on its own."""
    if not history:
        return query
    rewritten = complete([{"role": "system", "content": REWRITE_PROMPT}, *history[-HISTORY_MESSAGES:],
                          {"role": "user", "content": query}])
    return rewritten.strip() or query


def chat(query: str, history: list, mode: str = "hybrid") -> Answer:
    """Retrieve relevant chunks for the question and ask the LLM to answer from them."""
    search_query = standalone_question(query, history)
    rows, mode_used = retrieve(search_query, mode=mode)
    if not rows:
        return Answer(NOT_FOUND, rows, mode_used, search_query)

    # Number each chunk so the LLM can cite it and the UI can show which chunk [n] refers to
    context = "\n\n".join(f"[{i}] ({r.source})\n{r.content}" for i, r in enumerate(rows, 1))
    answer = complete([
        {"role": "system", "content": ANSWER_PROMPT.format(context=context)},
        *history[-HISTORY_MESSAGES:],
        {"role": "user", "content": query},
    ])
    return Answer(answer or "The response was blocked by a content filter.", rows, mode_used, search_query)
