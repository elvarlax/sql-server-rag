"""Unit tests for the MCP server. Retrieval and the database are mocked, so no services are needed."""
import asyncio
import os
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from mcp.server.mcpserver.exceptions import ToolError

import mcp_server


def row(source, content, score):
    return SimpleNamespace(source=source, content=content, score=score)


def call(tool, **arguments):
    """Call a tool the way an MCP client would and return its structured result."""
    result = asyncio.run(mcp_server.mcp.call_tool(tool, arguments))
    assert not result.is_error, result.content
    return result.structured_content


def test_tools_are_listed_as_read_only():
    tools = {t.name: t for t in asyncio.run(mcp_server.mcp.list_tools())}
    assert set(tools) == {"search_documents", "database_status"}
    assert all(t.annotations.read_only_hint for t in tools.values())


def test_search_returns_numbered_passages_with_sources():
    rows = [row("Demo_Starfsmannahandbok.pdf", "Starfsfólk fær 25 orlofsdaga.", 0.0312),
            row("Demo_Sidareglur.pdf", "Gjafir yfir 10.000 kr. ...", 0.0161)]
    with patch("mcp_server.retrieve", return_value=(rows, "hybrid")) as retrieve:
        result = call("search_documents", question="Hvað fæ ég marga orlofsdaga?")

    retrieve.assert_called_once_with("Hvað fæ ég marga orlofsdaga?", "hybrid")
    assert result["mode"] == "hybrid"
    assert [p["n"] for p in result["passages"]] == [1, 2]
    assert result["passages"][0]["source"] == "Demo_Starfsmannahandbok.pdf"
    assert result["passages"][0]["score"] == 0.0312


def test_search_passes_vector_mode_through():
    with patch("mcp_server.retrieve", return_value=([], "vector")) as retrieve:
        result = call("search_documents", question="orlof", mode="vector")
    retrieve.assert_called_once_with("orlof", "vector")
    assert result == {"mode": "vector", "passages": []}  # nothing close enough: no passages


def test_search_rejects_unknown_mode():
    # The input schema only allows hybrid or vector; the client gets the error back as a tool error
    with patch("mcp_server.retrieve") as retrieve, pytest.raises(ToolError):
        asyncio.run(mcp_server.mcp.call_tool("search_documents", {"question": "orlof", "mode": "keyword"}))
    retrieve.assert_not_called()


def test_database_status():
    with patch("mcp_server.table_stats", return_value=(101, True)):
        result = call("database_status")
    assert result["chunks"] == 101
    assert result["vector_index"].startswith("DiskANN")


def test_server_refuses_to_start_as_the_app_login():
    # rag_app may delete chunks, so the server must only ever run as the read-only rag_mcp
    env = {**os.environ, "SQL_LOGIN": "rag_app"}
    result = subprocess.run([sys.executable, "mcp_server.py"], env=env, capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode != 0
    assert "must log in as rag_mcp" in result.stderr
