from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from config import get_settings
from rag.embedding import EmbeddingClient
from rag.knowledge import KnowledgeImporter
from rag.llm import LLMClient
from rag.retriever import Retriever

app = FastAPI(title="RAG Agent API", version="1.0.0")


class ChatRequest(BaseModel):
    question: str


class ImportRequest(BaseModel):
    path: str


@app.on_event("startup")
async def startup_event() -> None:
    settings = get_settings()
    if settings.auto_import_knowledge:
        importer = KnowledgeImporter(settings, EmbeddingClient(settings), Retriever(settings))
        await importer.import_all()


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/api/chat")
async def chat(request: ChatRequest) -> dict[str, object]:
    question = request.question.strip()
    if not question:
        raise HTTPException(status_code=400, detail="question must not be empty")

    settings = get_settings()
    embedding = EmbeddingClient(settings)
    retriever = Retriever(settings)
    llm = LLMClient(settings)

    query_vector = await embedding.embed(question)
    documents = await retriever.search(query_vector, top_k=settings.retrieval_top_k)
    answer = await llm.answer(question, documents)
    return {"answer": answer, "sources": [doc.model_dump() for doc in documents]}


@app.post("/api/knowledge/import")
async def import_document(request: ImportRequest) -> dict[str, object]:
    settings = get_settings()
    importer = KnowledgeImporter(settings, EmbeddingClient(settings), Retriever(settings))
    imported = await importer.import_file(request.path)
    return {"imported": imported}


@app.post("/api/knowledge/import-all")
async def import_all() -> dict[str, object]:
    settings = get_settings()
    importer = KnowledgeImporter(settings, EmbeddingClient(settings), Retriever(settings))
    imported = await importer.import_all()
    return {"imported": imported}
