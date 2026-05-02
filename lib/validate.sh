#!/bin/bash
# ================================================================
# FILE: lib/validate.sh
# YAML validation helpers. Requires lib/ui.sh to be sourced first.
# ================================================================

validate_yaml() {
  local file="$1"
  local label="$2"

  [ ! -f "$file" ] && return 0

  printf "  ${DIM}[validate]${NC}  %-40s" "$label"

  # Prefer kubectl dry-run — catches k8s schema issues too
  if command -v kubectl &>/dev/null; then
    local out
    if out=$(kubectl apply --dry-run=client -f "$file" 2>&1); then
      step_done
      return 0
    else
      step_fail
      echo ""
      echo -e "  ${RED}YAML validation failed:  ${BOLD}${file}${NC}"
      echo -e "  ${DIM}Details:${NC}"
      echo "$out" | sed 's/^/     /'
      echo ""
      return 1
    fi
  fi

  # Fallback: yamllint
  if command -v yamllint &>/dev/null; then
    local out
    if out=$(yamllint -d '{extends: relaxed, rules: {line-length: disable}}' "$file" 2>&1); then
      step_done
      return 0
    else
      step_fail
      echo ""
      echo -e "  ${RED}YAML syntax error:  ${BOLD}${file}${NC}"
      echo "$out" | sed 's/^/     /'
      echo ""
      return 1
    fi
  fi

  echo -e "${YELLOW}⊘  skipped (kubectl + yamllint unavailable)${NC}"
  return 0
}

validate_configs() {
  local failed=false

  section_header "Pre-flight YAML Validation"

  if [ "${TEMPLATE_LABEL:-}" == "with-config" ] && [ -f "${CONFIGMAP_FILE:-}" ]; then
    validate_yaml "$CONFIGMAP_FILE" "configmap (generated)" || failed=true
  fi

  if [ "${HAS_MAPPING:-}" == "true" ]; then
    local tmp_mapping
    tmp_mapping=$(mktemp /tmp/kubeforge-mapping-XXXXXX.yaml)
    envsubst < "templates/mapping.yaml.template" > "$tmp_mapping"
    validate_yaml "$tmp_mapping" "mapping.yaml (rendered)" || failed=true
    rm -f "$tmp_mapping"
  fi

  if [ "${HAS_HPA:-}" == "true" ]; then
    local tmp_hpa
    tmp_hpa=$(mktemp /tmp/kubeforge-hpa-XXXXXX.yaml)
    envsubst < "templates/hpa.yaml.template" > "$tmp_hpa"
    validate_yaml "$tmp_hpa" "hpa.yaml (rendered)" || failed=true
    rm -f "$tmp_hpa"
  fi

  local tmp_deploy
  tmp_deploy=$(mktemp /tmp/kubeforge-deploy-XXXXXX.yaml)
  envsubst < "$TEMPLATE" > "$tmp_deploy"
  validate_yaml "$tmp_deploy" "${TEMPLATE_LABEL:-} deployment (rendered)" || failed=true
  rm -f "$tmp_deploy"

  echo ""
  if [ "$failed" == "true" ]; then
    error_banner "Pre-flight validation failed" "Fix the errors above before deploying"
    exit 1
  fi

  echo -e "  ${GREEN}${BOLD}✔${NC}  ${DIM}All YAML files passed validation${NC}"
  echo ""
}