import hashlib
from typing import Any

import httpx

from config import Settings


class EmbeddingClient:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def embed(self, text: str) -> list[float]:
        provider = self.settings.llm_provider.lower()
        if provider == "ollama":
            return await self._embed_ollama(text)
        if provider in {"openai", "anthropic"} and self.settings.embedding_api_base:
            return await self._embed_openai_compatible(text)
        return self._local_embedding(text)

    async def _embed_ollama(self, text: str) -> list[float]:
        url = f"{self.settings.ollama_url.rstrip('/')}/api/embeddings"
        payload = {"model": self.settings.ollama_embedding_model, "prompt": text}
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(url, json=payload)
            response.raise_for_status()
            data = response.json()
        return [float(value) for value in data.get("embedding", [])]

    async def _embed_openai_compatible(self, text: str) -> list[float]:
        url = f"{self.settings.embedding_api_base.rstrip('/')}/embeddings"
        model = self.settings.embedding_model or "text-embedding-3-small"
        headers = self._auth_headers(
            self.settings.embedding_api_key or self.settings.llm_api_key
        )
        payload: dict[str, Any] = {"model": model, "input": text}
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(url, headers=headers, json=payload)
            response.raise_for_status()
            data = response.json()
        return [float(value) for value in data["data"][0]["embedding"]]

    def _auth_headers(self, api_key: str) -> dict[str, str]:
        if not api_key or api_key.startswith("your-"):
            return {}
        return {"Authorization": f"Bearer {api_key}"}

    def _local_embedding(self, text: str) -> list[float]:
        digest = hashlib.sha256(text.encode("utf-8")).digest()
        vector = [
            ((digest[index % len(digest)] / 255.0) * 2.0) - 1.0 for index in range(384)
        ]
        norm = sum(value * value for value in vector) ** 0.5 or 1.0
        return [value / norm for value in vector]
