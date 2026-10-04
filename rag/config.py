import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

ROOT = Path(__file__).parent.parent

# LLM — any provider with an OpenAI-compatible API (OpenAI, Azure OpenAI, Ollama, Mistral, Groq, ...).
# Leave LLM_BASE_URL empty for OpenAI. See .env.example for other providers.
LLM_BASE_URL = os.getenv("LLM_BASE_URL") or None
LLM_API_KEY  = os.getenv("LLM_API_KEY") or os.getenv("OPENAI_API_KEY", "")
LLM_MODEL    = os.getenv("LLM_MODEL") or "gpt-6-luna"  # cheap, fast and good at Icelandic
LLM_READY    = bool(LLM_API_KEY or LLM_BASE_URL)      # local servers like Ollama need no key

# SQL Server
SQL_SERVER   = os.getenv("SQL_SERVER", "localhost,1433")
SQL_PASSWORD = os.getenv("SQL_PASSWORD", "")
DB_NAME      = "RagDemo"

# Documents and embeddings
DOCS_PATH      = ROOT / "docs"
QUESTIONS_PATH = ROOT / "questions.csv"
EMBED_MODEL    = "bge-m3"  # multilingual; handles Icelandic and cross-language questions
EMBED_DIMS     = 1024      # must match EMBED_MODEL — changing model requires re-ingesting
CHUNK_SIZE     = 500       # characters
CHUNK_OVERLAP  = 50        # characters shared by neighbouring chunks

# Retrieval
TOP_K            = 5     # chunks sent to the LLM
MAX_DISTANCE     = 0.52  # cosine distance: nothing farther is relevant (calibrated for bge-m3 on the tuning set)
RRF_CANDIDATES   = 20    # hybrid search: how many of each ranking's top results are fused
DISKANN_MIN_ROWS = 100   # SQL Server needs at least this many rows to build a DiskANN index
HISTORY_MESSAGES = 6     # earlier chat messages sent along with each question
