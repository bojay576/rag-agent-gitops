import httpx

from config import Settings
from rag.retriever import DocumentChunk


class LLMClient:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def answer(self, question: str, documents: list[DocumentChunk]) -> str:
        provider = self.settings.llm_provider.lower()
        context = "\n\n".join(f"[{doc.title}]\n{doc.content}" for doc in documents)

        if provider == "ollama":
            return await self._answer_ollama(question, context)
        if provider == "openai":
            return await self._answer_openai(question, context)
        if provider == "anthropic":
            return await self._answer_anthropic(question, context)

        return self._fallback_answer(question, documents)

    async def _answer_ollama(self, question: str, context: str) -> str:
        url = f"{self.settings.ollama_url.rstrip('/')}/api/generate"
        payload = {
            "model": self.settings.ollama_model,
            "stream": False,
            "prompt": self._prompt(question, context),
        }
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.post(url, json=payload)
            response.raise_for_status()
            data = response.json()
        return data.get("response", "").strip()

    async def _answer_openai(self, question: str, context: str) -> str:
        base_url = self.settings.llm_api_base.rstrip("/") or "https://api.openai.com/v1"
        model = self.settings.llm_model or "gpt-4o"
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": "Answer using the supplied knowledge context. Say when context is missing."},
                {"role": "user", "content": self._prompt(question, context)},
            ],
        }
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.post(
                f"{base_url}/chat/completions",
                headers=self._auth_headers(),
                json=payload,
            )
            response.raise_for_status()
            data = response.json()
        return data["choices"][0]["message"]["content"].strip()

    async def _answer_anthropic(self, question: str, context: str) -> str:
        base_url = self.settings.llm_api_base.rstrip("/") or "https://api.anthropic.com/v1"
        model = self.settings.llm_model or "claude-sonnet-4-6"
        headers = self._auth_headers()
        headers["anthropic-version"] = "2023-06-01"
        payload = {
            "model": model,
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": self._prompt(question, context)}],
        }
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.post(f"{base_url}/messages", headers=headers, json=payload)
            response.raise_for_status()
            data = response.json()
        return "".join(part.get("text", "") for part in data.get("content", [])).strip()

    def _prompt(self, question: str, context: str) -> str:
        return f"Knowledge context:\n{context or '(no matching context)'}\n\nQuestion: {question}\nAnswer:"

    def _auth_headers(self) -> dict[str, str]:
        if not self.settings.llm_api_key or self.settings.llm_api_key.startswith("your-"):
            return {}
        return {"Authorization": f"Bearer {self.settings.llm_api_key}"}

    def _fallback_answer(self, question: str, documents: list[DocumentChunk]) -> str:
        if not documents:
            return f"No knowledge context is available for: {question}"
        titles = ", ".join(doc.title for doc in documents)
        return f"Found relevant knowledge sections: {titles}"
