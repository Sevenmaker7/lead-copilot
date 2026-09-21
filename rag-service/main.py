"""
Lead Copilot RAG service.

Tiny FastAPI + Chroma microservice that grounds the Responder agent's draft
replies in the company's actual docs (services, pricing, FAQ) so the LLM can't
invent facts, prices, or promises that aren't in the source material.

Endpoints:
  GET  /health         - liveness check
  POST /ingest          - (re)build the vector index from /data/docs/*.md
  POST /query           - top-k relevant chunks for a query, used by n8n's
                          Responder agent node before drafting a reply
"""

import glob
import os
import re

import chromadb
import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

DOCS_DIR = "/data/docs"
CHROMA_DIR = "/data/chroma"
COLLECTION_NAME = "company_docs"
EMBEDDING_MODEL = "models/gemini-embedding-001"
GEMINI_API_KEY = os.environ["GEMINI_API_KEY"]
GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

app = FastAPI(title="Lead Copilot RAG service")
chroma = chromadb.PersistentClient(path=CHROMA_DIR)


class QueryRequest(BaseModel):
    query: str
    k: int = 4


class QueryResult(BaseModel):
    source: str
    heading: str
    text: str
    score: float


class QueryResponse(BaseModel):
    results: list[QueryResult]


def chunk_markdown(path: str) -> list[dict]:
    """Split a markdown file into chunks on '## ' headings. Each chunk keeps
    its filename + heading as metadata so grounded replies can cite a source."""
    text = open(path, encoding="utf-8").read()
    filename = os.path.basename(path)
    sections = re.split(r"(?m)^##\s+", text)
    chunks = []
    # sections[0] is anything before the first heading (usually the title/intro)
    if sections[0].strip():
        chunks.append({"heading": "Overview", "text": sections[0].strip()})
    for section in sections[1:]:
        lines = section.split("\n", 1)
        heading = lines[0].strip()
        body = lines[1].strip() if len(lines) > 1 else ""
        if body:
            chunks.append({"heading": heading, "text": body})
    return [{"source": filename, **c} for c in chunks]


def embed(texts: list[str]) -> list[list[float]]:
    """Embed via Gemini's free-tier embedding model.

    Gemini's newer embedding models (gemini-embedding-001) only support the
    single-text `embedContent` method synchronously - `batchEmbedContents` was
    a text-embedding-004-era endpoint that 404s on this model. Our chunk counts
    are small (a few dozen at most), so looping is fine.
    """
    values = []
    with httpx.Client(timeout=30) as client:
        for t in texts:
            resp = client.post(
                f"{GEMINI_BASE_URL}/{EMBEDDING_MODEL}:embedContent",
                params={"key": GEMINI_API_KEY},
                json={"content": {"parts": [{"text": t}]}},
            )
            resp.raise_for_status()
            values.append(resp.json()["embedding"]["values"])
    return values


def build_index() -> int:
    try:
        chroma.delete_collection(COLLECTION_NAME)
    except Exception:
        pass
    collection = chroma.create_collection(COLLECTION_NAME)

    all_chunks = []
    for path in sorted(glob.glob(os.path.join(DOCS_DIR, "*.md"))):
        all_chunks.extend(chunk_markdown(path))

    if not all_chunks:
        return 0

    embeddings = embed([c["text"] for c in all_chunks])
    collection.add(
        ids=[f"{c['source']}::{i}" for i, c in enumerate(all_chunks)],
        embeddings=embeddings,
        documents=[c["text"] for c in all_chunks],
        metadatas=[{"source": c["source"], "heading": c["heading"]} for c in all_chunks],
    )
    return len(all_chunks)


@app.on_event("startup")
def startup():
    try:
        collection = chroma.get_collection(COLLECTION_NAME)
        if collection.count() == 0:
            build_index()
    except Exception:
        build_index()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/ingest")
def ingest():
    count = build_index()
    if count == 0:
        raise HTTPException(status_code=400, detail=f"No .md files found in {DOCS_DIR}")
    return {"chunks_indexed": count}


@app.post("/query", response_model=QueryResponse)
def query(req: QueryRequest):
    collection = chroma.get_collection(COLLECTION_NAME)
    if collection.count() == 0:
        raise HTTPException(status_code=400, detail="Index is empty - call POST /ingest first")

    [query_embedding] = embed([req.query])
    results = collection.query(query_embeddings=[query_embedding], n_results=req.k)

    return QueryResponse(
        results=[
            QueryResult(
                source=meta["source"],
                heading=meta["heading"],
                text=doc,
                score=1 - dist,  # cosine distance -> similarity
            )
            for doc, meta, dist in zip(
                results["documents"][0], results["metadatas"][0], results["distances"][0]
            )
        ]
    )
