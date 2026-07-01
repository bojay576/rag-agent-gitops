import pytest

from config import Settings
from rag.retriever import DocumentChunk, Retriever


@pytest.mark.asyncio
async def test_search_filters_chunks_below_score_threshold() -> None:
    settings = Settings(RETRIEVAL_SCORE_THRESHOLD=0.9)
    retriever = Retriever(settings)
    retriever._memory_chunks = [
        DocumentChunk(
            source="high.md",
            title="high",
            content="high",
            embedding=[1.0, 0.0],
        ),
        DocumentChunk(
            source="low.md",
            title="low",
            content="low",
            embedding=[0.0, 1.0],
        ),
    ]

    results = await retriever.search([1.0, 0.0], top_k=5)

    assert [result.source for result in results] == ["high.md"]


@pytest.mark.asyncio
async def test_search_falls_back_to_memory_when_milvus_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = Settings(RETRIEVAL_SCORE_THRESHOLD=0.0)
    retriever = Retriever(settings)
    retriever._memory_chunks = [
        DocumentChunk(
            source="cached.md",
            title="cached",
            content="cached",
            embedding=[1.0, 0.0],
        )
    ]

    monkeypatch.setattr(retriever, "_milvus_client_installed", lambda: True)

    def raise_milvus_error(vector: list[float], top_k: int) -> list[DocumentChunk]:
        raise RuntimeError("milvus unavailable")

    monkeypatch.setattr(retriever, "_search_milvus", raise_milvus_error)

    results = await retriever.search([1.0, 0.0], top_k=5)

    assert [result.source for result in results] == ["cached.md"]


@pytest.mark.asyncio
async def test_upsert_falls_back_to_memory_when_milvus_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    retriever = Retriever(Settings())
    retriever._memory_chunks = []
    chunk = DocumentChunk(
        source="new.md",
        title="new",
        content="new",
        embedding=[1.0, 0.0],
    )

    monkeypatch.setattr(retriever, "_milvus_client_installed", lambda: True)

    def raise_milvus_error(chunks: list[DocumentChunk]) -> None:
        raise RuntimeError("milvus unavailable")

    monkeypatch.setattr(retriever, "_upsert_milvus", raise_milvus_error)

    await retriever.upsert([chunk])

    assert [cached.source for cached in retriever._memory_chunks] == ["new.md"]
