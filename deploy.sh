#!/bin/bash
# ================================================================
# FILE: deploy.sh  (KubeForge entry point)
# Always run from the k8s/ folder, or use the global wrapper:
#   kubeforge <service> [--country <code>] [action]
#
# Usage:
#   kubeforge <service>                         deploy (default country)
#   kubeforge <service> --country tg            deploy for Togo
#   kubeforge <service> --country tz --restart  restart Tanzania pods
#   kubeforge <service> --country tg --dry-run  preview Togo YAML
#   kubeforge <service> --country tz --status   show pods / HPA
#   kubeforge list                              list all services
#   kubeforge help                              show this help
# ================================================================

set -euo pipefail

# Resolve k8s/ root — works whether called as ./deploy.sh or via symlink
KUBEFORGE_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$KUBEFORGE_HOME"

# ── Load all library modules ──────────────────────────────────────
source lib/ui.sh
source lib/validate.sh
source lib/restart.sh
source lib/create.sh
source lib/audit.sh

# ── Audit state — must be set before any early exit ───────────────
_KFORGE_START=0
_KFORGE_STATUS="FAILED"

# ── Clean up temp files and write audit log on any exit ──────────
trap 'rm -f /tmp/kubeforge-*.log /tmp/kubeforge-*.yaml 2>/dev/null || true
      [[ "${ACTION:-}" =~ ^--(deploy|restart|rollback)$ ]] && log_audit "${ACTION#--}" "$_KFORGE_STATUS" "$(( $(date +%s) - _KFORGE_START ))"' EXIT

# ── Boot banner ───────────────────────────────────────────────────
boot_banner

# ── Arg parsing (named flags, order-independent) ──────────────────
SERVICE="${1:-}"
shift || true

# Capture optional history count before the flag loop consumes it
_HISTORY_LIMIT=50
if [ "${SERVICE:-}" = "history" ] && [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  _HISTORY_LIMIT="$1"
fi

ACTION="--deploy"
COUNTRY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --country|-c)
      COUNTRY="${2:-}"
      shift 2
      ;;
    --deploy|--restart|--rollback|--dry-run|--status|--init)
      ACTION="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

export COUNTRY

# ── Start timing after arg parsing ───────────────────────────────
_KFORGE_START=$(date +%s)

# ── Help ──────────────────────────────────────────────────────────
if [[ "$SERVICE" == "help" || "$SERVICE" == "--help" || "$SERVICE" == "-h" ]]; then
  echo ""
  echo -e "  ${BOLD}${WHITE}kubeforge${NC}  ${DIM}—  Multi-country Kubernetes deployment${NC}"
  echo ""
  divider
  echo ""
  echo -e "  ${BOLD}${CYAN}◆  Usage${NC}"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC}                               deploy (no country = base values.env)"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code>${NC}              deploy for a specific country"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --dry-run${NC}    preview YAML, do not apply"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --rollback${NC}   roll back to previous version"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --restart${NC}    rolling restart"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --status${NC}     show pods, deployment, HPA"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --init${NC}      scaffold country files for a service"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}list${NC}                                    list all services with country files"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}history${NC} ${DIM}[N]${NC}                             show last N deploy records  (default 50)"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}help${NC}                                    show this help"
  echo ""
  divider
  echo ""
  echo -e "  ${BOLD}${CYAN}◆  Country file layout  (per service)${NC}"
  echo -e "  ${DIM}services/<service>/${NC}"
  echo -e "  ${DIM}├── values.env            ← base: SERVICE_NAME PORT PREFIX HPA resources${NC}"
  echo -e "  ${DIM}├── values.tz.env         ← Tanzania override: NAMESPACE TAG${NC}"
  echo -e "  ${DIM}├── values.tg.env         ← Togo override: NAMESPACE TAG${NC}"
  echo -e "  ${DIM}├── application.yaml      ← (legacy base)${NC}"
  echo -e "  ${DIM}├── application.tz.yaml   ← Tanzania app config${NC}"
  echo -e "  ${DIM}├── application.tg.yaml   ← Togo app config${NC}"
  echo -e "  ${DIM}├── configmap.tz.yaml     ← generated for Tanzania${NC}"
  echo -e "  ${DIM}└── configmap.tg.yaml     ← generated for Togo${NC}"
  echo ""
  divider
  echo ""
  echo -e "  ${BOLD}${CYAN}◆  values.env Keys${NC}"
  echo ""
  echo -e "  ${BOLD}${WHITE}Required (base values.env)${NC}"
  printf "     ${GREEN}%-22s${NC} %s\n" "SERVICE_NAME"  "service name"
  printf "     ${GREEN}%-22s${NC} %s\n" "IMAGE"         "image name"
  printf "     ${GREEN}%-22s${NC} %s\n" "PORT"          "container port"
  printf "     ${GREEN}%-22s${NC} %s\n" "ENVIRONMENT"   "test / staging / prod"
  echo ""
  echo -e "  ${BOLD}${WHITE}Required (country override file, e.g. values.tz.env)${NC}"
  printf "     ${GREEN}%-22s${NC} %s\n" "NAMESPACE"     "kubernetes namespace for this country"
  printf "     ${GREEN}%-22s${NC} %s\n" "TAG"           "image tag for this country  (avoid 'latest')"
  echo ""
  echo -e "  ${BOLD}${WHITE}Optional${NC}"
  printf "     ${YELLOW}%-22s${NC} %s\n" "REPLICAS"           "pod replicas  (default: 1, recommend 2 for banking)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "AMBASSADOR_HOST"    "Ambassador routing host  (e.g. mixxmmp-test.tigo.co.tz)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "HOST_ALIAS_IP"      "IP for hostAliases  (e.g. 10.245.0.169)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "ROLLOUT_TIMEOUT"    "seconds to wait for rollout  (default: 120)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "PREFIX"             "public URL path  (enables mapping)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "REWRITE"            "path app receives  (enables mapping)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "HPA_MIN"            "minimum pods  (all 4 needed to enable HPA)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "HPA_MAX"            "maximum pods"
  printf "     ${YELLOW}%-22s${NC} %s\n" "HPA_CPU_THRESHOLD"  "CPU %% threshold"
  printf "     ${YELLOW}%-22s${NC} %s\n" "HPA_MEM_THRESHOLD"  "memory %% threshold"
  echo ""
  divider
  echo ""
  exit 0
fi

# ── History ───────────────────────────────────────────────────────
if [ "$SERVICE" == "history" ]; then
  do_history "$_HISTORY_LIMIT"
  exit 0
fi

# ── List (enhanced — shows country files per service) ─────────────
if [ "$SERVICE" == "list" ]; then
  echo ""
  echo -e "  ${BOLD}${CYAN}◆  Available Services${NC}"
  divider
  echo ""
  printf "  ${BOLD}  %-34s  %-18s  %-14s  %-12s  %s${NC}\n" \
    "SERVICE" "NAMESPACE" "TAG" "COUNTRIES" "FEATURES"
  echo ""
  for _svc_dir in services/*/; do
    _svc=$(basename "$_svc_dir")
    _ns="—" ; _tag="—" ; _countries="" ; _has_cm="" ; _has_hpa="" ; _has_map=""

    if [ -f "${_svc_dir}/values.env" ]; then
      _ns=$(grep  '^NAMESPACE=' "${_svc_dir}/values.env" 2>/dev/null | tail -1 \
        | cut -d= -f2 | tr -d '"' | tr -d "'") || true
      _tag=$(grep '^TAG='       "${_svc_dir}/values.env" 2>/dev/null | tail -1 \
        | cut -d= -f2 | tr -d '"' | tr -d "'") || true
      [ -z "$_ns"  ] && _ns="—"
      [ -z "$_tag" ] && _tag="—"

      # Detect country override files
      for _cf in "${_svc_dir}"values.*.env; do
        [ -f "$_cf" ] || continue
        _code=$(basename "$_cf" | sed 's/values\.\(.*\)\.env/\1/')
        _countries="${_countries}${_code} "
      done
      [ -z "$_countries" ] && _countries="${DIM}base only${NC}"

      [ -f "${_svc_dir}/application.yaml" ] && _has_cm="${GREEN}cm${NC} "
      grep -q '^HPA_MIN=' "${_svc_dir}/values.env" 2>/dev/null && _has_hpa="${CYAN}hpa${NC} " || true
      grep -q '^PREFIX='  "${_svc_dir}/values.env" 2>/dev/null && _has_map="${YELLOW}map${NC}" || true
    fi

    printf "  ${GREEN}▸${NC}  %-34s  ${DIM}%-18s${NC}  ${WHITE}%-14s${NC}  " "$_svc" "$_ns" "$_tag"
    echo -e "${_countries}  ${_has_cm}${_has_hpa}${_has_map}"
  done
  echo ""
  exit 0
fi

# ── Validate service ──────────────────────────────────────────────
if [ -z "$SERVICE" ]; then
  error_banner "No service name given" "Run:  kubeforge help"
  exit 1
fi

SERVICE_DIR="services/${SERVICE}"
ENV_FILE="${SERVICE_DIR}/values.env"

if [ ! -d "$SERVICE_DIR" ]; then
  error_banner "Service not found" "services/${SERVICE}/ does not exist"
  echo -e "  ${DIM}Available services:${NC}"
  ls -d services/*/ | xargs -I{} basename {} | sed 's/^/     /'
  echo ""
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  error_banner "values.env missing" "${ENV_FILE} is required"
  exit 1
fi

# ── Load base values ──────────────────────────────────────────────
set -a
source "$ENV_FILE"
set +a

# ── Load country override (merges on top of base, wins on conflict) ─
if [ -n "$COUNTRY" ]; then
  COUNTRY_ENV_FILE="${SERVICE_DIR}/values.${COUNTRY}.env"
  if [ ! -f "$COUNTRY_ENV_FILE" ]; then
    error_banner "Country override not found" \
      "${COUNTRY_ENV_FILE} does not exist — create it with NAMESPACE and TAG for country '${COUNTRY}'"
    exit 1
  fi
  set -a
  source "$COUNTRY_ENV_FILE"
  set +a
fi

# ── Set country-specific file paths ──────────────────────────────
if [ -n "$COUNTRY" ]; then
  CONFIGMAP_FILE="${SERVICE_DIR}/configmap.${COUNTRY}.yaml"
else
  CONFIGMAP_FILE="${SERVICE_DIR}/configmap.yaml"
fi

export SERVICE_NAME IMAGE TAG PORT NAMESPACE ENVIRONMENT
export PREFIX="${PREFIX:-}" REWRITE="${REWRITE:-}"
export HPA_MIN="${HPA_MIN:-}" HPA_MAX="${HPA_MAX:-}"
export HPA_CPU_THRESHOLD="${HPA_CPU_THRESHOLD:-}" HPA_MEM_THRESHOLD="${HPA_MEM_THRESHOLD:-}"
export CPU_REQUEST="${CPU_REQUEST:-}" MEMORY_REQUEST="${MEMORY_REQUEST:-}"
export CPU_LIMIT="${CPU_LIMIT:-}" MEMORY_LIMIT="${MEMORY_LIMIT:-}"
export CONFIGMAP_NAME="${CONFIGMAP_NAME:-}"
export CONFIGMAP_FULL_NAME="${CONFIGMAP_FULL_NAME:-}"
export ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120}"
export CONFIGMAP_FILE
export REPLICAS="${REPLICAS:-1}"
export AMBASSADOR_HOST="${AMBASSADOR_HOST:-}"
export HOST_ALIAS_IP="${HOST_ALIAS_IP:-}"

# ── Validate required vars ────────────────────────────────────────
MISSING=""
[ -z "${SERVICE_NAME:-}" ] && MISSING="${MISSING}\n     SERVICE_NAME"
[ -z "${IMAGE:-}"        ] && MISSING="${MISSING}\n     IMAGE"
[ -z "${TAG:-}"          ] && MISSING="${MISSING}\n     TAG"
[ -z "${PORT:-}"         ] && MISSING="${MISSING}\n     PORT"
[ -z "${NAMESPACE:-}"    ] && MISSING="${MISSING}\n     NAMESPACE"
[ -z "${ENVIRONMENT:-}"  ] && MISSING="${MISSING}\n     ENVIRONMENT"

if [ -n "$MISSING" ]; then
  error_banner "Missing required vars" \
    "Check values.env${COUNTRY:+ and values.${COUNTRY}.env}"
  echo -e "  ${RED}Missing:${NC}${MISSING}"
  echo ""
  exit 1
fi

# ── Feature flags ─────────────────────────────────────────────────
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

# ── Pick template ─────────────────────────────────────────────────
# Country-specific application.yaml takes priority over base.
if [ -n "$COUNTRY" ] && [ -f "${SERVICE_DIR}/application.${COUNTRY}.yaml" ]; then
  TEMPLATE="templates/template-with-config.yaml"
  TEMPLATE_LABEL="with-config"
elif [ -f "${SERVICE_DIR}/application.yaml" ]; then
  TEMPLATE="templates/template-with-config.yaml"
  TEMPLATE_LABEL="with-config"
else
  TEMPLATE="templates/template-no-config.yaml"
  TEMPLATE_LABEL="no-config"
fi

# ── Dispatch ──────────────────────────────────────────────────────
case "$ACTION" in
  --rollback) do_rollback ;;
  --restart)  do_restart  ;;
  --dry-run)  do_dry_run  ;;
  --status)   do_status   ;;
  --init)     do_init     ;;
  --deploy)   do_deploy   ;;
  *)
    error_banner "Unknown action: ${ACTION}" \
      "Valid:  --deploy  --restart  --rollback  --dry-run  --status  --init"
    exit 1
    ;;
esac