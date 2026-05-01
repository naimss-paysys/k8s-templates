#!/bin/bash
# ================================================================
# FILE: lib/create.sh
# Deploy, dry-run, status, rollout watch, diagnostics, and
# ConfigMap cleanup. Requires lib/ui.sh and lib/validate.sh.
# ================================================================

# ── Diagnostics ───────────────────────────────────────────────────
show_diagnostics() {
  local POD
  POD=$(kubectl get pods -n "$NAMESPACE" -l "app=${SERVICE_NAME}" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E "ImagePullBackOff|ErrImagePull|CrashLoopBackOff|CreateContainerConfigError|Pending" \
    | awk '{print $2}' | head -n 1) || POD=""

  if [ -z "$POD" ]; then
    POD=$(kubectl get pods -n "$NAMESPACE" -l "app=${SERVICE_NAME}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null) || POD=""
  fi

  if [ -n "$POD" ]; then
    echo -e "\n  ${WARN_BG}${BLACK}${BOLD} DIAGNOSTICS ${NC} ${BOLD}${WHITE} Failed Pod: $POD${NC}"
    echo -e "         ${GREY}→ Event Summary:${NC}"
    kubectl get events -n "$NAMESPACE" \
      --field-selector "involvedObject.name=${POD}" \
      --sort-by='.lastTimestamp' 2>/dev/null \
      | tail -n 8 | sed 's/^/           /' || true
    echo -e "\n         ${GREY}→ Recent Logs:${NC}"
    local LOGS
    LOGS=$(kubectl logs "$POD" -n "$NAMESPACE" --tail=15 2>/dev/null) || LOGS=""
    if [ -n "$LOGS" ]; then
      echo "$LOGS" | sed 's/^/           /'
    else
      echo -e "           ${DIM}No logs available (container hasn't started yet)${NC}"
    fi
  fi
}

# ── Rollout watch ─────────────────────────────────────────────────
watch_rollout() {
  local TIMEOUT="${ROLLOUT_TIMEOUT:-120}"
  local DEBUG_TIME=$(( TIMEOUT / 4 ))

  echo -e "  ${DIM}Waiting for rollout (max ${TIMEOUT}s)...${NC}"
  divider

  kubectl rollout status "deployment/${SERVICE_NAME}" -n "$NAMESPACE" &
  local ROLLOUT_PID=$!

  local WATCH_START NOW ELAPSED
  WATCH_START=$(date +%s)
  local DEBUG_DONE=false

  while kill -0 $ROLLOUT_PID 2>/dev/null; do
    NOW=$(date +%s)
    ELAPSED=$(( NOW - WATCH_START ))
    if [ $ELAPSED -ge $DEBUG_TIME ] && [ "$DEBUG_DONE" = "false" ]; then
      DEBUG_DONE=true
      echo -e "  ${YELLOW}!${NC} Rollout is taking longer than expected... checking pods."
    fi
    if [ $ELAPSED -ge $TIMEOUT ]; then
      kill $ROLLOUT_PID 2>/dev/null || true
      echo ""
      error_banner "Rollout Timeout" "Deployment stuck for ${TIMEOUT}s"
      show_diagnostics
      echo -e "\n  ${YELLOW}↩ REVERTING:${NC} Undoing deployment to maintain service stability."
      kubectl rollout undo "deployment/${SERVICE_NAME}" -n "$NAMESPACE" || true
      exit 1
    fi
    sleep 2
  done

  local ROLLOUT_EXIT=0
  wait $ROLLOUT_PID || ROLLOUT_EXIT=$?
  return $ROLLOUT_EXIT
}

# ── Pod status table ──────────────────────────────────────────────
show_pod_status() {
  section_header "Live Pods"
  kubectl get pods -n "$NAMESPACE" -l "app=${SERVICE_NAME}" 2>/dev/null \
    | sed 's/^/  /' \
    || echo -e "  ${DIM}No pods found${NC}"
  echo ""
}

# ── ConfigMap cleanup ─────────────────────────────────────────────
# Keeps the 3 newest versioned configmaps in the cluster.
# Lists what will be kept and what will be deleted, then asks
# for confirmation before deleting anything.
cleanup_old_configmaps() {
  local base_name="${CONFIGMAP_NAME:-}"
  [ -z "$base_name" ] && return 0

  section_header "ConfigMap Cleanup  (keeping latest 3)"

  # Sorted ascending by creation time (oldest first), so tail = newest
  local all_cms
  all_cms=$(kubectl get configmap -n "$NAMESPACE" \
    --sort-by=.metadata.creationTimestamp \
    --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep "^${base_name}-") || all_cms=""

  if [ -z "$all_cms" ]; then
    echo -e "  ${DIM}No versioned configmaps found for ${base_name}${NC}"
    echo ""
    return 0
  fi

  local total
  total=$(echo "$all_cms" | grep -c .) || total=0

  if [ "$total" -le 3 ]; then
    echo -e "  ${GREEN}✔${NC}  ${DIM}${total} configmap(s) found — within limit, nothing to clean up${NC}"
    echo ""
    return 0
  fi

  local delete_count=$(( total - 3 ))
  local keep_cms delete_cms
  keep_cms=$(echo "$all_cms"   | tail -n 3)
  delete_cms=$(echo "$all_cms" | head -n "$delete_count")

  # ── Show keep list ──────────────────────────────────────────────
  echo -e "  ${GREEN}${BOLD}Keeping (newest 3):${NC}"
  while IFS= read -r cm; do
    [ -z "$cm" ] && continue
    echo -e "     ${GREEN}▸${NC}  ${WHITE}${cm}${NC}"
  done <<< "$keep_cms"

  echo ""

  # ── Show delete list ────────────────────────────────────────────
  echo -e "  ${RED}${BOLD}To be deleted (${delete_count} older):${NC}"
  while IFS= read -r cm; do
    [ -z "$cm" ] && continue
    echo -e "     ${RED}✖${NC}  ${DIM}${cm}${NC}"
  done <<< "$delete_cms"

  echo ""

  local _do_delete=false
  if [ "${CI:-false}" = "true" ]; then
    echo -e "  ${DIM}CI mode — auto-deleting ${delete_count} old configmap(s)${NC}"
    echo ""
    _do_delete=true
  else
    printf "  ${WARN_BG}${BLACK}${BOLD} ? ${NC}  Delete ${RED}${BOLD}${delete_count}${NC} old configmap(s) from ${WHITE}${NAMESPACE}${NC}? ${BOLD}(y/n):${NC} "
    read -r CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
      echo ""
      _do_delete=true
    fi
  fi

  if [ "$_do_delete" = "true" ]; then
    while IFS= read -r cm; do
      [ -z "$cm" ] && continue
      printf "     ${DIM}Deleting${NC}  %-50s" "${cm}..."
      local DEL_OUT DEL_EXIT
      set +e
      DEL_OUT=$(kubectl delete configmap "$cm" -n "$NAMESPACE" 2>&1)
      DEL_EXIT=$?
      set -e
      if [ $DEL_EXIT -eq 0 ]; then
        echo -e "${GREEN}✔  deleted${NC}"
      else
        echo -e "${RED}✖  failed${NC}"
        echo -e "        ${DIM}${DEL_OUT}${NC}"
      fi
    done <<< "$delete_cms"
    echo ""
  else
    echo -e "  ${YELLOW}⊘${NC}  Skipped — old configmaps kept"
    echo ""
  fi
}

# ── Init action ───────────────────────────────────────────────────
# Scaffolds values.<country>.env and application.<country>.yaml
# for a service. Run before the first country deploy.
do_init() {
  if [ -z "${COUNTRY:-}" ]; then
    error_banner "--country required for init" \
      "Usage: kubeforge <service> --country <code> --init"
    exit 1
  fi

  local _cu
  _cu=$(echo "$COUNTRY" | tr '[:lower:]' '[:upper:]')

  banner "◈  Init  ·  ${SERVICE_NAME}  [${COUNTRY}]" \
    "Scaffolding country overlay files..."

  local country_env="${SERVICE_DIR}/values.${COUNTRY}.env"
  local country_app="${SERVICE_DIR}/application.${COUNTRY}.yaml"

  # ── values.<country>.env ───────────────────────────────────────
  section_header "values.${COUNTRY}.env"
  if [ -f "$country_env" ]; then
    echo -e "  ${YELLOW}⊘${NC}  Already exists — skipping"
    echo -e "     ${DIM}${country_env}${NC}"
  else
    cat > "$country_env" <<EOF
# ── ${_cu} country override ──────────────────────────────────────────
NAMESPACE=
TAG=
EOF
    echo -e "  ${GREEN}✔${NC}  Created: ${WHITE}${country_env}${NC}"
    echo -e "     ${DIM}Fill in:${NC}  ${BOLD}NAMESPACE${NC}  and  ${BOLD}TAG${NC}"
  fi
  echo ""

  # ── application.<country>.yaml ────────────────────────────────
  section_header "application.${COUNTRY}.yaml"
  if [ -f "$country_app" ]; then
    echo -e "  ${YELLOW}⊘${NC}  Already exists — skipping"
    echo -e "     ${DIM}${country_app}${NC}"
  elif [ -f "${SERVICE_DIR}/application.yaml" ]; then
    cp "${SERVICE_DIR}/application.yaml" "$country_app"
    echo -e "  ${GREEN}✔${NC}  Created: ${WHITE}${country_app}${NC}"
    echo -e "     ${DIM}Copied from application.yaml — update config values for ${_cu}${NC}"
  else
    echo -e "  ${YELLOW}⊘${NC}  No base application.yaml — ${DIM}${country_app}${NC} not created"
    echo -e "     ${DIM}This service uses the no-config template — no application yaml needed${NC}"
  fi
  echo ""

  divider
  echo ""
  echo -e "  ${BOLD}${WHITE}Next steps:${NC}"
  echo -e "     ${YELLOW}1.${NC}  Edit ${WHITE}${country_env}${NC}   ← set NAMESPACE and TAG"
  echo -e "     ${YELLOW}2.${NC}  Edit ${WHITE}${country_app}${NC}   ← update config values for ${_cu}"
  echo -e "     ${YELLOW}3.${NC}  ${WHITE}kubeforge ${SERVICE_NAME} --country ${COUNTRY} --dry-run${NC}"
  echo -e "     ${YELLOW}4.${NC}  ${WHITE}kubeforge ${SERVICE_NAME} --country ${COUNTRY}${NC}"
  echo ""
}

# ── Status action ─────────────────────────────────────────────────
do_status() {
  local _country_label="${COUNTRY:+  [${COUNTRY}]}"
  banner "◉  Status  ·  ${SERVICE_NAME}${_country_label}" \
    "Namespace  :  $NAMESPACE"

  section_header "Pods"
  kubectl get pods -n "$NAMESPACE" -l "app=${SERVICE_NAME}" 2>/dev/null \
    | sed 's/^/  /' \
    || echo -e "  ${DIM}No pods found${NC}"

  section_header "Deployment"
  kubectl get deployment "$SERVICE_NAME" -n "$NAMESPACE" -o wide 2>/dev/null \
    | sed 's/^/  /' \
    || echo -e "  ${DIM}Deployment not found${NC}"

  section_header "Service"
  kubectl get service "${SERVICE_NAME}-service" -n "$NAMESPACE" 2>/dev/null \
    | sed 's/^/  /' \
    || echo -e "  ${DIM}Service not found${NC}"

  if [ -n "${HPA_MIN:-}" ]; then
    section_header "HPA"
    kubectl get hpa -n "$NAMESPACE" 2>/dev/null \
      | grep "${SERVICE_NAME}" | sed 's/^/  /' \
      || echo -e "  ${DIM}No HPA found${NC}"
  fi

  echo ""
}

# ── Dry run action ────────────────────────────────────────────────
do_dry_run() {
  local _country_label="${COUNTRY:+  [${COUNTRY}]}"
  banner "◎  Dry Run  ·  ${SERVICE_NAME}${_country_label}" \
    "Namespace  :  $NAMESPACE" \
    "Image      :  $IMAGE:$TAG" \
    "Template   :  $TEMPLATE_LABEL"

  if [ "$TEMPLATE_LABEL" == "with-config" ]; then
    section_header "ConfigMap  (preview)"
    if [ -f "$CONFIGMAP_FILE" ]; then
      local CM_NAME
      CM_NAME=$(grep 'name:' "$CONFIGMAP_FILE" | head -1 | awk '{print $2}')
      echo -e "  ${GREY}Name:${NC} ${WHITE}${CM_NAME}${NC}"
      echo -e "  ${GREY}File:${NC} ${WHITE}${CONFIGMAP_FILE}${NC}"
      echo ""
      cat "$CONFIGMAP_FILE"
    else
      echo -e "  ${YELLOW}⊘  ${CONFIGMAP_FILE} not present — will be generated on deploy${NC}"
    fi
  else
    section_header "ConfigMap"
    echo -e "  ${YELLOW}⊘  no-config template — configmap step skipped${NC}"
  fi

  validate_configs

  section_header "Mapping"
  if [ "$HAS_MAPPING" == "true" ]; then
    envsubst < "templates/mapping.yaml.template"
  else
    echo -e "  ${YELLOW}⊘  PREFIX / REWRITE not set — mapping will be skipped${NC}"
  fi

  section_header "HPA"
  if [ "$HAS_HPA" == "true" ]; then
    envsubst < "templates/hpa.yaml.template"
  else
    echo -e "  ${YELLOW}⊘  HPA_MIN / MAX / THRESHOLD not set — HPA will be skipped${NC}"
  fi

  section_header "Rendered Deployment"
  envsubst < "$TEMPLATE"

  echo ""
  divider
  echo -e "  ${DIM}◎  Dry run complete — nothing was applied${NC}"
  echo ""
}

# ── Deploy action ─────────────────────────────────────────────────
do_deploy() {
  local TOTAL=1
  [ "$TEMPLATE_LABEL" == "with-config" ] && TOTAL=$(( TOTAL + 1 ))
  [ "$HAS_MAPPING"    == "true"        ] && TOTAL=$(( TOTAL + 1 ))
  [ "$HAS_HPA"        == "true"        ] && TOTAL=$(( TOTAL + 1 ))

  local STEP_NUM=1
  local START_TIME
  START_TIME=$(date +%s)
  local IMAGE_SHORT="${IMAGE##*/}:${TAG}"
  local _country_label="${COUNTRY:+  [${COUNTRY}]}"

  # ── Pre-flight checks ──────────────────────────────────────────
  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    warn_banner "Namespace '${NAMESPACE}' does not exist" \
      "Create it first: kubectl create namespace ${NAMESPACE}"
    exit 1
  fi

  if [ "${TAG:-}" = "latest" ]; then
    warn_banner "Using 'latest' tag is not recommended" \
      "Rollback will not work reliably — use a versioned tag instead"
  fi

  # ── Deploy banner ──────────────────────────────────────────────
  banner "▶  Deploying  ·  ${SERVICE_NAME}${_country_label}" \
    "Namespace  :  $NAMESPACE" \
    "Image      :  $IMAGE_SHORT" \
    "Template   :  $TEMPLATE_LABEL"

  # ── Show configmap info (applied first) ───────────────────────
  if [ "$TEMPLATE_LABEL" == "with-config" ] && [ -f "$CONFIGMAP_FILE" ]; then
    section_header "ConfigMap  (will be applied first)"
    local CM_NAME
    CM_NAME=$(grep 'name:' "$CONFIGMAP_FILE" | head -1 | awk '{print $2}')
    echo -e "  ${GREY}Name:${NC} ${WHITE}${CM_NAME}${NC}"
    echo -e "  ${GREY}File:${NC} ${WHITE}${CONFIGMAP_FILE}${NC}"
    echo ""
  fi

  validate_configs

  # ── Step: ConfigMap (always first) ────────────────────────────
  if [ "$TEMPLATE_LABEL" == "with-config" ]; then
    step $STEP_NUM $TOTAL "Generating configmap..."
    echo ""
    echo ""
    divider
    echo ""

    set +e
    SERVICE_NAME="$SERVICE_NAME" COUNTRY="${COUNTRY:-}" CI="${CI:-false}" \
      ./generate-configmap.sh "$SERVICE_NAME"
    local CONFIGMAP_EXIT=$?
    set -e

    echo ""
    divider
    echo ""

    if [ $CONFIGMAP_EXIT -ne 0 ]; then
      error_banner "ConfigMap generation failed" \
        "Check application${COUNTRY:+.${COUNTRY}}.yaml in services/${SERVICE_NAME}/"
      exit 1
    fi

    # Re-source base + country override to get fresh CONFIGMAP_FULL_NAME
    set -a
    source "${SERVICE_DIR}/values.env"
    [ -n "${COUNTRY:-}" ] && [ -f "${SERVICE_DIR}/values.${COUNTRY}.env" ] && \
      source "${SERVICE_DIR}/values.${COUNTRY}.env"
    set +a
    export CONFIGMAP_FULL_NAME="${CONFIGMAP_FULL_NAME:-}"

    # Refresh CONFIGMAP_FILE with country-specific name
    if [ -n "${COUNTRY:-}" ]; then
      CONFIGMAP_FILE="${SERVICE_DIR}/configmap.${COUNTRY}.yaml"
    else
      CONFIGMAP_FILE="${SERVICE_DIR}/configmap.yaml"
    fi

    if [ -f "$CONFIGMAP_FILE" ]; then
      step $STEP_NUM $TOTAL "Applying configmap..."
      local CM_OUTPUT CM_EXIT
      set +e
      CM_OUTPUT=$(kubectl apply -f "$CONFIGMAP_FILE" 2>&1)
      CM_EXIT=$?
      set -e
      if [ $CM_EXIT -eq 0 ]; then
        step_done
        kubectl_result "$CM_OUTPUT"
      else
        step_fail
        error_banner "ConfigMap apply failed" "Run --dry-run to inspect the file"
        echo "$CM_OUTPUT" | sed 's/^/     /'
        echo ""
        exit 1
      fi
    else
      step $STEP_NUM $TOTAL "Applying configmap..."
      step_skipped
    fi
    STEP_NUM=$(( STEP_NUM + 1 ))

  else
    echo -e "  ${DIM}[skip]${NC}   ${YELLOW}⊘  no-config template — configmap skipped${NC}"
  fi

  # ── Step: Mapping ──────────────────────────────────────────────
  if [ "$HAS_MAPPING" == "true" ]; then
    step $STEP_NUM $TOTAL "Applying mapping..."
    local RENDERED_MAPPING MAPPING_OUTPUT MAPPING_EXIT
    RENDERED_MAPPING=$(envsubst < "templates/mapping.yaml.template")
    set +e
    MAPPING_OUTPUT=$(echo "$RENDERED_MAPPING" | kubectl apply -f - 2>&1)
    MAPPING_EXIT=$?
    set -e
    if [ $MAPPING_EXIT -eq 0 ]; then
      step_done
      kubectl_result "$MAPPING_OUTPUT"
    else
      step_fail
      error_banner "Mapping apply failed" "Check PREFIX / REWRITE in values.env"
      echo "$MAPPING_OUTPUT" | sed 's/^/     /'
      echo ""
      exit 1
    fi
    STEP_NUM=$(( STEP_NUM + 1 ))
  else
    echo -e "  ${DIM}[skip]${NC}   ${YELLOW}⊘  PREFIX / REWRITE not set — mapping skipped${NC}"
  fi

  # ── Step: Deployment + Service ─────────────────────────────────
  step $STEP_NUM $TOTAL "Applying deployment + service..."
  local RENDERED DEPLOY_OUTPUT DEPLOY_EXIT
  RENDERED=$(envsubst < "$TEMPLATE")
  set +e
  DEPLOY_OUTPUT=$(echo "$RENDERED" | kubectl apply -f - 2>&1)
  DEPLOY_EXIT=$?
  set -e
  if [ $DEPLOY_EXIT -eq 0 ]; then
    step_done
    kubectl_result "$DEPLOY_OUTPUT"
  else
    step_fail
    error_banner "Deployment apply failed" "Run --dry-run to inspect rendered YAML"
    echo "$DEPLOY_OUTPUT" | sed 's/^/     /'
    echo ""
    exit 1
  fi
  STEP_NUM=$(( STEP_NUM + 1 ))

  # ── Step: HPA ─────────────────────────────────────────────────
  if [ "$HAS_HPA" == "true" ]; then
    step $STEP_NUM $TOTAL "Applying HPA..."
    local RENDERED_HPA HPA_OUTPUT HPA_EXIT
    RENDERED_HPA=$(envsubst < "templates/hpa.yaml.template")
    set +e
    HPA_OUTPUT=$(echo "$RENDERED_HPA" | kubectl apply -f - 2>&1)
    HPA_EXIT=$?
    set -e
    if [ $HPA_EXIT -eq 0 ]; then
      step_done
      kubectl_result "$HPA_OUTPUT"
    else
      step_fail
      error_banner "HPA apply failed" \
        "Check HPA_MIN HPA_MAX HPA_CPU_THRESHOLD HPA_MEM_THRESHOLD in values.env"
      echo "$HPA_OUTPUT" | sed 's/^/     /'
      echo ""
      exit 1
    fi
  else
    echo -e "  ${DIM}[skip]${NC}   ${YELLOW}⊘  HPA not configured — skipped${NC}"
  fi

  echo ""
  divider

  # ── Rollout watch ──────────────────────────────────────────────
  local ROLLOUT_OK=0
  watch_rollout || ROLLOUT_OK=$?

  if [ $ROLLOUT_OK -eq 0 ]; then
    local TOTAL_TIME=$(( $(date +%s) - START_TIME ))
    _KFORGE_STATUS="SUCCESS"
    success_banner "${SERVICE_NAME}${_country_label} is live" "${TOTAL_TIME}s"
    show_pod_status
    cleanup_old_configmaps
  else
    echo ""
    error_banner "Rollout Failed" "Kubernetes rejected or timed out during rollout."
    show_diagnostics
    echo -e "\n  ${YELLOW}↩ REVERTING:${NC} Rolling back to last stable state."
    kubectl rollout undo "deployment/${SERVICE_NAME}" -n "$NAMESPACE" || true
    exit 1
  fi
}