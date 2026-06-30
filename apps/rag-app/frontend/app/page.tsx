"use client";

import { FormEvent, useState } from "react";

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

export default function Home() {
  const [question, setQuestion] = useState("");
  const [loading, setLoading] = useState(false);
  const [messages, setMessages] = useState<Message[]>([
    {
      role: "assistant",
      content: "你好，我已经连接到知识库问答后端。可以直接问 Go、Kubernetes 或你放进 knowledge-base 的内容。",
    },
  ]);

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
