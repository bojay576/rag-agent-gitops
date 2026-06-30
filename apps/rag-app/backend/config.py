from functools import lru_cache
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    llm_provider: str = Field(default="ollama", alias="LLM_PROVIDER")
    llm_api_key: str = Field(default="", alias="LLM_API_KEY")
    llm_api_base: str = Field(default="", alias="LLM_API_BASE")
    llm_model: str = Field(default="", alias="LLM_MODEL")

    embedding_api_key: str = Field(default="", alias="EMBEDDING_API_KEY")
    embedding_api_base: str = Field(default="", alias="EMBEDDING_API_BASE")
    embedding_model: str = Field(default="", alias="EMBEDDING_MODEL")

    ollama_url: str = Field(default="http://ollama.rag-app.svc.cluster.local:11434", alias="OLLAMA_URL")
    ollama_model: str = Field(default="qwen2.5:7b", alias="OLLAMA_MODEL")
    ollama_embedding_model: str = Field(default="nomic-embed-text", alias="OLLAMA_EMBEDDING_MODEL")

    milvus_address: str = Field(default="milvus.milvus.svc.cluster.local:19530", alias="MILVUS_ADDRESS")
    milvus_collection: str = Field(default="rag_knowledge", alias="MILVUS_COLLECTION")
    knowledge_base_path: str = Field(default="/knowledge-base", alias="KNOWLEDGE_BASE_PATH")
    auto_import_knowledge: bool = Field(default=False, alias="AUTO_IMPORT_KNOWLEDGE")

    retrieval_top_k: int = Field(default=5, alias="RETRIEVAL_TOP_K")
    retrieval_score_threshold: float = Field(default=0.5, alias="RETRIEVAL_SCORE_THRESHOLD")


@lru_cache
def get_settings() -> Settings:
    return Settings()
