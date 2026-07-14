#!/usr/bin/env bash
# =============================================================================
# RAG Agent GitOps — 一键部署脚本
# =============================================================================
# 用途：在全新的 K8s 集群上完成 RAG 知识库系统的完整部署
# 用法：
#   chmod +x deploy.sh && ./deploy.sh
#   ./deploy.sh --with-ollama
#   ./deploy.sh --ollama-url http://192.168.1.100:11434
#   ./deploy.sh --llm-provider openai
#
# 前置条件（详见 README.md）：
#   1. Kubernetes 集群 ≥ 1.25（k3s/kind/minikube 均可）
#   2. kubectl 已安装并连接到集群
#   3. Helm ≥ 3.12 已安装
#   4. 集群节点有足够资源（CPU 4核+ / 内存 16GB+）
#   5. 集群有默认 StorageClass，或本脚本将自动安装 local-path-provisioner
# =============================================================================

set -euo pipefail

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}▶ $*${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ---- 配置 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MILVUS_NAMESPACE="milvus"
APP_NAMESPACE="rag-app"
MILVUS_HELM_RELEASE="milvus"
MILVUS_HELM_REPO="https://zilliztech.github.io/milvus-helm/"
WITH_OLLAMA=true
OLLAMA_URL_OVERRIDE=""
OLLAMA_SERVICE_URL="http://ollama.${APP_NAMESPACE}.svc.cluster.local:11434"
OLLAMA_MODEL_DEFAULT="qwen2.5:7b"
OLLAMA_EMBEDDING_MODEL_DEFAULT="nomic-embed-text"
LLM_PROVIDER=""
LLM_API_BASE=""
LLM_MODEL=""
LLM_API_KEY=""
EMBEDDING_API_BASE=""
EMBEDDING_MODEL=""
EMBEDDING_API_KEY=""
LLM_MODE_EXPLICIT=false
SKIP_OLLAMA_REQUESTED=false
REGISTRY_MIRROR=""
CONFIG_FILE="${SCRIPT_DIR}/.rag-deploy-config"
MILVUS_HELM_VALUES=(
  --set cluster.enabled=false
  --set streaming.enabled=false
  --set pulsarv3.enabled=false
  --set pulsar.enabled=false
  --set kafka.enabled=false
  --set woodpecker.enabled=false
  --set standalone.messageQueue=rocksmq
  --set minio.mode=standalone
  --set minio.replicas=1
  --set minio.image.repository=swr.cn-north-4.myhuaweicloud.com/ddn-k8s/quay.io/minio/minio
  --set minio.image.tag=RELEASE.2025-07-23T15-54-02Z
  --set minio.persistence.size=20Gi
  --set minio.securityContext.runAsUser=0
  --set minio.securityContext.runAsGroup=0
  --set minio.securityContext.fsGroup=0
  --set image.all.repository=swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/milvusdb/milvus
  --set image.all.tag=v2.6.20
  --set etcd.image.registry=swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io
  --set etcd.image.repository=milvusdb/etcd
  --set etcd.image.tag=3.5.25-r1
  --set etcd.replicaCount=1
  --set standalone.persistence.persistentVolumeClaim.size=20Gi
)

usage() {
  cat <<EOF
用法: ./deploy.sh [选项]

选项:
  --with-ollama             在 rag-app 命名空间内部署 Ollama，并自动配置后端使用集群内 Service（默认）
  --no-ollama               不部署 Ollama，交互式选择云端 API 或配合 --llm-provider 使用
  --ollama-url URL          使用外部 Ollama 地址，例如 http://192.168.1.100:11434
  --llm-provider PROVIDER   LLM 提供商: ollama | openai | anthropic
  --llm-api-base URL        云端 LLM API Base，例如 https://api.openai.com/v1
  --llm-model MODEL         云端 LLM 模型名称
  --llm-api-key KEY         云端 LLM API Key
  --embedding-api-base URL  Embedding API Base
  --embedding-model MODEL   Embedding 模型名称
  --embedding-api-key KEY   Embedding API Key（默认复用 LLM API Key）
  --registry-mirror URL     Docker Hub 镜像加速器地址，例如 https://dockerhub.azk8s.cn
  -h, --help                显示帮助

示例:
  ./deploy.sh
  ./deploy.sh --with-ollama
  ./deploy.sh --ollama-url http://192.168.1.100:11434
  ./deploy.sh --llm-provider openai
  ./deploy.sh --llm-provider openai --llm-api-base https://api.openai.com/v1 --llm-model gpt-4o
  ./deploy.sh --registry-mirror https://dockerhub.azk8s.cn
EOF
}

require_arg() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" ]]; then
    log_error "${option} 需要提供参数值"
    usage
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-ollama)
        WITH_OLLAMA=true
        LLM_PROVIDER="ollama"
        LLM_MODE_EXPLICIT=true
        shift
        ;;
      --no-ollama)
        WITH_OLLAMA=false
        SKIP_OLLAMA_REQUESTED=true
        shift
        ;;
      --ollama-url)
        require_arg "$1" "${2:-}"
        OLLAMA_URL_OVERRIDE="$2"
        WITH_OLLAMA=false
        LLM_PROVIDER="ollama"
        LLM_MODE_EXPLICIT=true
        shift 2
        ;;
      --llm-provider)
        require_arg "$1" "${2:-}"
        LLM_PROVIDER="$2"
        LLM_MODE_EXPLICIT=true
        if [[ "$LLM_PROVIDER" != "ollama" ]]; then
          WITH_OLLAMA=false
        fi
        shift 2
        ;;
      --llm-api-base)
        require_arg "$1" "${2:-}"
        LLM_API_BASE="${2:-}"
        LLM_MODE_EXPLICIT=true
        shift 2
        ;;
      --llm-model)
        require_arg "$1" "${2:-}"
        LLM_MODEL="${2:-}"
        LLM_MODE_EXPLICIT=true
        shift 2
        ;;
      --llm-api-key)
        require_arg "$1" "${2:-}"
        LLM_API_KEY="${2:-}"
        LLM_MODE_EXPLICIT=true
        shift 2
        ;;
      --embedding-api-base)
        require_arg "$1" "${2:-}"
        EMBEDDING_API_BASE="${2:-}"
        LLM_MODE_EXPLICIT=true
        shift 2
        ;;
      --embedding-model)
        require_arg "$1" "${2:-}"
        EMBEDDING_MODEL="${2:-}"
        LLM_MODE_EXPLICIT=true
        shift 2
        ;;
      --embedding-api-key)
        require_arg "$1" "${2:-}"
        EMBEDDING_API_KEY="${2:-}"
        LLM_MODE_EXPLICIT=true
        shift 2
        ;;
      --registry-mirror)
        require_arg "$1" "${2:-}"
        REGISTRY_MIRROR="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$SKIP_OLLAMA_REQUESTED" == true && "$LLM_MODE_EXPLICIT" != true && ! -t 0 ]]; then
    log_error "非交互式使用 --no-ollama 时，请同时提供 --llm-provider openai|anthropic 以及 API 参数。"
    exit 1
  fi

  case "$LLM_PROVIDER" in
    ""|ollama|openai|anthropic)
      ;;
    *)
      log_error "不支持的 LLM_PROVIDER: $LLM_PROVIDER"
      exit 1
      ;;
  esac

  if [[ "$SKIP_OLLAMA_REQUESTED" == true && "$LLM_PROVIDER" == "ollama" ]]; then
    log_error "--no-ollama 不能和 Ollama 模式同时使用，请选择 --llm-provider openai|anthropic。"
    exit 1
  fi

}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "${prompt} [${default}]: " value
  echo "${value:-$default}"
}

prompt_secret() {
  local prompt="$1"
  local value

  read -r -s -p "$prompt" value
  echo "" >&2
  echo "$value"
}

configure_ollama_mode() {
  LLM_PROVIDER="ollama"
  LLM_API_BASE=""
  LLM_MODEL=""
  LLM_API_KEY=""
  EMBEDDING_API_BASE=""
  EMBEDDING_MODEL=""
  EMBEDDING_API_KEY=""
}

configure_api_defaults() {
  if [[ "$LLM_PROVIDER" == "openai" ]]; then
    LLM_API_BASE="${LLM_API_BASE:-https://api.openai.com/v1}"
    LLM_MODEL="${LLM_MODEL:-gpt-4o}"
    EMBEDDING_API_BASE="${EMBEDDING_API_BASE:-$LLM_API_BASE}"
    EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"
  elif [[ "$LLM_PROVIDER" == "anthropic" ]]; then
    LLM_API_BASE="${LLM_API_BASE:-https://api.anthropic.com/v1}"
    LLM_MODEL="${LLM_MODEL:-claude-sonnet-4-6}"
    EMBEDDING_API_BASE="${EMBEDDING_API_BASE:-https://api.openai.com/v1}"
    EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"
  fi

}

configure_embedding_key_default() {
  if [[ "$LLM_PROVIDER" == "openai" ]]; then
    EMBEDDING_API_KEY="${EMBEDDING_API_KEY:-$LLM_API_KEY}"
  fi
}

validate_llm_mode() {
  case "$LLM_PROVIDER" in
    ollama|openai|anthropic)
      ;;
    *)
      log_error "不支持的 LLM_PROVIDER: $LLM_PROVIDER"
      exit 1
      ;;
  esac

  if [[ "$LLM_PROVIDER" == "ollama" && "$WITH_OLLAMA" != true && -z "$OLLAMA_URL_OVERRIDE" ]]; then
    log_error "Ollama 模式需要使用 --with-ollama 部署集群内 Ollama，或使用 --ollama-url 指定外部 Ollama 地址。"
    exit 1
  fi

  if [[ "$LLM_PROVIDER" != "ollama" ]]; then
    if [[ -z "$LLM_API_BASE" || -z "$LLM_MODEL" ]]; then
      log_error "云端 API 模式需要 LLM API Base 和模型名称。"
      exit 1
    fi
    if [[ -z "$EMBEDDING_API_BASE" || -z "$EMBEDDING_MODEL" ]]; then
      log_error "云端 API 模式需要 Embedding API Base 和模型名称。"
      exit 1
    fi
  fi
}

ensure_ingress_controller() {
  local ingress_classes="$1"
  local current_context

  if [[ -n "$ingress_classes" ]]; then
    log_info "✓ 检测到 IngressClass: $ingress_classes"
    return
  fi

  current_context="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$current_context" == minikube* ]]; then
    if ! command -v minikube &>/dev/null; then
      log_warn "当前是 minikube 集群，但未找到 minikube 命令；请手动执行：minikube addons enable ingress"
      return
    fi

    log_warn "未检测到 IngressClass，正在为 minikube 启用 ingress addon..."
    if minikube addons enable ingress; then
      kubectl wait --for=condition=available deployment/ingress-nginx-controller \
        -n ingress-nginx \
        --timeout=180s 2>/dev/null || {
        log_warn "ingress-nginx-controller 尚未就绪，请稍后检查：kubectl get pods -n ingress-nginx"
      }
      ingress_classes=$(kubectl get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || echo "")
      if [[ -n "$ingress_classes" ]]; then
        log_info "✓ 检测到 IngressClass: $ingress_classes"
      else
        log_warn "minikube ingress addon 已启用，但暂未检测到 IngressClass。"
      fi
    else
      log_warn "自动启用 minikube ingress addon 失败，请手动执行：minikube addons enable ingress"
    fi
    return
  fi

  log_warn "未检测到 IngressClass。Ingress 清单会被应用，但需要先安装 nginx-ingress、Traefik 等 Controller 才能访问域名入口。"
}

is_minikube_context() {
  local current_context

  current_context="$(kubectl config current-context 2>/dev/null || true)"
  [[ "$current_context" == minikube* ]]
}

update_helm_repo() {
  local repo_name="$1"
  local chart_ref="$2"
  local attempt

  for attempt in 1 2 3; do
    if helm repo update "$repo_name"; then
      return
    fi
    log_warn "Helm 仓库更新失败（第 ${attempt}/3 次），稍后重试..."
    sleep "$((attempt * 3))"
  done

  if helm show chart "$chart_ref" &>/dev/null; then
    log_warn "Helm 仓库更新失败，但本地已有可用 chart 缓存，继续部署。"
    return
  fi

  log_error "无法更新 Helm 仓库，且本地没有可用 chart 缓存：$chart_ref"
  exit 1
}

reset_failed_milvus_release() {
  log_warn "检测到 Milvus release 处于失败/挂起状态，将清理后重新安装。"

  if kubectl get namespace "$MILVUS_NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    log_warn "Milvus 命名空间正在删除中，等待删除完成..."
    if ! kubectl wait --for=delete namespace/"$MILVUS_NAMESPACE" --timeout=180s 2>/dev/null; then
      log_error "Milvus 命名空间仍处于 Terminating。"
      log_error "请手动执行: kubectl delete namespace ${MILVUS_NAMESPACE} --force --grace-period=0"
      return 1
    fi
  fi

  log_info "清理 Milvus 残留资源..."
  helm uninstall "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" --ignore-not-found || true
  kubectl delete all,job,pvc,configmap,secret -n "$MILVUS_NAMESPACE" \
    -l app.kubernetes.io/instance="$MILVUS_HELM_RELEASE" \
    --ignore-not-found --wait=true --timeout=180s || true
  kubectl delete pvc -n "$MILVUS_NAMESPACE" --all --ignore-not-found --wait=true --timeout=180s || true

  # 重新创建命名空间
  kubectl apply -f "${SCRIPT_DIR}/apps/milvus/namespace.yaml"
  return 0
}

choose_llm_mode() {
  # 检测是否已有部署配置 → 跳过 LLM 选择，复用已有配置
  if kubectl get configmap rag-backend-config -n "$APP_NAMESPACE" &>/dev/null 2>&1 && \
     kubectl get secret rag-backend-secret -n "$APP_NAMESPACE" &>/dev/null 2>&1; then
    log_info "检测到已有部署配置（ConfigMap + Secret），跳过 LLM 模式选择。"
    echo ""
    return
  fi

  # 本地配置文件存在且未传新参数 → 恢复配置到 K8s，跳过交互
  if [[ "$LLM_MODE_EXPLICIT" != true && -f "$CONFIG_FILE" ]]; then
    log_info "检测到本地配置缓存（${CONFIG_FILE}），自动恢复..."
    if restore_local_config; then
      log_info "✓ 配置已恢复。如需重新配置请执行: rm -f ${CONFIG_FILE}"
      echo ""
      return
    else
      log_warn "本地配置恢复失败，将重新配置。"
    fi
  fi

  log_step "步骤 4/9：选择 LLM 模式"

  if [[ "$LLM_MODE_EXPLICIT" == true ]]; then
    if [[ -z "$LLM_PROVIDER" ]]; then
      LLM_PROVIDER="openai"
    fi
    if [[ "$LLM_PROVIDER" == "ollama" ]]; then
      configure_ollama_mode
    else
      configure_api_defaults
      if [[ -t 0 ]]; then
        LLM_API_BASE="$(prompt_with_default "  LLM API Base" "$LLM_API_BASE")"
        LLM_MODEL="$(prompt_with_default "  LLM 模型名称" "$LLM_MODEL")"
        if [[ -z "$LLM_API_KEY" ]]; then
          LLM_API_KEY="$(prompt_secret "  LLM API Key: ")"
        fi
        EMBEDDING_API_BASE="$(prompt_with_default "  Embedding API Base" "$EMBEDDING_API_BASE")"
        EMBEDDING_MODEL="$(prompt_with_default "  Embedding 模型名称" "$EMBEDDING_MODEL")"
        if [[ -z "$EMBEDDING_API_KEY" ]]; then
          if [[ "$LLM_PROVIDER" == "openai" ]]; then
            EMBEDDING_API_KEY="$(prompt_secret "  Embedding API Key（留空则复用 LLM API Key）: ")"
          else
            EMBEDDING_API_KEY="$(prompt_secret "  Embedding API Key: ")"
          fi
        fi
        configure_api_defaults
        configure_embedding_key_default
      elif [[ -z "$LLM_API_KEY" ]]; then
        log_warn "未提供 LLM API Key，将以无认证模式运行。"
      fi
      configure_embedding_key_default
    fi
    validate_llm_mode
    log_info "LLM 模式: $LLM_PROVIDER"
    echo ""
    return
  fi

  if [[ ! -t 0 ]]; then
    if [[ "$SKIP_OLLAMA_REQUESTED" == true ]]; then
      log_error "非交互式使用 --no-ollama 时，请同时提供 --llm-provider openai|anthropic 以及 API 参数。"
      exit 1
    fi
    log_warn "当前不是交互式终端，默认使用集群内 Ollama。"
    WITH_OLLAMA=true
    configure_ollama_mode
    echo ""
    return
  fi

  local default_choice="1"
  echo "  请选择 RAG 后端使用的 LLM 模式:"
  if [[ "$SKIP_OLLAMA_REQUESTED" == true ]]; then
    default_choice="3"
    echo "    --no-ollama 已启用，本次不会部署集群内 Ollama。"
  else
    echo "    [1] 集群内 Ollama（默认，无需 API Key）"
    echo "    [2] 外部 Ollama（输入已有 Ollama URL）"
  fi
  echo "    [3] OpenAI 兼容 API（输入 Base URL / Model / API Key）"
  echo "    [4] Anthropic Claude（输入 Base URL / Model / API Key，并配置 Embedding API）"
  echo ""

  local mode_choice
  read -r -p "  请选择 [1-4] (默认 ${default_choice}): " mode_choice
  mode_choice="${mode_choice:-$default_choice}"

  case "$mode_choice" in
    1)
      if [[ "$SKIP_OLLAMA_REQUESTED" == true ]]; then
        log_error "--no-ollama 已启用，不能选择集群内 Ollama。"
        exit 1
      fi
      WITH_OLLAMA=true
      configure_ollama_mode
      log_info "模式: 集群内 Ollama (${OLLAMA_MODEL_DEFAULT})"
      ;;
    2)
      if [[ "$SKIP_OLLAMA_REQUESTED" == true ]]; then
        log_error "--no-ollama 已启用，不能选择 Ollama 模式。"
        exit 1
      fi
      WITH_OLLAMA=false
      configure_ollama_mode
      OLLAMA_URL_OVERRIDE="$(prompt_with_default "  Ollama URL" "http://192.168.1.100:11434")"
      log_info "模式: 外部 Ollama (${OLLAMA_URL_OVERRIDE})"
      ;;
    3)
      WITH_OLLAMA=false
      LLM_PROVIDER="openai"
      LLM_API_BASE="$(prompt_with_default "  LLM API Base" "https://api.openai.com/v1")"
      LLM_MODEL="$(prompt_with_default "  LLM 模型名称" "gpt-4o")"
      LLM_API_KEY="$(prompt_secret "  LLM API Key: ")"
      EMBEDDING_API_BASE="$(prompt_with_default "  Embedding API Base" "$LLM_API_BASE")"
      EMBEDDING_MODEL="$(prompt_with_default "  Embedding 模型名称" "text-embedding-3-small")"
      EMBEDDING_API_KEY="$(prompt_secret "  Embedding API Key（留空则复用 LLM API Key）: ")"
      configure_api_defaults
      configure_embedding_key_default
      log_info "模式: OpenAI 兼容 API (${LLM_MODEL} @ ${LLM_API_BASE})"
      ;;
    4)
      WITH_OLLAMA=false
      LLM_PROVIDER="anthropic"
      LLM_API_BASE="$(prompt_with_default "  Anthropic API Base" "https://api.anthropic.com/v1")"
      LLM_MODEL="$(prompt_with_default "  Claude 模型名称" "claude-sonnet-4-6")"
      LLM_API_KEY="$(prompt_secret "  Anthropic API Key: ")"
      EMBEDDING_API_BASE="$(prompt_with_default "  Embedding API Base" "https://api.openai.com/v1")"
      EMBEDDING_MODEL="$(prompt_with_default "  Embedding 模型名称" "text-embedding-3-small")"
      EMBEDDING_API_KEY="$(prompt_secret "  Embedding API Key: ")"
      configure_api_defaults
      configure_embedding_key_default
      log_info "模式: Anthropic (${LLM_MODEL} @ ${LLM_API_BASE})"
      ;;
    *)
      log_error "无效选择: $mode_choice"
      exit 1
      ;;
  esac

  validate_llm_mode

  # 立即保存 LLM 配置，后续步骤即使失败重跑也能跳过此步
  save_llm_config

  echo ""
}

# ---- 保存 LLM 配置到 K8s ConfigMap 和 Secret（在用户选择完后立即写入） ----
save_llm_config() {
  # 检测是否已有保存（符合预期则不会触发此函数，但防御性检查）
  if kubectl get configmap rag-backend-config -n "$APP_NAMESPACE" &>/dev/null 2>&1 && \
     kubectl get secret rag-backend-secret -n "$APP_NAMESPACE" &>/dev/null 2>&1; then
    return
  fi

  # 确保命名空间存在
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/namespace.yaml" &>/dev/null || true

  log_info "保存 LLM 配置到 ConfigMap 和 Secret..."

  local ollama_url=""
  local ollama_model=""
  local ollama_embedding_model=""

  if [[ "$WITH_OLLAMA" == true ]]; then
    ollama_url="$OLLAMA_SERVICE_URL"
    ollama_model="$OLLAMA_MODEL_DEFAULT"
    ollama_embedding_model="$OLLAMA_EMBEDDING_MODEL_DEFAULT"
  elif [[ -n "$OLLAMA_URL_OVERRIDE" ]]; then
    ollama_url="$OLLAMA_URL_OVERRIDE"
    ollama_model="$OLLAMA_MODEL_DEFAULT"
    ollama_embedding_model="$OLLAMA_EMBEDDING_MODEL_DEFAULT"
  elif [[ "$LLM_PROVIDER" == "ollama" ]]; then
    log_warn "未部署 Ollama；请使用 --ollama-url 指定外部 Ollama，或选择集群内 Ollama 模式。"
  else
    log_info "配置后端使用云端 API: ${LLM_PROVIDER} (${LLM_MODEL} @ ${LLM_API_BASE})"
  fi

  kubectl create configmap rag-backend-config \
    -n "$APP_NAMESPACE" \
    --from-literal=LLM_PROVIDER="$LLM_PROVIDER" \
    --from-literal=OLLAMA_URL="$ollama_url" \
    --from-literal=OLLAMA_MODEL="$ollama_model" \
    --from-literal=OLLAMA_EMBEDDING_MODEL="$ollama_embedding_model" \
    --from-literal=MILVUS_ADDRESS="milvus.${MILVUS_NAMESPACE}.svc.cluster.local:19530" \
    --from-literal=LLM_API_BASE="$LLM_API_BASE" \
    --from-literal=LLM_MODEL="$LLM_MODEL" \
    --from-literal=EMBEDDING_API_BASE="$EMBEDDING_API_BASE" \
    --from-literal=EMBEDDING_MODEL="$EMBEDDING_MODEL" \
    --from-literal=RETRIEVAL_TOP_K="5" \
    --from-literal=RETRIEVAL_SCORE_THRESHOLD="0.5" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic rag-backend-secret \
    -n "$APP_NAMESPACE" \
    --from-literal=LLM_API_KEY="$LLM_API_KEY" \
    --from-literal=EMBEDDING_API_KEY="$EMBEDDING_API_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  # 同时保存到本地文件（即使命名空间被删除也能恢复）
  cat > "$CONFIG_FILE" <<EOF
# RAG Agent GitOps — LLM 部署配置缓存（自动生成，请勿手动修改）
# 如需重新配置请执行：rm -f ${CONFIG_FILE}
LLM_PROVIDER=${LLM_PROVIDER}
WITH_OLLAMA=${WITH_OLLAMA}
OLLAMA_URL=${ollama_url}
OLLAMA_MODEL=${ollama_model}
OLLAMA_EMBEDDING_MODEL=${ollama_embedding_model}
LLM_API_BASE=${LLM_API_BASE}
LLM_MODEL=${LLM_MODEL}
EMBEDDING_API_BASE=${EMBEDDING_API_BASE}
EMBEDDING_MODEL=${EMBEDDING_MODEL}
EOF
  # Secret 内容单独存，权限 600
  cat > "${CONFIG_FILE}.secret" <<EOF
LLM_API_KEY=${LLM_API_KEY}
EMBEDDING_API_KEY=${EMBEDDING_API_KEY}
EOF
  chmod 600 "${CONFIG_FILE}.secret"

  log_info "✓ LLM 配置已保存"
}

# ---- 从本地配置文件恢复 LLM 配置到 K8s ----
restore_local_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 1
  fi

  # 确保命名空间存在
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/namespace.yaml" &>/dev/null || true

  # source 配置文件自动加载变量
  local ollama_url="" ollama_model="" ollama_embedding_model=""
  local llm_provider="" with_ollama=""
  local llm_api_base="" llm_model="" embedding_api_base="" embedding_model=""
  local llm_api_key="" embedding_api_key=""

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    case "$key" in
      LLM_PROVIDER)    llm_provider="$value" ;;
      WITH_OLLAMA)     with_ollama="$value" ;;
      OLLAMA_URL)      ollama_url="$value" ;;
      OLLAMA_MODEL)    ollama_model="$value" ;;
      OLLAMA_EMBEDDING_MODEL) ollama_embedding_model="$value" ;;
      LLM_API_BASE)    llm_api_base="$value" ;;
      LLM_MODEL)       llm_model="$value" ;;
      EMBEDDING_API_BASE) embedding_api_base="$value" ;;
      EMBEDDING_MODEL) embedding_model="$value" ;;
    esac
  done < "$CONFIG_FILE"

  # 读取 Secret 文件
  if [[ -f "${CONFIG_FILE}.secret" ]]; then
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
      [[ -z "$key" || "$key" =~ ^# ]] && continue
      case "$key" in
        LLM_API_KEY)       llm_api_key="$value" ;;
        EMBEDDING_API_KEY) embedding_api_key="$value" ;;
      esac
    done < "${CONFIG_FILE}.secret"
  fi

  kubectl create configmap rag-backend-config \
    -n "$APP_NAMESPACE" \
    --from-literal=LLM_PROVIDER="$llm_provider" \
    --from-literal=OLLAMA_URL="$ollama_url" \
    --from-literal=OLLAMA_MODEL="$ollama_model" \
    --from-literal=OLLAMA_EMBEDDING_MODEL="$ollama_embedding_model" \
    --from-literal=MILVUS_ADDRESS="milvus.${MILVUS_NAMESPACE}.svc.cluster.local:19530" \
    --from-literal=LLM_API_BASE="$llm_api_base" \
    --from-literal=LLM_MODEL="$llm_model" \
    --from-literal=EMBEDDING_API_BASE="$embedding_api_base" \
    --from-literal=EMBEDDING_MODEL="$embedding_model" \
    --from-literal=RETRIEVAL_TOP_K="5" \
    --from-literal=RETRIEVAL_SCORE_THRESHOLD="0.5" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic rag-backend-secret \
    -n "$APP_NAMESPACE" \
    --from-literal=LLM_API_KEY="$llm_api_key" \
    --from-literal=EMBEDDING_API_KEY="$embedding_api_key" \
    --dry-run=client -o yaml | kubectl apply -f -

  # 把配置恢复到全局变量，后续步骤如 deploy_ollama 等需要
  LLM_PROVIDER="$llm_provider"
  WITH_OLLAMA="${with_ollama:-true}"
  OLLAMA_URL_OVERRIDE="$ollama_url"
  LLM_API_BASE="$llm_api_base"
  LLM_MODEL="$llm_model"
  LLM_API_KEY="$llm_api_key"
  EMBEDDING_API_BASE="$embedding_api_base"
  EMBEDDING_MODEL="$embedding_model"
  EMBEDDING_API_KEY="$embedding_api_key"
}

# ---- 配置 Docker Hub 镜像加速器（k3s） ----
setup_registry_mirror() {
  if [[ -z "$REGISTRY_MIRROR" ]]; then
    return
  fi

  # k3s 使用 containerd，镜像加速器配置在 /etc/rancher/k3s/registries.yaml
  if [[ ! -f /etc/rancher/k3s/registries.yaml ]] || ! grep -q "$REGISTRY_MIRROR" /etc/rancher/k3s/registries.yaml 2>/dev/null; then
    log_info "配置 k3s containerd 镜像加速器: ${REGISTRY_MIRROR}"
    cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  docker.io:
    endpoint:
      - "${REGISTRY_MIRROR}"
EOF
    log_info "重启 k3s 使镜像加速器生效..."
    systemctl restart k3s 2>/dev/null || service k3s restart 2>/dev/null || true
    sleep 3
    log_info "✓ 镜像加速器已配置"
  else
    log_info "✓ 镜像加速器已配置: ${REGISTRY_MIRROR}"
  fi
  echo ""
}

# ---- 步骤 1：前置条件检查 ----
check_prerequisites() {
  log_step "步骤 1/9：检查前置条件"

  # 检查 kubectl
  if ! command -v kubectl &>/dev/null; then
    log_error "未找到 kubectl，请先安装：https://kubernetes.io/docs/tasks/tools/"
    exit 1
  fi
  log_info "✓ kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client -o json | grep -o '"gitVersion":"[^"]*"' | head -1)"

  # 检查集群连接
  if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到 Kubernetes 集群，请检查 kubeconfig 配置"
    log_error "运行 'kubectl cluster-info' 查看详细错误"
    exit 1
  fi
  log_info "✓ 集群连接正常"

  # 检查集群节点状态
  NODES_OUTPUT=$(kubectl get nodes --no-headers 2>/dev/null || true)
  NOT_READY=$(printf '%s\n' "$NODES_OUTPUT" | awk 'NF && $2 !~ /(^|,)Ready(,|$)/ { count++ } END { print count + 0 }')
  if [[ "$NOT_READY" -gt 0 ]]; then
    log_warn "有 $NOT_READY 个节点未就绪，部署可能失败"
    kubectl get nodes
  else
    NODE_COUNT=$(printf '%s\n' "$NODES_OUTPUT" | awk 'NF { count++ } END { print count + 0 }')
    log_info "✓ 集群节点数: ${NODE_COUNT}（全部就绪）"
  fi

  # 检查 Helm
  if ! command -v helm &>/dev/null; then
    log_error "未找到 Helm，请先安装：https://helm.sh/docs/intro/install/"
    exit 1
  fi
  log_info "✓ Helm: $(helm version --short 2>/dev/null | head -1)"

  # 检查集群资源
  log_info "集群资源概况："
  kubectl describe nodes 2>/dev/null | grep -A5 "Allocated resources:" | head -6 || true

  if kubectl get ingressclass &>/dev/null; then
    INGRESS_CLASSES=$(kubectl get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || echo "")
    ensure_ingress_controller "$INGRESS_CLASSES"
  else
    log_warn "当前集群不支持或无法查询 IngressClass，请确认已安装 Ingress Controller。"
  fi

  echo ""
}

# ---- 步骤 3：准备存储 ----
prepare_storage() {
  log_step "步骤 2/9：检查存储配置"

  # 检查是否有默认 StorageClass
  DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$DEFAULT_SC" ]]; then
    log_info "✓ 检测到默认 StorageClass: $DEFAULT_SC"
    log_info "  Milvus 将自动通过 PVC 动态申请存储，无需手动创建 PV"
  else
    log_warn "未检测到默认 StorageClass，正在安装 local-path-provisioner..."
    log_info "  local-path-provisioner 会在节点上使用 hostPath 动态创建 PV"

    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
    kubectl wait --for=condition=available deployment/local-path-provisioner -n local-path-storage --timeout=120s

    # 设为默认 StorageClass
    kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    log_info "✓ local-path-provisioner 安装完成，已设为默认 StorageClass"
  fi

  echo ""
}

# ---- 步骤 4：创建命名空间 ----
create_namespaces() {
  log_step "步骤 3/9：创建命名空间"

  kubectl apply -f "${SCRIPT_DIR}/apps/milvus/namespace.yaml"
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/namespace.yaml"

  log_info "✓ 命名空间 $MILVUS_NAMESPACE 和 $APP_NAMESPACE 已创建"
  echo ""
}

# ---- 步骤 5：部署 Milvus ----
deploy_milvus() {
  log_step "步骤 5/9：部署 Milvus 向量数据库（通过 Helm）"
  local release_exists=false
  local release_status=""
  local chart_cache="${SCRIPT_DIR}/.milvus-chart"

  # 添加 Helm 仓库
  if ! helm repo list 2>/dev/null | grep -q "milvus"; then
    log_info "添加 Milvus Helm 仓库..."
    helm repo add milvus "$MILVUS_HELM_REPO"
  fi
  log_info "更新 Helm 仓库..."
  update_helm_repo milvus milvus/milvus

  # 检查是否已安装
  if helm status "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" &>/dev/null; then
    release_exists=true
    release_status=$(helm status "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" 2>/dev/null | awk '/^STATUS:/ { status = $2 } END { print status }')
  fi

  if [[ "$release_exists" == true && "$release_status" =~ ^(failed|pending-) ]]; then
    log_warn "Milvus release 状态为 ${release_status}，自动清理后重新安装..."
    if reset_failed_milvus_release; then
      release_exists=false
    else
      log_warn "自动清理失败，再次尝试强制清理..."
      kubectl delete namespace "$MILVUS_NAMESPACE" --force --grace-period=0 --ignore-not-found 2>/dev/null || true
      sleep 5
      kubectl apply -f "${SCRIPT_DIR}/apps/milvus/namespace.yaml"
      release_exists=false
    fi
  fi

  # 下载或查找本地 chart
  local chart_ref="milvus/milvus"
  local chart_version
  chart_version=$(helm show chart milvus/milvus 2>/dev/null | grep '^version:' | awk '{print $2}' | head -1 || echo "")
  if [[ -z "$chart_version" ]]; then
    chart_version="5.0.24"
  fi

  # 检查本地是否已有缓存的 chart
  if [[ -d "${chart_cache}/milvus" ]]; then
    log_info "使用本地理化 chart（${chart_cache}/milvus）..."
    chart_ref="${chart_cache}/milvus"
  else
    log_info "尝试下载 Milvus chart 到本地..."
    local pull_ok=false
    for attempt in 1 2 3; do
      if helm pull milvus/milvus --untar --destination "$chart_cache" 2>/dev/null; then
        pull_ok=true
        chart_ref="${chart_cache}/milvus"
        log_info "✓ Chart 下载成功，从本地安装..."
        break
      fi
      log_warn "Helm pull 失败（第 ${attempt}/3 次）..."
      sleep 2
    done

    # 如果 helm pull 失败（国内 GitHub Release 下载慢/被墙），尝试通过 GH 代理下载
    if [[ "$pull_ok" != true ]]; then
      log_warn "Helm pull 失败，尝试通过 GitHub mirror 代理下载 chart..."
      local tgz_url="https://github.com/zilliztech/milvus-helm/releases/download/milvus-${chart_version}/milvus-${chart_version}.tgz"
      local tgz_file="${chart_cache}/milvus-${chart_version}.tgz"
      mkdir -p "$chart_cache"

      # 尝试多个 GitHub mirror 代理
      for mirror in \
        "https://ghproxy.com/${tgz_url}" \
        "https://github.moeyy.xyz/${tgz_url}" \
        "https://gh.api.99988866.xyz/${tgz_url}" \
        "${tgz_url}"; do
        log_info "  尝试: ${mirror}"
        if curl -fsSL --connect-timeout 10 --max-time 120 "$mirror" -o "$tgz_file" 2>/dev/null; then
          log_info "  ✓ 下载成功，解压 chart..."
          rm -rf "${chart_cache}/milvus" 2>/dev/null || true
          mkdir -p "${chart_cache}/milvus"
          tar -xzf "$tgz_file" -C "${chart_cache}/milvus" --strip-components=1 2>/dev/null && {
            pull_ok=true
            chart_ref="${chart_cache}/milvus"
            break
          }
        fi
      done
    fi

    if [[ "$pull_ok" != true ]]; then
      log_warn "无法下载 Milvus chart，尝试从 Helm 本地缓存中查找..."
      local helm_cache_dir
      helm_cache_dir=$(helm env HELM_CACHE 2>/dev/null || echo ~/.cache/helm/repository)
      local cached_chart
      cached_chart=$(find "$helm_cache_dir" -name "milvus-*.tgz" 2>/dev/null | head -1 || true)
      if [[ -n "$cached_chart" ]]; then
        log_info "找到本地缓存 chart: ${cached_chart}"
        chart_ref="$cached_chart"
        pull_ok=true
      fi
    fi

    if [[ "$pull_ok" != true ]]; then
      log_error "无法获取 Milvus Helm chart，请手动下载并放置到 ${chart_cache}/ 目录"
      log_error "下载地址: https://github.com/zilliztech/milvus-helm/releases/tag/milvus-${chart_version}"
      exit 1
    fi
  fi

  if [[ "$release_exists" == true ]]; then
    log_warn "Milvus 已安装，执行更新..."
    helm upgrade "$MILVUS_HELM_RELEASE" "$chart_ref" \
      --namespace "$MILVUS_NAMESPACE" \
      --reset-values \
      "${MILVUS_HELM_VALUES[@]}" \
      --wait \
      --timeout 10m
  else
    log_info "安装 Milvus Standalone..."
    helm install "$MILVUS_HELM_RELEASE" "$chart_ref" \
      --namespace "$MILVUS_NAMESPACE" \
      --create-namespace \
      "${MILVUS_HELM_VALUES[@]}" \
      --wait \
      --timeout 10m
  fi

  log_info "✓ Milvus 部署完成"
  echo ""
}

# ---- 步骤 6：创建知识库 ConfigMap ----
create_knowledge_base_config() {
  log_step "步骤 6/9：创建知识库 ConfigMap"

  if compgen -G "${SCRIPT_DIR}/knowledge-base/*.md" > /dev/null; then
    kubectl create configmap rag-knowledge-base \
      -n "$APP_NAMESPACE" \
      --from-file="${SCRIPT_DIR}/knowledge-base" \
      --dry-run=client -o yaml | kubectl apply -f -
    log_info "✓ 知识库 ConfigMap 已创建"
  else
    log_warn "未找到 knowledge-base/*.md，跳过知识库 ConfigMap"
  fi

  echo ""
}

# ---- 步骤 7：部署 Ollama（可选） ----
deploy_ollama() {
  if [[ "$WITH_OLLAMA" != true ]]; then
    return
  fi

  # 检测是否已部署
  if kubectl get deployment ollama -n "$APP_NAMESPACE" &>/dev/null 2>&1; then
    log_info "Ollama 已部署，跳过。"
    echo ""
    return
  fi

  log_step "步骤 7/9：部署 Ollama（可选）"

  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/ollama.yaml"
  log_info "等待 Ollama Pod 就绪..."
  kubectl wait --for=condition=available deployment/ollama \
    -n "$APP_NAMESPACE" \
    --timeout=300s 2>/dev/null || {
      log_warn "Ollama 等待超时，请手动检查："
      kubectl get pods -n "$APP_NAMESPACE" -l app=ollama
    }

  log_warn "Ollama 镜像不预装模型。首次使用前请进入 Pod 执行："
  log_warn "  kubectl exec -n ${APP_NAMESPACE} deployment/ollama -- ollama pull ${OLLAMA_MODEL_DEFAULT}"
  log_warn "  kubectl exec -n ${APP_NAMESPACE} deployment/ollama -- ollama pull ${OLLAMA_EMBEDDING_MODEL_DEFAULT}"
  echo ""
}

check_ollama_ready_for_import() {
  if [[ "$WITH_OLLAMA" != true ]]; then
    return
  fi

  log_info "检查 Ollama API 和 Embedding 模型是否可用..."
  kubectl delete pod ollama-healthcheck -n "$APP_NAMESPACE" \
    --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || {
      log_warn "上一次 Ollama 健康检查 Pod 仍在删除中，跳过自动知识库导入。"
      return 1
    }
  kubectl run ollama-healthcheck \
    -n "$APP_NAMESPACE" \
    --rm -i --restart=Never \
    --image=curlimages/curl:8.11.1 \
    --command -- /bin/sh -ec "curl -fsS '${OLLAMA_SERVICE_URL}/api/tags' | grep -q '${OLLAMA_EMBEDDING_MODEL_DEFAULT}'" >/dev/null || {
      log_warn "Ollama API 暂不可用，或尚未拉取 ${OLLAMA_EMBEDDING_MODEL_DEFAULT}，跳过自动知识库导入。"
      log_warn "请先执行：kubectl exec -n ${APP_NAMESPACE} deployment/ollama -- ollama pull ${OLLAMA_EMBEDDING_MODEL_DEFAULT}"
      log_warn "然后手动执行：kubectl apply -f apps/rag-app/knowledge-import-job.yaml"
      return 1
    }
}

# ---- 步骤 8：部署 RAG 应用 ----
deploy_rag_app() {
  log_step "步骤 8/9：部署 RAG 后端和前端"

  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/backend.yaml"
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/frontend.yaml"
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/ingress.yaml"

  log_info "✓ RAG 应用清单已提交"
  echo ""
}

run_knowledge_import() {
  # 检测是否已导入
  if kubectl get job rag-knowledge-import -n "$APP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q True; then
    log_info "知识库已导入，跳过。"
    echo ""
    return
  fi

  log_step "导入知识库"

  if ! check_ollama_ready_for_import; then
    echo ""
    return
  fi

  kubectl delete job rag-knowledge-import -n "$APP_NAMESPACE" --ignore-not-found=true
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/knowledge-import-job.yaml"
  kubectl wait --for=condition=complete job/rag-knowledge-import \
    -n "$APP_NAMESPACE" \
    --timeout=300s 2>/dev/null || {
      log_warn "知识库导入 Job 未在超时时间内完成，请手动检查："
      kubectl logs job/rag-knowledge-import -n "$APP_NAMESPACE" || true
    }

  echo ""
}

# ---- 步骤 9：等待就绪 ----
wait_for_ready() {
  log_step "步骤 9/9：等待所有 Pod 就绪"

  log_info "等待 Milvus Pod 就绪（可能需要几分钟）..."
  kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=milvus \
    -n "$MILVUS_NAMESPACE" \
    --timeout=600s 2>/dev/null || {
      log_warn "Milvus Pod 等待超时，请手动检查："
      kubectl get pods -n "$MILVUS_NAMESPACE"
    }

  log_info "等待 RAG 后端就绪..."
  kubectl wait --for=condition=ready pod \
    -l app=rag-backend \
    -n "$APP_NAMESPACE" \
    --timeout=300s 2>/dev/null || {
      log_warn "后端 Pod 等待超时，请手动检查："
      kubectl get pods -n "$APP_NAMESPACE"
    }

  log_info "等待 RAG 前端就绪..."
  kubectl wait --for=condition=ready pod \
    -l app=rag-frontend \
    -n "$APP_NAMESPACE" \
    --timeout=120s 2>/dev/null || {
      log_warn "前端 Pod 等待超时，请手动检查："
      kubectl get pods -n "$APP_NAMESPACE"
    }

  echo ""
}

# ---- 输出访问信息 ----
print_access_info() {
  log_step "部署完成！"

  # 获取节点 IP（优先使用外部 IP，其次是内部 IP）
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
  if [[ -z "$NODE_IP" ]]; then
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  fi

  # 获取 NodePort
  NODE_PORT=$(kubectl get svc rag-frontend-svc -n "$APP_NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "未分配")

  # 检查所有 Pod 状态
  echo ""
  echo "========================================"
  echo "  🎉 RAG Agent GitOps 部署完成！"
  echo "========================================"
  echo ""
  echo "  📍 访问地址:"
  echo "     http://${NODE_IP}:${NODE_PORT}"
  echo ""
  echo "  📦 Milvus 地址（集群内部）:"
  echo "     milvus.${MILVUS_NAMESPACE}.svc.cluster.local:19530"
  echo ""
  echo "  🔍 当前状态:"
  echo ""

  # 显示 Pod 状态
  echo "  --- Milvus Pods ---"
  kubectl get pods -n "$MILVUS_NAMESPACE" 2>/dev/null || echo "  (无)"
  echo ""
  echo "  --- RAG App Pods ---"
  kubectl get pods -n "$APP_NAMESPACE" 2>/dev/null || echo "  (无)"
  echo ""
  echo "========================================"
  echo "  📋 常用命令:"
  echo ""

  cat <<EOF
    # 查看 Pod 状态
    kubectl get pods -n ${APP_NAMESPACE}
    kubectl get pods -n ${MILVUS_NAMESPACE}

    # 查看后端日志
    kubectl logs -f deployment/rag-backend -n ${APP_NAMESPACE}

    # 查看前端日志
    kubectl logs -f deployment/rag-frontend -n ${APP_NAMESPACE}

    # 重启后端（修改配置后执行）
    kubectl rollout restart deployment/rag-backend -n ${APP_NAMESPACE}

    # 导入知识库到 Milvus
    curl -X POST http://rag-backend-svc.${APP_NAMESPACE}.svc.cluster.local:8080/api/knowledge/import-all

    # 卸载整个项目
    helm uninstall ${MILVUS_HELM_RELEASE} -n ${MILVUS_NAMESPACE}
    kubectl delete namespace ${APP_NAMESPACE} ${MILVUS_NAMESPACE}

EOF
  echo "========================================"
}

# ---- 主流程 ----
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        RAG Agent GitOps — 一键部署脚本                   ║"
  echo "║        Kubernetes 集群要求 ≥ 1.25                        ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""

  check_prerequisites
  setup_registry_mirror
  prepare_storage
  create_namespaces
  choose_llm_mode
  deploy_milvus
  create_knowledge_base_config
  deploy_ollama
  deploy_rag_app
  wait_for_ready
  run_knowledge_import
  print_access_info

  log_info "部署脚本执行完毕！"
}

# 执行主流程
parse_args "$@"
main
