#!/usr/bin/env bash
# =============================================================================
# RAG Agent GitOps — 一键卸载脚本
# =============================================================================
# 用途：清理 deploy.sh 创建的所有 Kubernetes 资源
# 用法：
#   chmod +x uninstall.sh && ./uninstall.sh
#
# 默认行为：
#   - 删除 rag-app 和 milvus 两个命名空间（包含其下所有资源）
#   - 卸载 Milvus Helm Release
#   - 可选删除 local-path-provisioner（deploy.sh 可能自动安装的）
#   - 可选删除 K8s 节点上的 hostPath 数据目录
#   - 可选关闭 minikube ingress addon
# =============================================================================

set -euo pipefail

# ---- 颜色输出（与 deploy.sh 一致） ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}${BOLD}▶ $*${NC}"; echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ---- 配置（与 deploy.sh 保持一致） ----
MILVUS_NAMESPACE="milvus"
APP_NAMESPACE="rag-app"
MILVUS_HELM_RELEASE="milvus"

# ---- 默认清理选项 ----
CLEAN_PVC=false
CLEAN_HOSTPATH=false
CLEAN_LOCAL_PROVISIONER=false
CLEAN_MINIKUBE_INGRESS=false
FORCE=false

usage() {
  cat <<EOF
用法: ./uninstall.sh [选项]

选项:
  --force                  跳过确认提示，直接卸载
  --clean-pvc              删除 PVC 数据（默认只删除命名空间，PVC 由 StorageClass 保留）
  --clean-hostpath         删除节点上的 /data/milvus-* hostPath 目录
  --clean-local-provisioner 删除 deploy.sh 自动安装的 local-path-provisioner
  --clean-minikube-ingress 停用 minikube ingress addon
  -h, --help               显示帮助

示例:
  ./uninstall.sh                              # 安全卸载（保留数据）
  ./uninstall.sh --force                       # 非交互式快速卸载
  ./uninstall.sh --clean-pvc                   # 卸载并删除 PVC 数据
  ./uninstall.sh --clean-pvc --clean-hostpath  # 完全清理，不留痕迹
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        FORCE=true
        shift
        ;;
      --clean-pvc)
        CLEAN_PVC=true
        shift
        ;;
      --clean-hostpath)
        CLEAN_HOSTPATH=true
        shift
        ;;
      --clean-local-provisioner)
        CLEAN_LOCAL_PROVISIONER=true
        shift
        ;;
      --clean-minikube-ingress)
        CLEAN_MINIKUBE_INGRESS=true
        shift
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
}

# ---- 前置检查 ----
check_prerequisites() {
  log_step "步骤 1/6：检查前置条件"

  if ! command -v kubectl &>/dev/null; then
    log_error "未找到 kubectl，请先安装：https://kubernetes.io/docs/tasks/tools/"
    exit 1
  fi
  log_info "✓ kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client -o json | grep -o '"gitVersion":"[^"]*"' | head -1)"

  if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到 Kubernetes 集群，请检查 kubeconfig 配置"
    log_error "运行 'kubectl cluster-info' 查看详细错误"
    exit 1
  fi
  log_info "✓ 集群连接正常: $(kubectl config current-context)"

  # 检查是否有任何目标资源存在
  local has_resources=false
  if kubectl get namespace "$APP_NAMESPACE" &>/dev/null 2>&1; then
    has_resources=true
  fi
  if kubectl get namespace "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    has_resources=true
  fi
  if helm status "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    has_resources=true
  fi

  if [[ "$has_resources" != true ]]; then
    log_info "未检测到 rag-agent-gitops 部署的相关资源，无需卸载。"
    log_info "确认命令: kubectl get ns ${APP_NAMESPACE} ${MILVUS_NAMESPACE} 2>/dev/null || echo '无'"
    exit 0
  fi

  echo ""
}

# ---- 确认卸载 ----
confirm_uninstall() {
  if [[ "$FORCE" == true ]]; then
    return
  fi

  log_step "步骤 2/6：确认卸载"

  echo "  即将删除 rag-agent-gitops 部署的全部资源："
  echo ""

  # 列出 rag-app 命名空间的资源
  if kubectl get namespace "$APP_NAMESPACE" &>/dev/null 2>&1; then
    echo "  ┌─ 应用命名空间: ${BOLD}${APP_NAMESPACE}${NC}"
    local app_resources
    app_resources=$(kubectl get all,pvc,configmap,secret,ingress,job -n "$APP_NAMESPACE" -o name 2>/dev/null | sed 's/^/  │  /' || echo "  │  （无资源）")
    echo "$app_resources"
    echo "  └─"
  else
    echo "  ┌─ 应用命名空间: ${BOLD}${APP_NAMESPACE}${NC}（不存在）"
    echo "  └─"
  fi
  echo ""

  # 列出 milvus 命名空间的资源
  if kubectl get namespace "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    echo "  ┌─ Milvus 命名空间: ${BOLD}${MILVUS_NAMESPACE}${NC}（含 PVC 持久数据）"
    local milvus_resources
    milvus_resources=$(kubectl get all,pvc -n "$MILVUS_NAMESPACE" -o name 2>/dev/null | sed 's/^/  │  /' || echo "  │  （无资源）")
    echo "$milvus_resources"
    echo "  └─"
  else
    echo "  ┌─ Milvus 命名空间: ${BOLD}${MILVUS_NAMESPACE}${NC}（不存在）"
    echo "  └─"
  fi
  echo ""

  # 检查是否有 PVC（持久数据）
  local has_pvc=false
  if kubectl get namespace "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    local pvc_count
    pvc_count=$(kubectl get pvc -n "$MILVUS_NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$pvc_count" -gt 0 ]]; then
      has_pvc=true
    fi
  fi

  local has_app_pvc=false
  if kubectl get namespace "$APP_NAMESPACE" &>/dev/null 2>&1; then
    local app_pvc_count
    app_pvc_count=$(kubectl get pvc -n "$APP_NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$app_pvc_count" -gt 0 ]]; then
      has_app_pvc=true
    fi
  fi

  if [[ "$has_pvc" == true || "$has_app_pvc" == true ]]; then
    log_warn "检测到持久卷声明 (PVC)，删除命名空间后 PVC 及存储后端数据将不可用！"
    echo ""

    if [[ "$CLEAN_PVC" == true ]]; then
      log_warn "--clean-pvc 已启用，PVC 数据将被永久删除。"
    else
      echo "  数据选项："
      echo "    [c] 仅删除命名空间（PVC 由 StorageClass/provisioner 保留，可回收利用）"
      echo "    [d] 同时删除 PVC 及存储后端数据（永久丢失！）"
      echo "    [q] 取消卸载"
      read -r -p "  请选择 [c/d/q] (默认 c): " data_choice
      data_choice="${data_choice:-c}"

      case "$data_choice" in
        c|C)
          CLEAN_PVC=false
          log_info "保留 PVC 和存储数据"
          ;;
        d|D)
          CLEAN_PVC=true
          log_warn "确认删除 PVC，数据将永久丢失！"
          ;;
        q|Q)
          log_info "取消卸载"
          exit 0
          ;;
        *)
          log_info "保留 PVC 和存储数据"
          ;;
      esac
    fi
  else
    local confirm_choice
    read -r -p "  确认卸载所有资源？(y/N): " confirm_choice
    if [[ "${confirm_choice}" != "y" && "${confirm_choice}" != "Y" ]]; then
      log_info "取消卸载"
      exit 0
    fi
  fi

  # 询问是否清理额外组件
  echo ""
  if ! kubectl get namespace local-path-storage &>/dev/null 2>&1; then
    CLEAN_LOCAL_PROVISIONER=false
  fi

  # 检查是否是 minikube 上下文
  local current_context
  current_context="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$current_context" != minikube* ]]; then
    CLEAN_MINIKUBE_INGRESS=false
  fi

  echo ""
}

# ---- 删除 RAG 应用资源 ----
delete_rag_app() {
  log_step "步骤 3/6：删除 RAG 应用资源"

  local ns_exists=false
  if kubectl get namespace "$APP_NAMESPACE" &>/dev/null 2>&1; then
    ns_exists=true
  fi

  if [[ "$ns_exists" != true ]]; then
    log_info "命名空间 ${APP_NAMESPACE} 不存在，跳过"
    echo ""
    return
  fi

  # 先删除 Knowledge Import Job（快速完成，避免占位）
  log_info "删除 Knowledge Import Job..."
  kubectl delete job rag-knowledge-import -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true

  # 删除 Deployment（Ollama、Frontend、Backend）
  log_info "删除 Deployment..."
  kubectl delete deployment rag-backend -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
  kubectl delete deployment rag-frontend -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
  kubectl delete deployment ollama -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true

  # 删除 Service
  log_info "删除 Service..."
  kubectl delete service rag-backend-svc -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true
  kubectl delete service rag-frontend-svc -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true
  kubectl delete service ollama -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true

  # 删除 ConfigMap 和 Secret
  log_info "删除 ConfigMap 和 Secret..."
  kubectl delete configmap rag-backend-config -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true
  kubectl delete configmap rag-knowledge-base -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true
  kubectl delete secret rag-backend-secret -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true

  # 删除 Ingress
  log_info "删除 Ingress..."
  kubectl delete ingress rag-ingress -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true

  # 删除 PVC（可选）
  if [[ "$CLEAN_PVC" == true ]]; then
    log_info "删除 PVC（--clean-pvc 已启用）..."
    kubectl delete pvc --all -n "$APP_NAMESPACE" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
  fi

  # 最后删除命名空间（包含其余残留资源）
  log_info "删除命名空间 ${APP_NAMESPACE}..."
  if kubectl delete namespace "$APP_NAMESPACE" --wait=true --timeout=180s 2>/dev/null; then
    log_info "✓ 命名空间 ${APP_NAMESPACE} 已删除"
  else
    log_warn "命名空间 ${APP_NAMESPACE} 删除超时，如果有资源卡在 Terminating 状态，可执行："
    log_warn "  kubectl delete namespace ${APP_NAMESPACE} --force --grace-period=0"
  fi

  echo ""
}

# ---- 删除 Milvus ----
delete_milvus() {
  log_step "步骤 4/6：删除 Milvus 向量数据库"

  # 卸载 Helm Release（如果存在）
  if helm status "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    log_info "卸载 Helm Release: ${MILVUS_HELM_RELEASE}..."
    helm uninstall "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" --wait --timeout 5m 2>/dev/null || {
      log_warn "Helm uninstall 超时，请稍后手动检查：helm status ${MILVUS_HELM_RELEASE} -n ${MILVUS_NAMESPACE}"
    }
    log_info "✓ Milvus Helm Release 已卸载"
  else
    log_info "Milvus Helm Release 不存在，跳过"
  fi

  # 删除 Milvus 命名空间中的 PVC（可选）
  if kubectl get namespace "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    if [[ "$CLEAN_PVC" == true ]]; then
      log_info "删除 Milvus PVC（--clean-pvc 已启用）..."
      kubectl delete pvc --all -n "$MILVUS_NAMESPACE" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
    fi

    # 删除命名空间
    log_info "删除命名空间 ${MILVUS_NAMESPACE}..."
    if kubectl delete namespace "$MILVUS_NAMESPACE" --wait=true --timeout=180s 2>/dev/null; then
      log_info "✓ 命名空间 ${MILVUS_NAMESPACE} 已删除"
    else
      log_warn "命名空间 ${MILVUS_NAMESPACE} 删除超时，如果有资源卡在 Terminating 状态，可执行："
      log_warn "  kubectl delete namespace ${MILVUS_NAMESPACE} --force --grace-period=0"
    fi
  else
    log_info "命名空间 ${MILVUS_NAMESPACE} 不存在，跳过"
  fi

  # 清理 PV（hostPath PV 不会随命名空间删除）
  log_info "清理 PersistentVolume..."
  for pv in milvus-etcd-pv milvus-minio-pv milvus-standalone-pv; do
    if kubectl get pv "$pv" &>/dev/null 2>&1; then
      # PV 的 ReclaimPolicy 是 Retain，需要手动删除
      kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' 2>/dev/null || true
      kubectl delete pv "$pv" --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true
      log_info "✓ PV ${pv} 已删除"
    fi
  done

  echo ""
}

# ---- 清理额外组件 ----
cleanup_extras() {
  log_step "步骤 5/6：清理额外组件"

  # 清理 local-path-provisioner
  if [[ "$CLEAN_LOCAL_PROVISIONER" == true ]]; then
    if kubectl get namespace local-path-storage &>/dev/null 2>&1; then
      log_info "删除 local-path-provisioner..."
      kubectl delete deployment local-path-provisioner -n local-path-storage --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true
      kubectl delete namespace local-path-storage --ignore-not-found --wait=true --timeout=120s 2>/dev/null || true
      log_info "✓ local-path-provisioner 已删除"
    else
      log_info "local-path-provisioner 不存在，跳过"
    fi
  else
    log_info "跳过 local-path-provisioner 清理（如需清理请用 --clean-local-provisioner）"
  fi

  # 清理 hostPath 数据目录
  if [[ "$CLEAN_HOSTPATH" == true ]]; then
    log_warn "清理节点上的 /data/milvus-* hostPath 目录..."
    log_warn "这需要在集群节点上执行命令，请确认节点可达："
    echo ""

    # 尝试通过 kubectl 在节点上执行清理
    local node_name
    node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$node_name" ]]; then
      log_info "在节点 ${node_name} 上清理 hostPath 数据..."
      # 使用特权 Pod 清理 hostPath 数据
      kubectl run hostpath-cleaner --image=alpine:3.20 --restart=Never --command -- rm -rf /data/milvus-etcd /data/milvus-minio /data/milvus-standalone 2>/dev/null || {
        # 如果无法直接执行，打印提示
        log_warn "无法自动清理 hostPath 数据，请手动在节点上执行："
        log_warn "  sudo rm -rf /data/milvus-etcd /data/milvus-minio /data/milvus-standalone"
      }
      kubectl delete pod hostpath-cleaner --ignore-not-found --wait=true --timeout=30s 2>/dev/null || true
    else
      log_warn "无法获取节点名称，请手动在 K8s 节点上执行："
      log_warn "  sudo rm -rf /data/milvus-etcd /data/milvus-minio /data/milvus-standalone"
    fi
    log_info "✓ hostPath 目录已清理"
  fi

  # 清理 minikube ingress addon
  if [[ "$CLEAN_MINIKUBE_INGRESS" == true ]]; then
    if command -v minikube &>/dev/null; then
      local current_context
      current_context="$(kubectl config current-context 2>/dev/null || true)"
      if [[ "$current_context" == minikube* ]]; then
        log_info "停用 minikube ingress addon..."
        minikube addons disable ingress 2>/dev/null || true
        log_info "✓ minikube ingress addon 已停用"
      else
        log_info "当前非 minikube 集群，跳过"
      fi
    else
      log_info "minikube 命令不可用，跳过"
    fi
  else
    log_info "跳过 minikube ingress addon 清理（如需清理请用 --clean-minikube-ingress）"
  fi

  echo ""
}

# ---- 输出状态 ----
print_result() {
  log_step "步骤 6/6：卸载完成"

  echo ""
  echo -e "${BOLD}========================================${NC}"
  echo -e "${BOLD}  🧹 RAG Agent GitOps 已卸载${NC}"
  echo -e "${BOLD}========================================${NC}"
  echo ""

  # 确认命名空间已删除
  local all_clean=true

  if kubectl get namespace "$APP_NAMESPACE" &>/dev/null 2>&1; then
    log_warn "命名空间 '${APP_NAMESPACE}' 仍在删除中"
    log_warn "  检查: kubectl get ns ${APP_NAMESPACE}"
    all_clean=false
  else
    log_info "✓ 命名空间 '${APP_NAMESPACE}' 已清理"
  fi

  if kubectl get namespace "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    log_warn "命名空间 '${MILVUS_NAMESPACE}' 仍在删除中"
    log_warn "  检查: kubectl get ns ${MILVUS_NAMESPACE}"
    all_clean=false
  else
    log_info "✓ 命名空间 '${MILVUS_NAMESPACE}' 已清理"
  fi

  # 检查 Helm Release
  if helm status "$MILVUS_HELM_RELEASE" -n "$MILVUS_NAMESPACE" &>/dev/null 2>&1; then
    log_warn "Milvus Helm Release 仍存在（命名空间可能还在）"
    all_clean=false
  fi

  echo ""
  if [[ "$all_clean" == true ]]; then
    log_info "所有资源已清理完毕！"
  else
    log_warn "部分资源仍在清理中，稍后可运行以下命令确认："
    echo ""
    echo "  kubectl get ns ${APP_NAMESPACE} ${MILVUS_NAMESPACE} 2>/dev/null || echo '已清理'"
    echo "  helm status ${MILVUS_HELM_RELEASE} -n ${MILVUS_NAMESPACE} 2>/dev/null || echo '已清理'"
  fi

  echo ""
  log_info "如需重新部署，执行: ./deploy.sh"
  echo ""
}

# ---- 主流程 ----
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║    RAG Agent GitOps — 一键卸载脚本                       ║"
  echo "║    清理 deploy.sh 创建的所有 K8s 资源                    ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""

  check_prerequisites
  confirm_uninstall
  delete_rag_app
  delete_milvus
  cleanup_extras
  print_result

  log_info "卸载脚本执行完毕！"
}

# 执行主流程
parse_args "$@"
main
