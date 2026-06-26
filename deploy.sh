#!/usr/bin/env bash
# =============================================================================
# RAG Agent GitOps — 一键部署脚本
# =============================================================================
# 用途：在全新的 K8s 集群上完成 RAG 知识库系统的完整部署
# 用法：chmod +x deploy.sh && ./deploy.sh
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

# ---- 步骤 0：前置条件检查 ----
check_prerequisites() {
  log_step "步骤 0/7：检查前置条件"

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
  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v Ready | wc -l || echo "0")
  if [[ "$NOT_READY" -gt 0 ]]; then
    log_warn "有 $NOT_READY 个节点未就绪，部署可能失败"
    kubectl get nodes
  else
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    log_info "✓ 集群节点数: $NODE_COUNT（全部就绪）"
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

  echo ""
}

# ---- 步骤 1：准备存储 ----
prepare_storage() {
  log_step "步骤 1/7：检查存储配置"

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

# ---- 步骤 2：创建命名空间 ----
create_namespaces() {
  log_step "步骤 2/7：创建命名空间"

  kubectl apply -f "${SCRIPT_DIR}/apps/milvus/namespace.yaml"
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/namespace.yaml"

  log_info "✓ 命名空间 $MILVUS_NAMESPACE 和 $APP_NAMESPACE 已创建"
  echo ""
}

# ---- 步骤 3：部署 Milvus ----
deploy_milvus() {
  log_step "步骤 3/7：部署 Milvus 向量数据库（通过 Helm）"

  # 添加 Helm 仓库
  if ! helm repo list 2>/dev/null | grep -q "milvus"; then
    log_info "添加 Milvus Helm 仓库..."
    helm repo add milvus "$MILVUS_HELM_REPO"
  fi
  log_info "更新 Helm 仓库..."
  helm repo update milvus

  # 检查是否已安装
  if helm status "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" &>/dev/null; then
    log_warn "Milvus 已安装，执行更新..."
    helm upgrade "$MILVUS_HELM_RELEASE" milvus/milvus \
      --namespace "$MILVUS_NAMESPACE" \
      --set mode=standalone \
      --set image.all.repository="milvusdb/milvus" \
      --set image.all.tag="v2.4.0" \
      --wait \
      --timeout 10m
  else
    log_info "安装 Milvus Standalone..."
    helm install "$MILVUS_HELM_RELEASE" milvus/milvus \
      --namespace "$MILVUS_NAMESPACE" \
      --set mode=standalone \
      --set image.all.repository="milvusdb/milvus" \
      --set image.all.tag="v2.4.0" \
      --wait \
      --timeout 10m
  fi

  log_info "✓ Milvus 部署完成"
  echo ""
}

# ---- 步骤 4：创建应用配置 ----
create_app_config() {
  log_step "步骤 4/7：创建应用 ConfigMap 和 Secret"

  # 检查 secret 中的 API Key 是否已配置
  SECRET_FILE="${SCRIPT_DIR}/apps/rag-app/backend-secret.yaml"

  if grep -q "your-llm-api-key-here" "$SECRET_FILE"; then
    log_warn "=============================================="
    log_warn "  检测到 API Key 未配置！"
    log_warn "  当前 LLM_PROVIDER 默认为 'ollama'（本地模式）"
    log_warn "  如需使用云端 LLM（OpenAI/Anthropic），请："
    log_warn "  1. 编辑 apps/rag-app/backend-secret.yaml"
    log_warn "  2. 填入你的 API Key"
    log_warn "  3. 编辑 apps/rag-app/backend-config.yaml"
    log_warn "     修改 LLM_PROVIDER 为 'openai' 或 'anthropic'"
    log_warn "  4. 重新运行 kubectl apply -f apps/rag-app/backend-secret.yaml"
    log_warn "  5. 重启后端: kubectl rollout restart deployment/rag-backend -n rag-app"
    log_warn "=============================================="
  fi

  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/backend-config.yaml"
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/backend-secret.yaml"

  log_info "✓ ConfigMap 和 Secret 已创建"
  echo ""
}

# ---- 步骤 5：部署 RAG 应用 ----
deploy_rag_app() {
  log_step "步骤 5/7：部署 RAG 后端和前端"

  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/backend.yaml"
  kubectl apply -f "${SCRIPT_DIR}/apps/rag-app/frontend.yaml"

  log_info "✓ RAG 应用清单已提交"
  echo ""
}

# ---- 步骤 6：等待就绪 ----
wait_for_ready() {
  log_step "步骤 6/7：等待所有 Pod 就绪"

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

# ---- 步骤 7：输出访问信息 ----
print_access_info() {
  log_step "步骤 7/7：部署完成！"

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
  prepare_storage
  create_namespaces
  deploy_milvus
  create_app_config
  deploy_rag_app
  wait_for_ready
  print_access_info

  log_info "部署脚本执行完毕！"
}

# 执行主流程
main "$@"
