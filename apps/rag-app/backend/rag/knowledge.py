from pathlib import Path

from config import Settings
from rag.embedding import EmbeddingClient
from rag.retriever import DocumentChunk, Retriever

SUPPORTED_SUFFIXES = {".md", ".txt", ".json"}


class KnowledgeImporter:
    def __init__(
        self, settings: Settings, embedding: EmbeddingClient, retriever: Retriever
    ) -> None:
        self.settings = settings
        self.embedding = embedding
        self.retriever = retriever

    async def import_all(self) -> int:
        base_path = Path(self.settings.knowledge_base_path)
        if not base_path.exists():
            return 0

        imported = 0
        for path in sorted(base_path.rglob("*")):
            if path.suffix not in SUPPORTED_SUFFIXES:
                continue
            imported += await self.import_file(str(path))
        return imported

    async def import_file(self, path: str) -> int:
        document_path = Path(path)
        if not document_path.exists() or not document_path.is_file():
            raise FileNotFoundError(f"knowledge document not found: {path}")

        text = document_path.read_text(encoding="utf-8")
        suffix = document_path.suffix.lower()

        if suffix == ".json":
            chunks = self._chunk_json(text, source=str(document_path))
        elif suffix == ".txt":
            chunks = self._chunk_text(text, source=str(document_path))
        else:
            chunks = self._chunk_markdown(text, source=str(document_path))

        for chunk in chunks:
            chunk.embedding = await self.embedding.embed(chunk.content)

        await self.retriever.upsert(chunks)
        return len(chunks)

    def _chunk_markdown(self, text: str, source: str) -> list[DocumentChunk]:
        chunks: list[DocumentChunk] = []
        current_title = Path(source).name
        current_lines: list[str] = []

        def flush() -> None:
            content = "\n".join(current_lines).strip()
            if content:
                chunks.append(
                    DocumentChunk(source=source, title=current_title, content=content)
                )

        for line in text.splitlines():
            if line.startswith("## "):
                flush()
                current_title = line.removeprefix("## ").strip()
                current_lines = [line]
            else:
                current_lines.append(line)

        flush()
        return chunks or [
            DocumentChunk(source=source, title=Path(source).name, content=text.strip())
        ]

    def _chunk_text(self, text: str, source: str) -> list[DocumentChunk]:
        """Split .txt file by blank lines into paragraphs"""
        chunks: list[DocumentChunk] = []
        title = Path(source).name
        for para in text.split("\n\n"):
            content = para.strip()
            if content:
                chunks.append(
                    DocumentChunk(source=source, title=title, content=content)
                )
        return chunks or [
            DocumentChunk(source=source, title=title, content=text.strip())
        ]

    def _chunk_json(self, text: str, source: str) -> list[DocumentChunk]:
        """Split .json file by top-level keys"""
        import json

        chunks: list[DocumentChunk] = []
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return [
                DocumentChunk(
                    source=source, title=Path(source).name, content=text.strip()
                )
            ]

        if isinstance(data, dict):
            for key, value in data.items():
                content = str(value)
                if content.strip():
                    chunks.append(
                        DocumentChunk(source=source, title=key, content=content)
                    )
        elif isinstance(data, list):
            for i, item in enumerate(data):
                content = str(item)
                if content.strip():
                    chunks.append(
                        DocumentChunk(
                            source=source,
                            title=f"{Path(source).name}[{i}]",
                            content=content,
                        )
                    )
        else:
            chunks.append(
                DocumentChunk(
                    source=source, title=Path(source).name, content=text.strip()
                )
            )

        return chunks or [
            DocumentChunk(source=source, title=Path(source).name, content=text.strip())
        ]
