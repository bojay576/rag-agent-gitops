"use client";

import { FormEvent, useEffect, useRef, useState } from "react";

type Source = {
  source: string;
  title: string;
  score?: number;
};

type Message = {
  role: "user" | "assistant";
  content: string;
  sources?: Source[];
  error?: boolean;
};

type KnowledgeFile = {
  name: string;
  size: number;
};

export default function Home() {
  const [question, setQuestion] = useState("");
  const [loading, setLoading] = useState(false);
  const [messages, setMessages] = useState<Message[]>([
    {
      role: "assistant",
      content: "你好，我已经连接到知识库问答后端。可以直接问 Go、Kubernetes 或你放进 knowledge-base 的内容。",
    },
  ]);

  // ---- 文件上传状态 ----
  const [files, setFiles] = useState<KnowledgeFile[]>([]);
  const [uploading, setUploading] = useState(false);
  const [importing, setImporting] = useState(false);
  const [dragging, setDragging] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const ACCEPTED_TYPES = ".md,.txt,.json";

  // ---- 加载文件列表 ----
  const loadFiles = async () => {
    try {
      const res = await fetch("/api/knowledge/files");
      if (res.ok) {
        const data = await res.json();
        setFiles(data.files ?? []);
      }
    } catch {
      // ignore
    }
  };

  // 初始加载文件列表
  useEffect(() => { loadFiles(); }, []);

  // ---- 文件上传 ----
  const uploadFiles = async (fileList: FileList | File[]) => {
    setUploading(true);
    try {
      for (const file of Array.from(fileList)) {
        const formData = new FormData();
        formData.set("file", file);
        await fetch("/api/knowledge/upload", { method: "POST", body: formData });
      }
      await loadFiles();
    } catch {
      // ignore
    } finally {
      setUploading(false);
    }
  };

  // ---- 拖拽事件 ----
  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    setDragging(true);
  };
  const handleDragLeave = () => setDragging(false);
  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragging(false);
    if (e.dataTransfer.files.length) uploadFiles(e.dataTransfer.files);
  };

  // ---- 导入到 Milvus ----
  const handleImport = async () => {
    setImporting(true);
    try {
      await fetch("/api/knowledge/import-all", { method: "POST" });
    } catch {
      // ignore
    } finally {
      setImporting(false);
    }
  };

  // ---- 聊天 ----
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmed = question.trim();
    if (!trimmed || loading) return;

    setMessages((current) => [...current, { role: "user", content: trimmed }]);
    setQuestion("");
    setLoading(true);

    try {
      const response = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question: trimmed }),
      });
      const data = await response.json();
      if (!response.ok) {
        throw new Error(data.detail ?? "请求失败");
      }
      setMessages((current) => [
        ...current,
        { role: "assistant", content: data.answer ?? "", sources: data.sources ?? [] },
      ]);
    } catch (error) {
      const message = error instanceof Error ? error.message : "未知错误";
      setMessages((current) => [...current, { role: "assistant", content: message, error: true }]);
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="shell">
      <aside className="sidebar">
        <h1 className="brand">RAG Agent</h1>
        <p className="muted">面向 GitOps 知识库的检索增强问答界面。后端会检索 Milvus 中的文档片段，再交给配置的 LLM 生成回答。</p>

        {/* ---- 文件上传区域 ---- */}
        <section className="upload-section">
          <h2 className="upload-heading">📁 知识库文件</h2>
          <div
            className={`drop-zone${dragging ? " drag-over" : ""}`}
            onDragOver={handleDragOver}
            onDragLeave={handleDragLeave}
            onDrop={handleDrop}
            onClick={() => fileInputRef.current?.click()}
          >
            <input
              ref={fileInputRef}
              type="file"
              multiple
              accept={ACCEPTED_TYPES}
              className="file-input-hidden"
              onChange={(e) => e.target.files && uploadFiles(e.target.files)}
            />
            {uploading ? (
              <span className="drop-hint">上传中...</span>
            ) : (
              <span className="drop-hint">
                拖拽文件到此处<br />或点击选择文件
              </span>
            )}
          </div>

          {files.length > 0 && (
            <div className="file-list">
              {files.map((f) => (
                <div key={f.name} className="file-item">
                  <span className="file-name">📄 {f.name}</span>
                  <span className="file-size">{(f.size / 1024).toFixed(1)} KB</span>
                </div>
              ))}
            </div>
          )}

          <div className="upload-actions">
            <span className="file-count">✓ {files.length} 个文件</span>
            <button className="import-btn" onClick={handleImport} disabled={importing || files.length === 0}>
              {importing ? "导入中..." : "导入到 Milvus"}
            </button>
          </div>
        </section>
      </aside>
      <section className="main">
        <div className="messages">
          {messages.map((message, index) => (
            <article key={index} className={`message ${message.role} ${message.error ? "error" : ""}`}>
              {message.content}
              {message.sources && message.sources.length > 0 ? (
                <div className="source">
                  来源：{message.sources.map((source) => source.title || source.source).join(" / ")}
                </div>
              ) : null}
            </article>
          ))}
        </div>
        <form className="composer" onSubmit={submit}>
          <textarea
            value={question}
            onChange={(event) => setQuestion(event.target.value)}
            placeholder="输入你的问题..."
            aria-label="问题"
          />
          <button type="submit" disabled={loading}>
            {loading ? "生成中" : "发送"}
          </button>
        </form>
      </section>
    </main>
  );
}
