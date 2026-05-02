#!/bin/bash
# ================================================================
# FILE: generate-configmap.sh
# Generates a versioned ConfigMap from application.<country>.yaml.
# Called by deploy.sh during the configmap step.
# Can also be run standalone:
#   COUNTRY=tz ./generate-configmap.sh <service-name>
# ================================================================

# Resolve k8s/ root before any cd so lib/ui.sh can always be found
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load KubeForge UI for consistent output styling
source "${SCRIPT_DIR}/lib/ui.sh"

# colordiff with graceful fallback to plain diff
diff_side_by_side() {
  if command -v colordiff &>/dev/null; then
    colordiff -y --suppress-common-lines "$@" || true
  else
    diff -y --suppress-common-lines "$@" || true
  fi
}

# ── 1. Resolve SERVICE_NAME ───────────────────────────────────────
if [ -z "${SERVICE_NAME:-}" ]; then
  SERVICE_NAME="${1:-}"
fi

if [ -z "${SERVICE_NAME:-}" ]; then
  echo -e "  ${RED}${BOLD}✖${NC}  SERVICE_NAME not provided"
  echo -e "     ${DIM}Usage: COUNTRY=tz ./generate-configmap.sh <service-name>${NC}"
  exit 1
fi

# ── 2. Locate service directory ───────────────────────────────────
SERVICE_DIR="${SCRIPT_DIR}/services/${SERVICE_NAME}"
if [ ! -d "$SERVICE_DIR" ]; then
  echo -e "  ${RED}${BOLD}✖${NC}  Service directory not found: services/${SERVICE_NAME}"
  exit 1
fi

cd "$SERVICE_DIR" || exit 1

# ── 3. Load config (service.yaml) ────────────────────────────────
# config.sh is sourced from the k8s/ root — it needs SERVICE_DIR set.
source "${SCRIPT_DIR}/lib/config.sh"

if [ ! -f "service.yaml" ]; then
  echo -e "  ${RED}${BOLD}✖${NC}  service.yaml not found in services/${SERVICE_NAME}/"
  echo -e "     ${DIM}Create it: kubeforge ${SERVICE_NAME} --country ${COUNTRY:-<code>} --init${NC}"
  exit 1
fi

load_service_config

CONFIG_VERSION="${CONFIG_VERSION:-v1}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-${SERVICE_NAME}-config}"

for _var in NAMESPACE TAG; do
  if [ -z "${!_var:-}" ]; then
    echo -e "  ${RED}${BOLD}✖${NC}  '${_var}' not set${COUNTRY:+ under countries.${COUNTRY}} in service config"
    exit 1
  fi
done

# ── 4. File setup ─────────────────────────────────────────────────
if [ -n "${COUNTRY:-}" ]; then
  APP_FILE="application.${COUNTRY}.yaml"
else
  APP_FILE="application.yaml"
fi

if [ ! -f "$APP_FILE" ]; then
  if [ -n "${COUNTRY:-}" ]; then
    echo -e "  ${RED}${BOLD}✖${NC}  application.${COUNTRY}.yaml not found in services/${SERVICE_NAME}/"
    echo -e "     ${DIM}→ Create it or scaffold: kubeforge ${SERVICE_NAME} --country ${COUNTRY} --init${NC}"
  else
    echo -e "  ${RED}${BOLD}✖${NC}  application.yaml not found in services/${SERVICE_NAME}/"
    echo -e "     ${DIM}→ Set COUNTRY and create application.<country>.yaml instead${NC}"
  fi
  exit 1
fi

# Generated files go into generated/ subfolder
mkdir -p generated

if [ -n "${COUNTRY:-}" ]; then
  OUTPUT_FILE="generated/configmap.${COUNTRY}.yaml"
  TEMP_FILE="generated/configmap.${COUNTRY}.new.yaml"
else
  OUTPUT_FILE="generated/configmap.yaml"
  TEMP_FILE="generated/configmap.new.yaml"
fi

# Build versioned name — include country so cleanup stays per-country isolated
if [ -n "${COUNTRY:-}" ]; then
  CONFIGMAP_FULL_NAME="${CONFIGMAP_NAME}-${COUNTRY}-${CONFIG_VERSION}-${TAG}"
else
  CONFIGMAP_FULL_NAME="${CONFIGMAP_NAME}-${CONFIG_VERSION}-${TAG}"
fi
CONFIGMAP_FULL_NAME=$(echo "$CONFIGMAP_FULL_NAME" | tr '[:upper:]' '[:lower:]')

# Write CONFIGMAP_FULL_NAME back to countries.<country>.configmap_full_name in service.yaml
write_configmap_full_name "$CONFIGMAP_FULL_NAME"

# ── 5. Generate new ConfigMap YAML ───────────────────────────────
{
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: ${CONFIGMAP_FULL_NAME}"
  echo "  namespace: ${NAMESPACE}"
  echo "data:"
  echo "  application.yaml: |"
  sed 's/^/    /' "${APP_FILE}"
} > "${TEMP_FILE}"

# ── 6. Comparison ─────────────────────────────────────────────────
extract_config() {
  awk '/application.yaml: \|/{flag=1; next} flag'
}

if [ ! -f "${OUTPUT_FILE}" ]; then
  section_header "ConfigMap — First Run"
  echo -e "  ${GREEN}✔${NC}  Creating: ${WHITE}${CONFIGMAP_FULL_NAME}${NC}"
  mv "${TEMP_FILE}" "${OUTPUT_FILE}"
  exit 0
fi

CONTENT_CHANGED=false
if ! diff -q <(extract_config < "${OUTPUT_FILE}") <(extract_config < "${TEMP_FILE}") > /dev/null 2>&1; then
  CONTENT_CHANGED=true
fi

NAME_MATCHES=false
if grep -q "name: ${CONFIGMAP_FULL_NAME}" "${OUTPUT_FILE}" 2>/dev/null; then
  NAME_MATCHES=true
fi

# ── 7. Decision ───────────────────────────────────────────────────
if [ "$CONTENT_CHANGED" = false ] && [ "$NAME_MATCHES" = true ]; then
  echo -e "  ${GREEN}✔${NC}  ${DIM}No changes in content or version — skipping${NC}"
  rm -f "${TEMP_FILE}"
  exit 0
fi

if [ "$CONTENT_CHANGED" = false ] && [ "$NAME_MATCHES" = false ]; then
  section_header "ConfigMap — Name Updated"
  echo -e "  ${CYAN}→${NC}  New name: ${WHITE}${CONFIGMAP_FULL_NAME}${NC}"
  echo -e "     ${DIM}Content unchanged — syncing name to new tag/version${NC}"
  mv "${TEMP_FILE}" "${OUTPUT_FILE}"
  echo -e "  ${GREEN}✔${NC}  Updated: ${OUTPUT_FILE}"
  exit 0
fi

# Content changed — detect structural key changes before showing diff
_extract_keys() {
  awk '/application.yaml: \|/{flag=1; next} flag' "$1" \
    | grep -E '^\s+[a-zA-Z_-]+\s*:' | sed 's/:.*//' | sed 's/^ *//' | sort -u
}
_old_keys=$(_extract_keys "${OUTPUT_FILE}")
_new_keys=$(_extract_keys "${TEMP_FILE}")

_PENDING_CV=""
_PENDING_CFN=""
_CV_BUMPED=""

if [ "$_old_keys" != "$_new_keys" ]; then
  # Compute next config_version (v1 → v2, v3 → v4, etc.)
  _cv_num=$(echo "${CONFIG_VERSION:-v1}" | tr -dc '0-9')
  _cv_num="${_cv_num:-1}"
  _cv_num=$(( _cv_num + 1 ))
  _PENDING_CV="v${_cv_num}"

  # Recompute ConfigMap name with new version
  _PENDING_CFN="${CONFIGMAP_NAME}-${_PENDING_CV}-${TAG}"
  _PENDING_CFN=$(echo "$_PENDING_CFN" | tr '[:upper:]' '[:lower:]')

  # Update name in TEMP_FILE so the diff shows the bumped name
  sed -i "s|^  name: ${CONFIGMAP_FULL_NAME}$|  name: ${_PENDING_CFN}|" "${TEMP_FILE}"

  _CV_BUMPED="${CONFIG_VERSION:-v1} → ${_PENDING_CV}"
fi

section_header "ConfigMap — Content Changes Detected"
echo -e "  ${GREY}Name:${NC} ${WHITE}${_PENDING_CFN:-$CONFIGMAP_FULL_NAME}${NC}"
if [ -n "$_CV_BUMPED" ]; then
  echo -e "  ${CYAN}→${NC}  config_version will auto-bump: ${WHITE}${BOLD}${_CV_BUMPED}${NC}  ${DIM}(keys changed)${NC}"
fi
echo ""
diff_side_by_side "${OUTPUT_FILE}" "${TEMP_FILE}"
echo ""

# Helper: commit the version bump to service.yaml after confirmed apply
_apply_cv_bump() {
  if [ -n "$_PENDING_CV" ]; then
    yq -i ".config_version = \"${_PENDING_CV}\"" service.yaml
    CONFIGMAP_FULL_NAME="$_PENDING_CFN"
    write_configmap_full_name "$CONFIGMAP_FULL_NAME"
    CONFIG_VERSION="$_PENDING_CV"
    echo -e "  ${CYAN}✔${NC}  config_version bumped: ${WHITE}${BOLD}${_CV_BUMPED}${NC}  in service.yaml"
  fi
}

if [ "${CI:-false}" = "true" ]; then
  mv "${TEMP_FILE}" "${OUTPUT_FILE}"
  _apply_cv_bump
  echo -e "  ${GREEN}✔${NC}  ConfigMap updated (CI mode)"
else
  printf "  ${WARN_BG}${BLACK}${BOLD} ? ${NC}  Apply these config changes? ${BOLD}(y/n):${NC} "
  read -r CONFIRM
  if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
    mv "${TEMP_FILE}" "${OUTPUT_FILE}"
    _apply_cv_bump
    echo -e "  ${GREEN}✔${NC}  Updated: ${OUTPUT_FILE}"
  else
    echo -e "  ${YELLOW}⊘${NC}  Aborted — keeping existing config"
    rm -f "${TEMP_FILE}"
    exit 1
  fi
fi