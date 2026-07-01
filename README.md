# RAG Agent GitOps

基于 Kubernetes 的 RAG（检索增强生成）知识库问答系统，支持多 LLM 后端（Ollama / OpenAI / Anthropic），通过 GitOps 方式一键部署到 K8s 集群。

## 架构概览

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Browser    │────▶│  rag-frontend    │────▶│  rag-backend    │
│  (NodePort)  │     │  (Node.js :3000) │     │  (Python :8080) │
└──────────────┘     └──────────────────┘     └────────┬────────┘
                                                       │
                                          ┌────────────┼────────────┐
                                          │            │            │
                                          ▼            ▼            ▼
                                   ┌──────────┐ ┌──────────┐ ┌──────────┐
                                   │  Milvus  │ │  Ollama  │ │ LLM API  │
                                   │ (向量库)  │ │ (本地)   │ │ (云端)   │
                                   └──────────┘ └──────────┘ └──────────┘
```

**核心流程：**
1. 用户通过浏览器访问前端界面，输入问题
2. 前端将问题发送到后端 API
3. 后端调用 Embedding 模型将问题向量化
4. 在 Milvus 向量库中检索最相似的文档片段
5. 将检索结果作为上下文，结合用户问题，发送给 LLM 生成答案
6. 答案返回前端展示给用户

## 目录结构

```
rag-agent-gitops/
├── README.md                           # 本文档
├── deploy.sh                           # 一键部署脚本
├── apps/
│   ├── milvus/
│   │   ├── namespace.yaml              # Milvus 命名空间
│   │   └── pv.yaml                     # Milvus 持久化卷 (etcd/MinIO/standalone)
│   └── rag-app/
│       ├── backend/                    # FastAPI 后端源码和 Dockerfile
│       ├── frontend/                   # Next.js 前端源码和 Dockerfile
│       ├── namespace.yaml              # 应用命名空间
│       ├── backend-config.yaml         # 后端 ConfigMap（LLM 提供商配置）
│       ├── backend-secret.yaml         # 后端 Secret（API Key 等敏感信息）
│       ├── backend.yaml                # 后端 Deployment + Service
│       └── frontend.yaml               # 前端 Deployment + Service
└── knowledge-base/                     # 知识库文档（会被向量化存入 Milvus）
    ├── go-best-practices.md
    └── k8s-troubleshooting.md
```

## 前置条件（Prerequisites）

> 以下是在一台**全新电脑**上实现一键部署所需要满足的条件。

### 硬件要求

| 资源 | 最低要求 | 推荐配置 |
|------|----------|----------|
| CPU | 4 核 | 8 核+ |
| 内存 | 16 GB | 32 GB+ |
| 磁盘 | 100 GB 可用空间 | 200 GB+ SSD |
| 网络 | 可访问互联网（拉取镜像/Helm Chart） | — |

> **注意：** 如果使用本地 Ollama 运行 7B 模型，内存需至少 16GB；Milvus 独立模式需要额外 4-8GB 内存。

### 软件环境

| 软件 | 版本要求 | 用途 | 安装指南 |
|------|----------|------|----------|
| **Kubernetes 集群** | ≥ 1.25 | 容器编排平台 | [k3s](https://k3s.io) / [kind](https://kind.sigs.k8s.io) / [minikube](https://minikube.sigs.k8s.io) |
| **kubectl** | ≥ 1.25 | K8s 命令行工具 | `brew install kubectl` 或 [官方文档](https://kubernetes.io/docs/tasks/tools/) |
| **Helm** | ≥ 3.12 | Milvus 部署（通过 Helm Chart） | `brew install helm` 或 [官方文档](https://helm.sh/docs/intro/install/) |
| **Docker**（可选） | ≥ 24 | 构建自定义镜像 | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| **Ingress Controller**（生产推荐） | nginx-ingress / Traefik 等 | 域名入口和 TLS | [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) |

### K8s 集群要求

- [ ] 集群至少有一个节点处于 `Ready` 状态
- [ ] `kubectl` 能正常连接到集群（`kubectl cluster-info` 成功）
- [ ] 集群已安装默认 StorageClass，或已准备好 hostPath 目录（见下文）
- [ ] 集群有足够的可用资源（CPU/内存/磁盘）
- [ ] 如果使用 NodePort 暴露服务，确保节点 IP 可从浏览器访问
- [ ] 如果使用 Ingress 暴露服务，确保已安装 Ingress Controller（如 nginx-ingress、Traefik）

### 存储说明

本项目的 PV 默认使用 `hostPath`（适合单节点开发/测试环境），数据存储在节点的以下路径：

```
/data/milvus-etcd        # Milvus etcd 元数据 (10Gi)
/data/milvus-minio       # Milvus MinIO 对象存储 (20Gi)
/data/milvus-standalone  # Milvus 向量数据 (50Gi)
```

部署脚本会自动创建这些目录。如需生产环境，请将 `apps/milvus/pv.yaml` 中的 `hostPath` 替换为合适的存储类型（如 NFS、Ceph、Longhorn、云存储等）。

---

## 一键部署

> 确保上述**前置条件**全部满足后，执行以下命令：

```bash
# 1. 克隆仓库
git clone <your-repo-url> && cd rag-agent-gitops

# 2. （重要）配置 LLM 提供商
# 编辑 apps/rag-app/backend-secret.yaml，填入你的 API Key
# 编辑 apps/rag-app/backend-config.yaml，选择 LLM 提供商

# 3. 一键部署
chmod +x deploy.sh
./deploy.sh

# 可选：在集群内部署 Ollama
./deploy.sh --with-ollama

# 或使用外部 Ollama
./deploy.sh --ollama-url http://192.168.1.100:11434
```

部署脚本会自动完成：
1. ✅ 检查前置条件（kubectl、helm、集群状态）
2. ✅ 在节点上创建 hostPath 存储目录
3. ✅ 创建命名空间（`milvus` 和 `rag-app`）
4. ✅ 部署 Milvus 独立版（通过 Helm）
5. ✅ 创建 Milvus PV 资源
6. ✅ 创建应用 ConfigMap 和 Secret
7. ✅ 部署 RAG 后端和前端
8. ✅ 等待所有 Pod 就绪
9. ✅ 输出访问地址

部署完成后，脚本会输出类似以下信息：

```
========================================
  🎉 RAG Agent GitOps 部署完成！
========================================
  前端访问地址: http://192.168.1.100:30000
  Ingress 地址:  http://rag.127-0-0-1.sslip.io
  Milvus 地址:  milvus.milvus.svc.cluster.local:19530

  验证命令:
    kubectl get pods -n rag-app
    kubectl get pods -n milvus

  查看后端日志:
    kubectl logs -f deployment/rag-backend -n rag-app
========================================
```

---

## 本地 Docker Compose 开发

不想启动 Kubernetes 时，可以用 Docker Compose 在本机启动 Milvus、Ollama、后端和前端：

```bash
cp .env.example .env
docker compose up -d --build

# 首次使用 Ollama 时拉取模型
docker compose exec ollama ollama pull qwen2.5:7b
docker compose exec ollama ollama pull nomic-embed-text

# 导入 knowledge-base/ 文档
curl -X POST http://localhost:8080/api/knowledge/import-all
```

前端默认访问 `http://localhost:3000`，后端默认访问 `http://localhost:8080`。Compose 使用与 K8s ConfigMap/Secret 同名的环境变量，可以通过 `.env` 切换 `LLM_PROVIDER`、`OLLAMA_URL`、`LLM_API_BASE` 等配置。

---

## LLM 提供商配置

本项目支持**多种 LLM 后端**，通过 ConfigMap 和 Secret 灵活切换。

### 方式一：Ollama（本地部署，无需 API Key）

**适用场景：** 离线环境、数据隐私敏感、无 API 调用费用。

前置条件：集群内或网络可达的 Ollama 服务。`deploy.sh --with-ollama` 会在 `rag-app` 命名空间内部署 Ollama，并自动把后端 `OLLAMA_URL` 设置为 `http://ollama.rag-app.svc.cluster.local:11434`。如果你已有外部 Ollama，可以使用 `deploy.sh --ollama-url http://<host>:11434`。

```yaml
# backend-config.yaml (ConfigMap)
LLM_PROVIDER: "ollama"
OLLAMA_URL: "http://ollama.rag-app.svc.cluster.local:11434"
OLLAMA_MODEL: "qwen2.5:7b"            # 生成模型
OLLAMA_EMBEDDING_MODEL: "nomic-embed-text"  # 嵌入模型
```

### 方式二：OpenAI 兼容 API（推荐云端调用）

**适用场景：** 不想自己跑模型，调用云端 LLM 服务。

支持所有 OpenAI 兼容接口的服务商（OpenAI / DeepSeek / 通义千问 / Moonshot / 硅基流动 等）。

```yaml
# backend-config.yaml (ConfigMap)
LLM_PROVIDER: "openai"
LLM_API_BASE: "https://api.openai.com/v1"       # 或其他兼容地址
LLM_MODEL: "gpt-4o"                              # 生成模型
EMBEDDING_API_BASE: "https://api.openai.com/v1"  # 嵌入 API 地址
EMBEDDING_MODEL: "text-embedding-3-small"        # 嵌入模型
```

```yaml
# backend-secret.yaml (Secret) — 填入实际 Key
LLM_API_KEY: "sk-your-openai-api-key"
```

### 方式三：Anthropic Claude

**适用场景：** 使用 Claude 系列模型。

```yaml
# backend-config.yaml (ConfigMap)
LLM_PROVIDER: "anthropic"
LLM_API_BASE: "https://api.anthropic.com/v1"
LLM_MODEL: "claude-sonnet-4-6"
```

```yaml
# backend-secret.yaml (Secret) — 填入实际 Key
LLM_API_KEY: "sk-ant-your-anthropic-api-key"
```

### 环境变量完整参考

| 变量名 | 说明 | 示例值 |
|--------|------|--------|
| `LLM_PROVIDER` | LLM 提供商类型 | `ollama` / `openai` / `anthropic` |
| `LLM_API_KEY` | API 密钥（从 Secret 注入） | `sk-xxx` |
| `LLM_API_BASE` | LLM API 地址 | `https://api.openai.com/v1` |
| `LLM_MODEL` | 生成模型名称 | `gpt-4o` / `qwen2.5:7b` |
| `EMBEDDING_API_KEY` | Embedding API 密钥 | `sk-xxx` |
| `EMBEDDING_API_BASE` | Embedding API 地址 | `https://api.openai.com/v1` |
| `EMBEDDING_MODEL` | Embedding 模型名称 | `text-embedding-3-small` |
| `MILVUS_ADDRESS` | Milvus 连接地址 | `milvus.milvus.svc.cluster.local:19530` |
| `OLLAMA_URL` | Ollama 服务地址（仅 Ollama 模式） | `http://10.0.0.1:11434` |
| `OLLAMA_MODEL` | Ollama 生成模型（仅 Ollama 模式） | `qwen2.5:7b` |
| `OLLAMA_EMBEDDING_MODEL` | Ollama 嵌入模型（仅 Ollama 模式） | `nomic-embed-text` |

---

## 知识库管理

知识库文档存放在 `knowledge-base/` 目录下。系统支持 Markdown 格式的文档。

### 自动导入知识到 Milvus

`deploy.sh` 会从 `knowledge-base/*.md` 生成 `rag-knowledge-base` ConfigMap，挂载到后端的 `/knowledge-base`，并在后端就绪后创建 `rag-knowledge-import` Job 调用 `/api/knowledge/import-all`。

如果你更新了知识库文档，可以重新运行部署脚本，或手动重建 ConfigMap 并重跑 Job：

```bash
kubectl create configmap rag-knowledge-base \
  -n rag-app \
  --from-file=knowledge-base \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/rag-backend -n rag-app
kubectl delete job rag-knowledge-import -n rag-app --ignore-not-found=true
kubectl apply -f apps/rag-app/knowledge-import-job.yaml
```

### 手动导入知识到 Milvus

```bash
# 方式一：通过后端 API 导入
curl -X POST http://<backend-ip>:8080/api/knowledge/import \
  -H "Content-Type: application/json" \
  -d '{"path": "/knowledge-base/go-best-practices.md"}'

# 方式二：批量导入目录
curl -X POST http://<backend-ip>:8080/api/knowledge/import-all
```

### 编写知识文档建议

- 使用 Markdown 格式，结构清晰
- 每个文档聚焦一个主题，便于检索
- 使用 `##` 标题分隔不同知识点（后端会按标题分块）
- 单个文档建议不超过 5000 字，过大的文档检索效果会下降

---

## 手动部署（分步操作）

如果不想使用一键部署脚本，可以按以下步骤手动部署：

### 1. 准备存储目录

```bash
# 在 K8s 节点上创建 hostPath 目录
sudo mkdir -p /data/milvus-etcd /data/milvus-minio /data/milvus-standalone
sudo chmod 777 /data/milvus-*
```

### 2. 创建命名空间

```bash
kubectl apply -f apps/milvus/namespace.yaml
kubectl apply -f apps/rag-app/namespace.yaml
```

### 3. 部署 Milvus

```bash
# 通过 Helm 部署 Milvus 独立版
helm repo add milvus https://zilliztech.github.io/milvus-helm/
helm repo update
helm upgrade --install milvus milvus/milvus \
  --namespace milvus \
  --set mode=standalone \
  --set persistence.enabled=true \
  --set persistence.persistentVolumeClaim.etcd.storageClass=manual \
  --set persistence.persistentVolumeClaim.minio.storageClass=manual \
  --set persistence.persistentVolumeClaim.standalone.storageClass=manual

# 创建 PV 资源
kubectl apply -f apps/milvus/pv.yaml
```

### 4. 配置 LLM

```bash
# 编辑 Secret 填入 API Key
vim apps/rag-app/backend-secret.yaml

# 编辑 ConfigMap 选择 LLM 提供商
vim apps/rag-app/backend-config.yaml

# 应用配置
kubectl apply -f apps/rag-app/backend-secret.yaml
kubectl apply -f apps/rag-app/backend-config.yaml
```

### 5. 部署应用

```bash
kubectl apply -f apps/rag-app/backend.yaml
kubectl apply -f apps/rag-app/frontend.yaml
kubectl apply -f apps/rag-app/ingress.yaml
```

### 6. 验证部署

```bash
# 查看 Pod 状态
kubectl get pods -n rag-app
kubectl get pods -n milvus

# 查看后端日志
kubectl logs -f deployment/rag-backend -n rag-app

# 获取前端访问地址
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
NODE_PORT=$(kubectl get svc rag-frontend-svc -n rag-app -o jsonpath='{.spec.ports[0].nodePort}')
echo "访问地址: http://${NODE_IP}:${NODE_PORT}"

# 获取 Ingress 地址（需要 Ingress Controller）
kubectl get ingress -n rag-app
```

### Ingress 和 TLS

仓库提供 `apps/rag-app/ingress.yaml`，默认使用 `rag.127-0-0-1.sslip.io` 作为开发域名并转发到 `rag-frontend-svc:3000`。生产环境请将 host 改为真实域名，并配合 cert-manager 创建 TLS 证书 Secret。

---

## 镜像构建说明

| 镜像 | 说明 | 构建来源 |
|------|------|----------|
| `ghcr.io/bojay576/rag-backend:latest` | RAG 后端（Python/FastAPI） | `apps/rag-app/backend/` |
| `ghcr.io/bojay576/rag-frontend:latest` | RAG 前端（Node.js/Next.js） | `apps/rag-app/frontend/` |

GitHub Actions 会在推送 `main` 后构建并推送 `latest` 和 commit SHA 两类 tag 到 GHCR。K8s 清单默认使用 GHCR 镜像和 `imagePullPolicy: Always`，全新集群无需手动预加载本地镜像。

本地开发或自建镜像时可直接在仓库根目录执行：

```bash
docker build -t rag-backend:v1.0 apps/rag-app/backend
docker build -t rag-frontend:v1.0 apps/rag-app/frontend
```

如果使用本地镜像，请将 `apps/rag-app/backend.yaml` 与 `apps/rag-app/frontend.yaml` 中的 `image` 字段改为本地 tag，并把 `imagePullPolicy` 调整为 `IfNotPresent`。

如果你需要修改镜像拉取策略或添加私有仓库认证：

```bash
# 修改镜像拉取策略为 Always（从远程仓库拉取）
kubectl patch deployment rag-backend -n rag-app -p '{"spec":{"template":{"spec":{"containers":[{"name":"backend","imagePullPolicy":"Always"}]}}}}'
```

如需推送到私有仓库：

```yaml
# 在 backend.yaml 和 frontend.yaml 中修改 image 字段
image: your-registry.example.com/rag-backend:v1.0

# 并添加 imagePullSecrets
imagePullSecrets:
  - name: your-registry-secret
```

---

## 常见问题

### Q: 部署后 Pod 一直 Pending？

```bash
kubectl describe pod <pod-name> -n rag-app
```
常见原因：
- 节点资源不足（CPU/内存不够）
- 镜像拉取失败（检查 `imagePullPolicy` 和镜像是否存在）
- PVC 未绑定（检查 PV 是否创建成功）

### Q: 后端连不上 Milvus？

```bash
# 检查 Milvus 是否运行
kubectl get pods -n milvus

# 测试连通性（从后端 Pod 内）
kubectl exec -it deployment/rag-backend -n rag-app -- curl -s milvus.milvus.svc.cluster.local:19530/healthz
```

### Q: 如何切换 LLM 提供商？

修改 ConfigMap 和 Secret 后，重启后端 Pod：

```bash
kubectl rollout restart deployment/rag-backend -n rag-app
```

### Q: 如何查看 LLM 调用的日志？

```bash
kubectl logs -f deployment/rag-backend -n rag-app | grep -E "LLM|embedding|api_key"
```

### Q: 生产环境需要注意什么？

- ❌ **不要用 hostPath**：改用 NFS / Longhorn / 云存储
- ❌ **不要用 NodePort**：改用 Ingress + TLS
- ✅ **添加资源限制**（resources.requests/limits）
- ✅ **配置网络策略**（NetworkPolicy）
- ✅ **使用 Sealed Secrets 或 External Secrets** 管理敏感信息
- ✅ **配置 ArgoCD / Flux** 实现真正的 GitOps 自动同步
- ✅ **添加 HPA** 实现自动扩缩容
- ✅ **配置持久化日志收集**（Loki/ELK）

---

## 技术栈

| 组件 | 技术 | 说明 |
|------|------|------|
| 容器编排 | Kubernetes | 部署和编排 |
| 向量数据库 | Milvus 2.x (Standalone) | 向量存储与相似性检索 |
| LLM 后端 | Ollama / OpenAI / Anthropic | 可切换的 LLM 提供商 |
| 后端框架 | Python (FastAPI) | RAG 核心逻辑 |
| 前端框架 | Node.js (Next.js/React) | 用户交互界面 |
| 包管理 | Helm | Milvus 部署 |
| 部署方式 | GitOps (kubectl apply) | 声明式部署 |

---

## License

MIT
