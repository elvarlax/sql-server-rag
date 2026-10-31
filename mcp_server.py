"""MCP server: lets an AI agent search the documents in SQL Server.

The agent (Claude Code, VS Code, Claude Desktop, ...) gets two read-only tools: search_documents runs
the same search as the chat app and returns numbered passages with their sources, and database_status
reports what's loaded. The agent writes the answer itself, so no LLM key is needed here; only SQL
Server and Ollama (for embeddings).

The agent never writes SQL: the tools only run the fixed searches, as rag_app, which can't create or
drop anything in the database (see database/Security).

Run it over stdio from an MCP client, for example in .mcp.json:
    {"mcpServers": {"sql-server-rag": {"command": "python", "args": ["mcp_server.py"]}}}
"""
import logging
from typing import Literal

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations
from typing_extensions import TypedDict  # pydantic needs it on Python < 3.12

from rag.config import MAX_DISTANCE
from rag.db import table_stats
from rag.retrieval import retrieve

# stdout carries the MCP protocol, so logs must go to stderr (the default for logging)
logging.basicConfig(level=logging.WARNING)

mcp = MCPServer(
    name="sql-server-rag",
    instructions=(
        "Searches a company's policy documents (in Icelandic) stored in SQL Server 2025. "
        "Call search_documents before answering questions about the company's policies, "
        "answer only from the returned passages, and cite them as [n]. "
        "If no passages are returned, say that the documents don't answer the question."
    ),
)

READ_ONLY = ToolAnnotations(read_only_hint=True, idempotent_hint=True, open_world_hint=False)


# Typed results give the client an output schema, so the agent knows the fields before calling
class Passage(TypedDict):
    n: int        # cite as [n]
    source: str   # file the passage came from
    content: str
    score: float  # RRF score for hybrid (higher is better), cosine distance for vector (lower is better)


class SearchResult(TypedDict):
    mode: str
    passages: list[Passage]


class DatabaseStatus(TypedDict):
    chunks: int
    vector_index: str
    max_distance: float


@mcp.tool(annotations=READ_ONLY)
def search_documents(question: str, mode: Literal["hybrid", "vector"] = "hybrid") -> SearchResult:
    """Search the documents for passages that answer a question (Icelandic or English).

    Returns up to 5 numbered passages with their source file. An empty list means nothing in the
    documents is close enough to the question, so it should not be answered from them.
    Use mode="hybrid" (vector + full-text, the default) unless asked for vector-only search.
    """
    rows, used = retrieve(question, mode)
    return {
        "mode": used,
        "passages": [
            {"n": i, "source": r.source, "content": r.content, "score": round(float(r.score), 4)}
            for i, r in enumerate(rows, start=1)
        ],
    }


@mcp.tool(annotations=READ_ONLY)
def database_status() -> DatabaseStatus:
    """How many chunks are loaded and whether vector search uses the DiskANN index."""
    chunks, has_diskann = table_stats()
    return {
        "chunks": chunks,
        "vector_index": "DiskANN (approximate)" if has_diskann else "none (exact search)",
        "max_distance": MAX_DISTANCE,
    }


if __name__ == "__main__":
    mcp.run()  # stdio
