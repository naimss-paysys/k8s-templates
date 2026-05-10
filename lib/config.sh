#!/bin/bash
# ================================================================
# FILE: lib/config.sh
# Loads service config from service.yaml (new format) or falls
# back to values.env / values.<country>.env (legacy format).
# Exports all variables that templates and deploy steps expect.
# Requires lib/ui.sh.
# ================================================================

# ── yq guard ──────────────────────────────────────────────────────
_yq_check() {
  if ! command -v yq &>/dev/null; then
    echo -e "  ${RED}✖${NC}  'yq' is required to parse service.yaml"
    echo -e "     ${DIM}→ sudo wget -qO /usr/local/bin/yq \\${NC}"
    echo -e "          ${DIM}https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64${NC}"
    echo -e "     ${DIM}→ sudo chmod +x /usr/local/bin/yq${NC}"
    exit 1
  fi
}

# yq wrapper — converts "null" output to empty string
_yq() {
  local result
  result=$(yq "$@" 2>/dev/null)
  [ "$result" = "null" ] && echo "" || echo "$result"
}

# Parse "500m/1000m" → request (before /) or limit (after /)
_res_request() { echo "${1%%/*}"; }
_res_limit()   { echo "${1##*/}"; }

# ── Entry point ───────────────────────────────────────────────────
# Call after SERVICE_DIR and COUNTRY are set.
load_service_config() {
  if [ -f "${SERVICE_DIR}/service.yaml" ]; then
    _load_yaml
  elif [ -f "${SERVICE_DIR}/values.env" ]; then
    _load_env
  else
    error_banner "No config found" \
      "Create ${SERVICE_DIR}/service.yaml (run: kubeforge ${SERVICE_NAME} --country <code> --init)"
    exit 1
  fi
  _set_feature_flags
}

# ── YAML loader (service.yaml) ────────────────────────────────────
_load_yaml() {
  _yq_check
  local f="${SERVICE_DIR}/service.yaml"

  # Base — shared across all countries
  SERVICE_NAME=$(_yq '.name'                      "$f")
  IMAGE=$(_yq        '.image'                     "$f")
  PORT=$(_yq         '.port'                      "$f")
  CONFIG_VERSION=$(_yq '.config_version // "v1"'  "$f")
  CONFIGMAP_NAME="${SERVICE_NAME}-config"
  NAMESPACE=$(_yq      '.namespace     // ""'     "$f")
  TAG=$(_yq            '.tag           // ""'     "$f")
  REPLICAS=$(_yq       '.replicas      // 1'      "$f")
  HOST_ALIAS_IP=$(_yq  '.host_alias_ip // ""'     "$f")
  TLS_SECRET=$(_yq     '.tls_secret   // ""'      "$f")
  ROLLOUT_TIMEOUT=$(_yq '.rollout_timeout // 120' "$f")

  # Routing
  PREFIX=$(_yq  '.routing.prefix  // ""' "$f")
  REWRITE=$(_yq '.routing.rewrite // ""' "$f")

  # Scaling
  HPA_MIN=$(_yq           '.scaling.min           // ""' "$f")
  HPA_MAX=$(_yq           '.scaling.max           // ""' "$f")
  HPA_CPU_THRESHOLD=$(_yq '.scaling.cpu_threshold // ""' "$f")
  HPA_MEM_THRESHOLD=$(_yq '.scaling.mem_threshold // ""' "$f")

  # Base resources
  local base_cpu base_mem
  base_cpu=$(_yq '.resources.cpu    // ""' "$f")
  base_mem=$(_yq '.resources.memory // ""' "$f")

  # Country block — only ambassador_host, tls_secret, configmap_full_name, previous_tag
  # namespace / tag / replicas / host_alias_ip can still be overridden per country if needed
  AMBASSADOR_HOST="" CONFIGMAP_FULL_NAME=""
  if [ -n "${COUNTRY:-}" ]; then
    AMBASSADOR_HOST=$(_yq ".countries.${COUNTRY}.ambassador_host     // \"\"" "$f")
    CONFIGMAP_FULL_NAME=$(_yq ".countries.${COUNTRY}.configmap_full_name // \"\"" "$f")

    local c_namespace c_tag c_host_alias_ip c_tls c_replicas
    c_namespace=$(_yq   ".countries.${COUNTRY}.namespace     // \"\"" "$f")
    c_tag=$(_yq         ".countries.${COUNTRY}.tag           // \"\"" "$f")
    c_host_alias_ip=$(_yq ".countries.${COUNTRY}.host_alias_ip // \"\"" "$f")
    c_tls=$(_yq         ".countries.${COUNTRY}.tls_secret    // \"\"" "$f")
    c_replicas=$(_yq    ".countries.${COUNTRY}.replicas      // \"\"" "$f")

    [ -n "$c_namespace"    ] && NAMESPACE="$c_namespace"
    [ -n "$c_tag"          ] && TAG="$c_tag"
    [ -n "$c_host_alias_ip" ] && HOST_ALIAS_IP="$c_host_alias_ip"
    [ -n "$c_tls"          ] && TLS_SECRET="$c_tls"
    [ -n "$c_replicas"     ] && REPLICAS="$c_replicas"

    # Resources: country value wins, falls back to base
    local c_cpu c_mem
    c_cpu=$(_yq ".countries.${COUNTRY}.resources.cpu    // \"\"" "$f")
    c_mem=$(_yq ".countries.${COUNTRY}.resources.memory // \"\"" "$f")
    local eff_cpu="${c_cpu:-$base_cpu}"
    local eff_mem="${c_mem:-$base_mem}"

    CPU_REQUEST=$(_res_request "$eff_cpu")
    CPU_LIMIT=$(_res_limit     "$eff_cpu")
    MEMORY_REQUEST=$(_res_request "$eff_mem")
    MEMORY_LIMIT=$(_res_limit     "$eff_mem")
  else
    CPU_REQUEST=$(_res_request "$base_cpu")
    CPU_LIMIT=$(_res_limit     "$base_cpu")
    MEMORY_REQUEST=$(_res_request "$base_mem")
    MEMORY_LIMIT=$(_res_limit     "$base_mem")
  fi

  SERVICE_CONFIG_FORMAT="yaml"
  _export_vars
}

# ── ENV loader (legacy values.env) ───────────────────────────────
_load_env() {
  set -a
  source "${SERVICE_DIR}/values.env"
  [ -n "${COUNTRY:-}" ] && [ -f "${SERVICE_DIR}/values.${COUNTRY}.env" ] && \
    source "${SERVICE_DIR}/values.${COUNTRY}.env"
  set +a
  SERVICE_CONFIG_FORMAT="env"
  _export_vars
}

# ── Write CONFIGMAP_FULL_NAME back to the config file ─────────────
# Called by generate-configmap.sh after computing the versioned name.
write_configmap_full_name() {
  local cfn="$1"
  if [ "${SERVICE_CONFIG_FORMAT:-env}" = "yaml" ]; then
    if [ -n "${COUNTRY:-}" ]; then
      yq -i ".countries.${COUNTRY}.configmap_full_name = \"${cfn}\"" \
        "${SERVICE_DIR}/service.yaml"
    fi
  else
    local target_env="${SERVICE_DIR}/values.env"
    [ -n "${COUNTRY:-}" ] && [ -f "${SERVICE_DIR}/values.${COUNTRY}.env" ] && \
      target_env="${SERVICE_DIR}/values.${COUNTRY}.env"
    if grep -q '^CONFIGMAP_FULL_NAME=' "$target_env" 2>/dev/null; then
      sed -i "s|^CONFIGMAP_FULL_NAME=.*|CONFIGMAP_FULL_NAME=${cfn}|" "$target_env"
    else
      [ -s "$target_env" ] && [ -n "$(tail -c1 "$target_env")" ] && echo >> "$target_env"
      echo "CONFIGMAP_FULL_NAME=${cfn}" >> "$target_env"
    fi
  fi
}

# ── Export all template variables ─────────────────────────────────
_export_vars() {
  export SERVICE_NAME IMAGE TAG PORT NAMESPACE
  export PREFIX="${PREFIX:-}"               REWRITE="${REWRITE:-}"
  export HPA_MIN="${HPA_MIN:-}"             HPA_MAX="${HPA_MAX:-}"
  export HPA_CPU_THRESHOLD="${HPA_CPU_THRESHOLD:-}" HPA_MEM_THRESHOLD="${HPA_MEM_THRESHOLD:-}"
  export CPU_REQUEST="${CPU_REQUEST:-}"     MEMORY_REQUEST="${MEMORY_REQUEST:-}"
  export CPU_LIMIT="${CPU_LIMIT:-}"         MEMORY_LIMIT="${MEMORY_LIMIT:-}"
  export CONFIGMAP_NAME="${CONFIGMAP_NAME:-}"
  export CONFIGMAP_FULL_NAME="${CONFIGMAP_FULL_NAME:-}"
  export CONFIG_VERSION="${CONFIG_VERSION:-v1}"
  export ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120}"
  export REPLICAS="${REPLICAS:-1}"
  export AMBASSADOR_HOST="${AMBASSADOR_HOST:-}"
  export HOST_ALIAS_IP="${HOST_ALIAS_IP:-}"
  export TLS_SECRET="${TLS_SECRET:-}"
  export SERVICE_CONFIG_FORMAT="${SERVICE_CONFIG_FORMAT:-env}"
}

# ── Feature flags (HAS_MAPPING, HAS_HPA) ─────────────────────────
_set_feature_flags() {
  if [ -n "${PREFIX:-}" ] && [ -n "${REWRITE:-}" ]; then
    HAS_MAPPING=true
  else
    HAS_MAPPING=false
  fi

  if [ -n "${HPA_MIN:-}" ] && [ -n "${HPA_MAX:-}" ] && \
     [ -n "${HPA_CPU_THRESHOLD:-}" ] && [ -n "${HPA_MEM_THRESHOLD:-}" ]; then
    HAS_HPA=true
  else
    HAS_HPA=false
  fi

  export HAS_MAPPING HAS_HPA
}