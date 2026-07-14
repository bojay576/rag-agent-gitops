from pathlib import Path
import shutil

from fastapi import FastAPI, File, HTTPException, UploadFile
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
        importer = KnowledgeImporter(
            settings, EmbeddingClient(settings), Retriever(settings)
        )
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
    importer = KnowledgeImporter(
        settings, EmbeddingClient(settings), Retriever(settings)
    )
    imported = await importer.import_file(request.path)
    return {"imported": imported}


@app.post("/api/knowledge/import-all")
async def import_all() -> dict[str, object]:
    settings = get_settings()
    importer = KnowledgeImporter(
        settings, EmbeddingClient(settings), Retriever(settings)
    )
    imported = await importer.import_all()
    return {"imported": imported}


@app.post("/api/knowledge/upload")
async def upload_file(file: UploadFile = File(...)) -> dict[str, object]:
    """Upload a file to the knowledge base directory"""
    settings = get_settings()
    dest = Path(settings.knowledge_base_path) / file.filename
    with dest.open("wb") as f:
        shutil.copyfileobj(file.file, f)
    return {"filename": file.filename, "status": "uploaded"}


@app.get("/api/knowledge/files")
async def list_files() -> dict[str, object]:
    """List files in the knowledge base directory"""
    settings = get_settings()
    base = Path(settings.knowledge_base_path)
    if not base.exists():
        return {"files": []}
    files = []
    for p in sorted(base.iterdir()):
        if p.is_file():
            files.append({"name": p.name, "size": p.stat().st_size})
    return {"files": files}
