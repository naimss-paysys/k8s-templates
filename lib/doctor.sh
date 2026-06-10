#!/bin/bash
# ================================================================
# FILE: lib/doctor.sh
# KubeForge Doctor — namespace-scoped health checks.
# Requires lib/ui.sh. No cluster-level RBAC needed.
# ================================================================

_doc_pass() { echo -e "  ${GREEN}✔${NC}  $1"; }

_doc_warn() {
  echo -e "  ${YELLOW}⚠${NC}  $1"
  [ -n "${2:-}" ] && echo -e "     ${DIM}→ $2${NC}"
  ISSUES=$(( ISSUES + 1 ))
}

_doc_fail() {
  echo -e "  ${RED}✖${NC}  $1"
  [ -n "${2:-}" ] && echo -e "     ${DIM}→ $2${NC}"
  ISSUES=$(( ISSUES + 1 ))
}

do_doctor() {
  local ISSUES=0
  local _country_label="${COUNTRY:+  [${COUNTRY}]}"

  banner "◈  KubeForge Doctor${_country_label}" \
    "Checking connectivity and prerequisites..."

  # ── Connectivity (namespace-scoped, no cluster RBAC needed) ──────
  section_header "Connectivity"

  local CTX
  if CTX=$(kubectl config current-context 2>/dev/null); then
    _doc_pass "Context: ${WHITE}${CTX}${NC}"
  else
    _doc_fail "kubeconfig not set" "Check ~/.kube/config or KUBECONFIG env var"
    divider
    echo ""
    echo -e "  ${RED}${BOLD}✖  Cannot continue — no kubeconfig found${NC}"
    echo ""
    return
  fi

  # Verify API server is reachable using a namespace we have access to
  local _probe_ns="${NAMESPACE:-test-mmp}"
  if kubectl get serviceaccount default -n "$_probe_ns" &>/dev/null; then
    _doc_pass "API server reachable  ${DIM}(verified via namespace: ${_probe_ns})${NC}"
  else
    _doc_fail "API server unreachable or no access to namespace '${_probe_ns}'" \
      "Check VPN, kubeconfig, and RBAC permissions"
    divider
    echo ""
    echo -e "  ${RED}${BOLD}✖  Cannot continue — API server not accessible${NC}"
    echo ""
    return
  fi
  echo ""

  # ── Namespace ─────────────────────────────────────────────────────
  if [ -n "${NAMESPACE:-}" ]; then
    section_header "Namespace  [${NAMESPACE}]"

    # Verify we can actually read in this namespace
    if kubectl auth can-i get pods -n "$NAMESPACE" &>/dev/null; then
      _doc_pass "Namespace accessible"
    else
      _doc_fail "No read access to namespace '${NAMESPACE}'" \
        "Check your RBAC rolebinding for this namespace"
    fi

    # Secrets — read from service.yaml if defined, else use defaults
    local _sec_list=""
    if [ -n "${SERVICE_DIR:-}" ] && [ -f "${SERVICE_DIR}/service.yaml" ] && command -v yq &>/dev/null; then
      _sec_list=$(yq '.secrets // [] | .[]' "${SERVICE_DIR}/service.yaml" 2>/dev/null) || _sec_list=""
    fi
    if [ -z "${_sec_list:-}" ]; then
      _sec_list=$'my-registry-secret\ndashboard-application-secrets\nelk-credentials\nmixxmmp-tls-secret'
    fi
    while IFS= read -r secret; do
      [ -z "$secret" ] && continue
      if kubectl get secret "$secret" -n "$NAMESPACE" &>/dev/null; then
        _doc_pass "Secret: ${WHITE}${secret}${NC}"
      else
        _doc_fail "Secret: ${WHITE}${secret}${NC}  ${DIM}← missing${NC}" \
          "kubectl create secret generic ${secret} -n ${NAMESPACE} ..."
      fi
    done <<< "$_sec_list"

    # Shared ConfigMaps required by all services
    for cm in "shared-logback" "shared-filebeat-config"; do
      if kubectl get configmap "$cm" -n "$NAMESPACE" &>/dev/null; then
        _doc_pass "ConfigMap: ${WHITE}${cm}${NC}"
      else
        _doc_fail "ConfigMap: ${WHITE}${cm}${NC}  ${DIM}← missing${NC}" \
          "kubectl apply -f shared/${cm}.yaml -n ${NAMESPACE}"
      fi
    done

    # PVC
    if kubectl get pvc file-storage -n "$NAMESPACE" &>/dev/null; then
      local pvc_phase
      pvc_phase=$(kubectl get pvc file-storage -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null) || pvc_phase="Unknown"
      if [ "$pvc_phase" = "Bound" ]; then
        _doc_pass "PVC: ${WHITE}file-storage${NC}  ${DIM}(${pvc_phase})${NC}"
      else
        _doc_warn "PVC: ${WHITE}file-storage${NC}  ${DIM}(phase: ${pvc_phase} — not bound)${NC}" \
          "kubectl describe pvc file-storage -n ${NAMESPACE}"
      fi
    else
      _doc_fail "PVC: ${WHITE}file-storage${NC}  ${DIM}← not found${NC}" \
        "kubectl apply -f pvc/file-storage.yaml -n ${NAMESPACE}"
    fi

    echo ""
  fi

  # ── Service ───────────────────────────────────────────────────────
  if [ -n "${SERVICE_NAME:-}" ]; then
    section_header "Service  [${DEPLOY_NAME}]"

    # Deployment readiness
    if kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" &>/dev/null; then
      local ready_r total_r
      ready_r=$(kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || ready_r=0
      total_r=$(kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null) || total_r=0
      ready_r="${ready_r:-0}"
      if [ "$ready_r" = "$total_r" ] && [ "${total_r:-0}" -gt 0 ]; then
        _doc_pass "Deployment: ${WHITE}${ready_r}/${total_r} ready${NC}"
      else
        _doc_warn "Deployment: ${WHITE}${ready_r:-0}/${total_r:-?} ready${NC}" \
          "kubectl describe deployment ${DEPLOY_NAME} -n ${NAMESPACE}"
      fi
    else
      echo -e "  ${DIM}⊘  Deployment not found — service has not been deployed yet${NC}"
    fi

    # Pod status
    local pod_lines
    pod_lines=$(kubectl get pods -n "$NAMESPACE" -l "app=${DEPLOY_NAME}" \
      --no-headers 2>/dev/null) || pod_lines=""

    if [ -n "$pod_lines" ]; then
      local running_pods crash_pods pending_pods
      running_pods=$(echo "$pod_lines" | grep -c 'Running')           || running_pods=0
      crash_pods=$(echo "$pod_lines"   | grep -cE 'CrashLoop|OOMKilled|Error') || crash_pods=0
      pending_pods=$(echo "$pod_lines" | grep -cE 'Pending|Init:')    || pending_pods=0

      if [ "$crash_pods" -gt 0 ]; then
        _doc_fail "Pods: ${WHITE}${running_pods} running${NC}  ${RED}${crash_pods} crashing${NC}" \
          "kubectl logs -n ${NAMESPACE} -l app=${DEPLOY_NAME} --tail=30"
      elif [ "$pending_pods" -gt 0 ]; then
        _doc_warn "Pods: ${WHITE}${running_pods} running${NC}  ${YELLOW}${pending_pods} pending${NC}" \
          "kubectl describe pod -n ${NAMESPACE} -l app=${DEPLOY_NAME}"
      else
        _doc_pass "Pods: ${WHITE}${running_pods} running${NC}"
      fi
    else
      echo -e "  ${DIM}⊘  No pods found${NC}"
    fi

    # Image pull errors (recent events)
    local pull_errors
    pull_errors=$(kubectl get events -n "$NAMESPACE" \
      --field-selector "reason=Failed" --no-headers 2>/dev/null \
      | grep -cE "ImagePull|Back-off pulling") || pull_errors=0
    if [ "$pull_errors" -gt 0 ]; then
      _doc_warn "Image pull errors detected  ${DIM}(${pull_errors} recent events)${NC}" \
        "kubectl get events -n ${NAMESPACE} --field-selector reason=Failed"
    fi

    # Service ConfigMap in cluster
    if [ -n "${CONFIGMAP_FULL_NAME:-}" ]; then
      if kubectl get configmap "$CONFIGMAP_FULL_NAME" -n "$NAMESPACE" &>/dev/null; then
        _doc_pass "ConfigMap: ${WHITE}${CONFIGMAP_FULL_NAME}${NC}"
      else
        _doc_fail "ConfigMap: ${WHITE}${CONFIGMAP_FULL_NAME}${NC}  ${DIM}← not found in cluster${NC}" \
          "kubeforge ${SERVICE_NAME}${COUNTRY:+ --country ${COUNTRY}} to redeploy"
      fi
    fi

    # HPA
    if [ "${HAS_HPA:-false}" == "true" ]; then
      if kubectl get hpa -n "$NAMESPACE" 2>/dev/null | grep -q "$DEPLOY_NAME"; then
        _doc_pass "HPA active"
      else
        echo -e "  ${DIM}⊘  HPA configured in service.yaml but not yet in cluster${NC}"
      fi
    fi

    echo ""
  fi

  # ── Summary ───────────────────────────────────────────────────────
  divider
  echo ""
  if [ "$ISSUES" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✔  All checks passed — system looks healthy${NC}"
  else
    echo -e "  ${RED}${BOLD}✖  ${ISSUES} issue(s) found — review the items above${NC}"
  fi
  echo ""
}