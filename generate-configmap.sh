#!/bin/bash
# ================================================================
# FILE: generate-configmap.sh
# Generates a versioned ConfigMap from application.yaml.
# Called by deploy.sh during the configmap step.
# Can also be run standalone:
#   ./generate-configmap.sh <service-name>
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
  if [ -f "values.env" ]; then
    source values.env
  fi
fi

if [ -z "${SERVICE_NAME:-}" ]; then
  echo -e "  ${RED}${BOLD}✖${NC}  SERVICE_NAME not provided"
  exit 1
fi

# ── 2. Locate service directory ───────────────────────────────────
SERVICE_DIR="${SCRIPT_DIR}/services/${SERVICE_NAME}"
if [ ! -d "$SERVICE_DIR" ]; then
  echo -e "  ${RED}${BOLD}✖${NC}  Service directory not found: services/${SERVICE_NAME}"
  exit 1
fi

cd "$SERVICE_DIR" || exit 1

# ── 3. Load environment & validate ───────────────────────────────
if [ ! -f "values.env" ]; then
  echo -e "  ${RED}${BOLD}✖${NC}  values.env not found in services/${SERVICE_NAME}/"
  exit 1
fi

source values.env

# Country override wins on TAG — must load before building CONFIGMAP_FULL_NAME
if [ -n "${COUNTRY:-}" ] && [ -f "values.${COUNTRY}.env" ]; then
  source "values.${COUNTRY}.env"
fi

CONFIG_VERSION="${CONFIG_VERSION:-v1}"

for _var in CONFIGMAP_NAME NAMESPACE TAG; do
  if [ -z "${!_var:-}" ]; then
    echo -e "  ${RED}${BOLD}✖${NC}  ${_var} not set in values.env"
    exit 1
  fi
done

# ── 4. File setup ─────────────────────────────────────────────────
# Country-specific application.yaml takes priority over base.
if [ -n "${COUNTRY:-}" ] && [ -f "application.${COUNTRY}.yaml" ]; then
  APP_FILE="application.${COUNTRY}.yaml"
else
  APP_FILE="application.yaml"
fi

# Output and temp files are country-scoped when COUNTRY is set.
if [ -n "${COUNTRY:-}" ]; then
  OUTPUT_FILE="configmap.${COUNTRY}.yaml"
  TEMP_FILE="configmap.${COUNTRY}.new.yaml"
else
  OUTPUT_FILE="configmap.yaml"
  TEMP_FILE="configmap.new.yaml"
fi

if [ ! -f "$APP_FILE" ]; then
  echo -e "  ${RED}${BOLD}✖${NC}  ${APP_FILE} not found in services/${SERVICE_NAME}/"
  exit 1
fi

# Build versioned name — TAG is now always correct (country override loaded above)
CONFIGMAP_FULL_NAME="${CONFIGMAP_NAME}-${CONFIG_VERSION}-${TAG}"
CONFIGMAP_FULL_NAME=$(echo "$CONFIGMAP_FULL_NAME" | tr '[:upper:]' '[:lower:]')

# Write CONFIGMAP_FULL_NAME to the env file that owns this country's TAG:
#   country deploy  → values.<country>.env  (keeps base file untouched)
#   base deploy     → values.env
if [ -n "${COUNTRY:-}" ] && [ -f "values.${COUNTRY}.env" ]; then
  _TARGET_ENV="values.${COUNTRY}.env"
else
  _TARGET_ENV="values.env"
fi

if grep -q '^CONFIGMAP_FULL_NAME=' "$_TARGET_ENV" 2>/dev/null; then
  sed -i "s|^CONFIGMAP_FULL_NAME=.*|CONFIGMAP_FULL_NAME=${CONFIGMAP_FULL_NAME}|" "$_TARGET_ENV"
else
  echo "CONFIGMAP_FULL_NAME=${CONFIGMAP_FULL_NAME}" >> "$_TARGET_ENV"
fi

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

# Content changed — show diff and prompt
section_header "ConfigMap — Content Changes Detected"
echo -e "  ${GREY}Name:${NC} ${WHITE}${CONFIGMAP_FULL_NAME}${NC}"
echo ""
diff_side_by_side "${OUTPUT_FILE}" "${TEMP_FILE}"
echo ""

if [ "${CI:-false}" = "true" ]; then
  mv "${TEMP_FILE}" "${OUTPUT_FILE}"
  echo -e "  ${GREEN}✔${NC}  ConfigMap updated (CI mode)"
else
  printf "  ${WARN_BG}${BLACK}${BOLD} ? ${NC}  Apply these config changes? ${BOLD}(y/n):${NC} "
  read -r CONFIRM
  if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
    mv "${TEMP_FILE}" "${OUTPUT_FILE}"
    echo -e "  ${GREEN}✔${NC}  Updated: ${OUTPUT_FILE}"
  else
    echo -e "  ${YELLOW}⊘${NC}  Aborted — keeping existing config"
    rm -f "${TEMP_FILE}"
    exit 1
  fi
fi