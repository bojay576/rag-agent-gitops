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
