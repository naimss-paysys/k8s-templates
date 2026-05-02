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

check_image_exists() {
  # Extract registry prefix from whichever template is in use
  local _registry
  _registry=$(grep -m1 'image:.*\$IMAGE' "${KUBEFORGE_HOME}/${TEMPLATE}" \
    2>/dev/null | sed 's/.*image:[[:space:]]*//' | sed 's/\$IMAGE.*//')

  [ -z "$_registry" ] && return 0

  local _registry_host="${_registry%/}"
  local _full_image="${_registry}${IMAGE}:${TAG}"

  printf "  ${DIM}[validate]${NC}  %-40s" "image: ${IMAGE}:${TAG}"

  # Method 1 — docker manifest inspect (no full pull, just fetches manifest)
  if command -v docker &>/dev/null; then
    local _out
    if _out=$(docker manifest inspect "${_full_image}" 2>&1); then
      step_done
      return 0
    fi
    if echo "$_out" | grep -qiE "not found|manifest unknown|no such manifest|404"; then
      step_fail
      echo ""
      echo -e "  ${RED}Image not found:${NC}  ${WHITE}${_full_image}${NC}"
      echo -e "  ${DIM}Check that tag '${TAG}' was pushed to the registry${NC}"
      return 1
    fi
    # Auth / network error — fall through to method 2
  fi

  # Method 2 — registry API via curl + credentials from imagePullSecret
  if command -v curl &>/dev/null; then
    local _auth _status
    _auth=$(kubectl get secret my-registry-secret -n "$NAMESPACE" \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
      | base64 -d 2>/dev/null \
      | grep -o '"auth":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -n "$_auth" ]; then
      _status=$(curl -sk -o /dev/null -w "%{http_code}" \
        -H "Authorization: Basic ${_auth}" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://${_registry_host}/v2/${IMAGE}/manifests/${TAG}" \
        2>/dev/null) || _status="000"

      if [ "$_status" = "200" ] || [ "$_status" = "201" ]; then
        step_done
        return 0
      elif [ "$_status" = "404" ]; then
        step_fail
        echo ""
        echo -e "  ${RED}Image not found:${NC}  ${WHITE}${_full_image}${NC}"
        echo -e "  ${DIM}Tag '${TAG}' does not exist — check what was pushed to the registry${NC}"
        return 1
      fi
    fi
  fi

  # Could not verify — warn and skip (don't block deploy)
  echo -e "${YELLOW}⊘  skipped (docker not authenticated / registry unreachable)${NC}"
  return 0
}

validate_configs() {
  local failed=false

  section_header "Pre-flight Validation"

  check_image_exists || failed=true

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

  echo -e "  ${GREEN}${BOLD}✔${NC}  ${DIM}All pre-flight checks passed${NC}"
  echo ""
}