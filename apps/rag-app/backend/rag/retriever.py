import math
from typing import Any
from uuid import uuid4

from pydantic import BaseModel, Field

try:
    from pymilvus import Collection, CollectionSchema, DataType, FieldSchema, connections, utility
except Exception:  # pragma: no cover - pymilvus is optional for unit tests.
    Collection = None
    CollectionSchema = None
    DataType = None
    FieldSchema = None
    connections = None
    utility = None

from config import Settings


class DocumentChunk(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid4()))
    source: str
    title: str
    content: str
    embedding: list[float] = Field(default_factory=list)
    score: float | None = None


class Retriever:
    _memory_chunks: list[DocumentChunk] = []

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def upsert(self, chunks: list[DocumentChunk]) -> None:
        if not chunks:
            return
        if self._milvus_available():
            self._upsert_milvus(chunks)
            return

        existing = {(chunk.source, chunk.title, chunk.content): chunk for chunk in self._memory_chunks}
        for chunk in chunks:
            existing[(chunk.source, chunk.title, chunk.content)] = chunk
        self._memory_chunks = list(existing.values())

    async def search(self, vector: list[float], top_k: int = 5) -> list[DocumentChunk]:
        if self._milvus_available():
            return self._search_milvus(vector, top_k)
        scored = [
            chunk.model_copy(update={"score": self._cosine_similarity(vector, chunk.embedding)})
            for chunk in self._memory_chunks
            if chunk.embedding
        ]
        scored.sort(key=lambda chunk: chunk.score or 0, reverse=True)
        return scored[:top_k]

    def _milvus_available(self) -> bool:
        return all([Collection, CollectionSchema, DataType, FieldSchema, connections, utility])

    def _connect(self) -> None:
        host, _, port = self.settings.milvus_address.partition(":")
        connections.connect(alias="default", host=host, port=port or "19530")

    def _ensure_collection(self, dimension: int) -> Any:
        self._connect()
        if utility.has_collection(self.settings.milvus_collection):
            return Collection(self.settings.milvus_collection)

        schema = CollectionSchema(
            fields=[
                FieldSchema(name="id", dtype=DataType.VARCHAR, is_primary=True, max_length=64),
                FieldSchema(name="source", dtype=DataType.VARCHAR, max_length=512),
                FieldSchema(name="title", dtype=DataType.VARCHAR, max_length=256),
                FieldSchema(name="content", dtype=DataType.VARCHAR, max_length=8192),
                FieldSchema(name="embedding", dtype=DataType.FLOAT_VECTOR, dim=dimension),
            ],
            description="RAG knowledge chunks",
        )
        collection = Collection(self.settings.milvus_collection, schema=schema)
        collection.create_index("embedding", {"index_type": "AUTOINDEX", "metric_type": "COSINE"})
        return collection

    def _upsert_milvus(self, chunks: list[DocumentChunk]) -> None:
        collection = self._ensure_collection(len(chunks[0].embedding))
        collection.upsert(
            [
                [chunk.id for chunk in chunks],
                [chunk.source for chunk in chunks],
                [chunk.title for chunk in chunks],
                [chunk.content for chunk in chunks],
                [chunk.embedding for chunk in chunks],
            ]
        )
        collection.flush()

    def _search_milvus(self, vector: list[float], top_k: int) -> list[DocumentChunk]:
        collection = self._ensure_collection(len(vector))
        collection.load()
        results = collection.search(
            data=[vector],
            anns_field="embedding",
            param={"metric_type": "COSINE"},
            limit=top_k,
            output_fields=["source", "title", "content"],
        )
        chunks: list[DocumentChunk] = []
        for hit in results[0]:
            entity = hit.entity
            chunks.append(
                DocumentChunk(
                    id=str(hit.id),
                    source=entity.get("source"),
                    title=entity.get("title"),
                    content=entity.get("content"),
                    score=float(hit.score),
                )
            )
        return chunks

    def _cosine_similarity(self, left: list[float], right: list[float]) -> float:
        if not left or not right:
            return 0.0
        pairs = zip(left, right)
        dot = sum(a * b for a, b in pairs)
        left_norm = math.sqrt(sum(a * a for a in left))
        right_norm = math.sqrt(sum(b * b for b in right))
        if not left_norm or not right_norm:
            return 0.0
        return dot / (left_norm * right_norm)
