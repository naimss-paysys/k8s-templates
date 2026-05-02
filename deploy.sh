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
source lib/config.sh
source lib/validate.sh
source lib/restart.sh
source lib/create.sh
source lib/audit.sh
source lib/doctor.sh

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

# Capture optional country code for: kubeforge default <code>
_DEFAULT_SET=""
if [ "${SERVICE:-}" = "default" ] && [ -n "${1:-}" ] && [[ "${1:-}" =~ ^[a-z]{2,3}$ ]]; then
  _DEFAULT_SET="$1"
fi

ACTION="--deploy"
COUNTRY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --country|-c)
      COUNTRY="${2:-}"
      shift 2
      ;;
    --deploy|--restart|--rollback|--dry-run|--status|--init|--doctor)
      ACTION="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

export COUNTRY

# ── Auto-load default country if none specified ───────────────────
_KFORGE_CONF="${KUBEFORGE_HOME}/.kubeforge"
_KFORGE_DEFAULT_LOADED=false
if [ -z "$COUNTRY" ] && [ -f "$_KFORGE_CONF" ]; then
  _kf_def=$(grep '^DEFAULT_COUNTRY=' "$_KFORGE_CONF" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
  if [ -n "$_kf_def" ]; then
    COUNTRY="$_kf_def"
    _KFORGE_DEFAULT_LOADED=true
    export COUNTRY
  fi
fi

# ── Show active country in header ─────────────────────────────────
if [ -n "$COUNTRY" ] && [[ "$SERVICE" != "help" && "$SERVICE" != "--help" && "$SERVICE" != "-h" && "$SERVICE" != "default" ]]; then
  if [ "$_KFORGE_DEFAULT_LOADED" = true ]; then
    echo -e "  ${DIM}Country:${NC}  ${WHITE}${BOLD}${COUNTRY}${NC}  ${DIM}(default — override with --country <code>)${NC}"
  else
    echo -e "  ${DIM}Country:${NC}  ${WHITE}${BOLD}${COUNTRY}${NC}"
  fi
  echo ""
fi

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
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC}                               deploy using default country (set with: kubeforge default <code>)"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code>${NC}              deploy for a specific country"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --dry-run${NC}    preview YAML, do not apply"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --rollback${NC}   roll back to previous version"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --restart${NC}    rolling restart"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --status${NC}     show pods, deployment, HPA"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --init${NC}       scaffold country files for a service"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}<service>${NC} ${YELLOW}--country <code> --doctor${NC}     health check: secrets, pods, configmap"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}doctor${NC}                                   connectivity + namespace prerequisites"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}list${NC}                                    list all services with country files"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}history${NC} ${DIM}[N]${NC}                             show last N deploy records  (default 50)"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}default${NC} ${DIM}<code>${NC}                           set default country (e.g. tz, tg)"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}default${NC}                                  show current default country"
  echo -e "     ${WHITE}kubeforge${NC} ${GREEN}help${NC}                                    show this help"
  echo ""
  divider
  echo ""
  echo -e "  ${BOLD}${CYAN}◆  File layout  (per service)${NC}"
  echo -e "  ${DIM}services/<service>/${NC}"
  echo -e "  ${DIM}├── service.yaml          ← single config: image, port, resources, countries${NC}"
  echo -e "  ${DIM}├── application.tz.yaml   ← Tanzania Spring Boot config${NC}"
  echo -e "  ${DIM}├── application.tg.yaml   ← Togo Spring Boot config${NC}"
  echo -e "  ${DIM}└── generated/            ← gitignored, auto-created on deploy${NC}"
  echo -e "  ${DIM}    ├── configmap.tz.yaml${NC}"
  echo -e "  ${DIM}    └── configmap.tg.yaml${NC}"
  echo ""
  divider
  echo ""
  echo -e "  ${BOLD}${CYAN}◆  service.yaml Keys${NC}"
  echo ""
  echo -e "  ${BOLD}${WHITE}Required (top-level)${NC}"
  printf "     ${GREEN}%-22s${NC} %s\n" "name"           "service name (matches Deployment + Service name)"
  printf "     ${GREEN}%-22s${NC} %s\n" "image"          "container image name"
  printf "     ${GREEN}%-22s${NC} %s\n" "port"           "container port"
  printf "     ${GREEN}%-22s${NC} %s\n" "environment"    "test / staging / prod"
  echo ""
  echo -e "  ${BOLD}${WHITE}Required (under countries.<code>)${NC}"
  printf "     ${GREEN}%-22s${NC} %s\n" "namespace"      "kubernetes namespace for this country"
  printf "     ${GREEN}%-22s${NC} %s\n" "tag"            "image tag for this country  (avoid 'latest')"
  echo ""
  echo -e "  ${BOLD}${WHITE}Optional (top-level)${NC}"
  printf "     ${YELLOW}%-22s${NC} %s\n" "replicas"           "pod replicas  (default: 1)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "rollout_timeout"    "seconds before rollout is stuck  (default: 120)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "config_version"     "bump when ConfigMap structure changes  (default: v1)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "resources.cpu"      "request/limit shorthand  e.g. 200m/800m"
  printf "     ${YELLOW}%-22s${NC} %s\n" "resources.memory"   "request/limit shorthand  e.g. 512Mi/1536Mi"
  printf "     ${YELLOW}%-22s${NC} %s\n" "routing.prefix"     "public URL path  (enables Ambassador mapping)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "routing.rewrite"    "path app receives  (almost always /)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "scaling.min"        "minimum pods  (all 4 needed to enable HPA)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "scaling.max"        "maximum pods"
  printf "     ${YELLOW}%-22s${NC} %s\n" "scaling.cpu_threshold"  "CPU %% threshold"
  printf "     ${YELLOW}%-22s${NC} %s\n" "scaling.mem_threshold"  "memory %% threshold"
  echo ""
  echo -e "  ${BOLD}${WHITE}Optional (under countries.<code>)${NC}"
  printf "     ${YELLOW}%-22s${NC} %s\n" "replicas"           "override base replicas for this country"
  printf "     ${YELLOW}%-22s${NC} %s\n" "ambassador_host"    "Ambassador host selector  (e.g. mixxmmp-test.tigo.co.tz)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "host_alias_ip"      "IP for hostAliases in pod  (e.g. 10.245.0.169)"
  printf "     ${YELLOW}%-22s${NC} %s\n" "resources.cpu"      "override base CPU  e.g. 500m/1000m"
  printf "     ${YELLOW}%-22s${NC} %s\n" "resources.memory"   "override base memory  e.g. 1Gi/2Gi"
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

# ── Doctor (cluster-only — no service context) ────────────────────
if [ "$SERVICE" == "doctor" ]; then
  do_doctor
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

    if [ -f "${_svc_dir}/service.yaml" ] && command -v yq &>/dev/null; then
      # ── New format: service.yaml ──────────────────────────────────
      _first=$(yq '.countries | keys | .[0]' "${_svc_dir}/service.yaml" 2>/dev/null)
      if [ -n "$_first" ] && [ "$_first" != "null" ]; then
        _ns=$(yq ".countries.${_first}.namespace" "${_svc_dir}/service.yaml" 2>/dev/null)
        _tag=$(yq ".countries.${_first}.tag"       "${_svc_dir}/service.yaml" 2>/dev/null)
        [ "$_ns"  = "null" ] && _ns="—"
        [ "$_tag" = "null" ] && _tag="—"
      fi
      _countries=$(yq '.countries | keys | .[]' "${_svc_dir}/service.yaml" 2>/dev/null \
        | tr '\n' ' ') || _countries="${DIM}none${NC}"
      _hpa=$(yq '.scaling.min // ""' "${_svc_dir}/service.yaml" 2>/dev/null)
      _pfx=$(yq '.routing.prefix // ""' "${_svc_dir}/service.yaml" 2>/dev/null)
      ls "${_svc_dir}"application.*.yaml &>/dev/null 2>&1 && _has_cm="${GREEN}cm${NC} " || true
      [ -n "$_hpa" ] && [ "$_hpa" != "null" ] && _has_hpa="${CYAN}hpa${NC} "
      [ -n "$_pfx" ] && [ "$_pfx" != "null" ] && _has_map="${YELLOW}map${NC}"

    elif [ -f "${_svc_dir}/values.env" ]; then
      # ── Legacy format: values.env ─────────────────────────────────
      _ns=$(grep  '^NAMESPACE=' "${_svc_dir}/values.env" 2>/dev/null | tail -1 \
        | cut -d= -f2 | tr -d '"' | tr -d "'") || true
      _tag=$(grep '^TAG='       "${_svc_dir}/values.env" 2>/dev/null | tail -1 \
        | cut -d= -f2 | tr -d '"' | tr -d "'") || true
      [ -z "$_ns"  ] && _ns="—"
      [ -z "$_tag" ] && _tag="—"
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

# ── Default country command ───────────────────────────────────────
if [ "$SERVICE" == "default" ]; then
  if [ -n "$_DEFAULT_SET" ]; then
    echo "DEFAULT_COUNTRY=${_DEFAULT_SET}" > "$_KFORGE_CONF"
    echo -e "  ${GREEN}✔${NC}  Default country set to ${WHITE}${BOLD}${_DEFAULT_SET}${NC}"
    echo -e "  ${DIM}Saved: ${_KFORGE_CONF}${NC}"
    echo ""
  else
    if [ -f "$_KFORGE_CONF" ]; then
      _cur=$(grep '^DEFAULT_COUNTRY=' "$_KFORGE_CONF" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
      if [ -n "$_cur" ]; then
        echo -e "  ${CYAN}◆${NC}  Default country: ${WHITE}${BOLD}${_cur}${NC}"
      else
        echo -e "  ${YELLOW}⊘${NC}  No default country set"
      fi
    else
      echo -e "  ${YELLOW}⊘${NC}  No default country set"
    fi
    echo -e "  ${DIM}Set with: kubeforge default <code>  (e.g. tz, tg)${NC}"
    echo ""
  fi
  exit 0
fi

# ── Validate service ──────────────────────────────────────────────
if [ -z "$SERVICE" ]; then
  error_banner "No service name given" "Run:  kubeforge help"
  exit 1
fi

SERVICE_DIR="services/${SERVICE}"
SERVICE_NAME="$SERVICE"

if [ ! -d "$SERVICE_DIR" ]; then
  error_banner "Service not found" "services/${SERVICE}/ does not exist"
  echo -e "  ${DIM}Available services:${NC}"
  ls -d services/*/ | xargs -I{} basename {} | sed 's/^/     /'
  echo ""
  exit 1
fi

# ── Load service config (service.yaml or legacy values.env) ───────
# --init is allowed even when no config exists yet (will scaffold it)
if [ "$ACTION" != "--init" ] || \
   [ -f "${SERVICE_DIR}/service.yaml" ] || [ -f "${SERVICE_DIR}/values.env" ]; then
  load_service_config
fi

# ── Validate country is defined in config ─────────────────────────
if [ -n "$COUNTRY" ] && [ "$ACTION" != "--init" ]; then
  if [ -f "${SERVICE_DIR}/service.yaml" ]; then
    _cnt_check=$(yq ".countries.${COUNTRY}" "${SERVICE_DIR}/service.yaml" 2>/dev/null)
    if [ -z "$_cnt_check" ] || [ "$_cnt_check" = "null" ]; then
      error_banner "Country '${COUNTRY}' not defined" \
        "Add it to ${SERVICE_DIR}/service.yaml under countries:"
      exit 1
    fi
  elif [ ! -f "${SERVICE_DIR}/values.${COUNTRY}.env" ]; then
    error_banner "Country override not found" \
      "values.${COUNTRY}.env missing — run: kubeforge ${SERVICE} --country ${COUNTRY} --init"
    exit 1
  fi
fi

# ── Validate required vars ────────────────────────────────────────
if [ "$ACTION" != "--init" ]; then
  MISSING=""
  [ -z "${SERVICE_NAME:-}" ] && MISSING="${MISSING}\n     name (service.yaml) or SERVICE_NAME"
  [ -z "${IMAGE:-}"        ] && MISSING="${MISSING}\n     image"
  [ -z "${TAG:-}"          ] && MISSING="${MISSING}\n     tag (under countries.${COUNTRY:-base})"
  [ -z "${PORT:-}"         ] && MISSING="${MISSING}\n     port"
  [ -z "${NAMESPACE:-}"    ] && MISSING="${MISSING}\n     namespace (under countries.${COUNTRY:-base})"
  [ -z "${ENVIRONMENT:-}"  ] && MISSING="${MISSING}\n     environment"

  if [ -n "$MISSING" ]; then
    error_banner "Missing required values" "Check ${SERVICE_DIR}/service.yaml"
    echo -e "  ${RED}Missing:${NC}${MISSING}"
    echo ""
    exit 1
  fi
fi

# ── ConfigMap file path (generated/ subfolder) ────────────────────
if [ -n "$COUNTRY" ]; then
  CONFIGMAP_FILE="${SERVICE_DIR}/generated/configmap.${COUNTRY}.yaml"
else
  CONFIGMAP_FILE="${SERVICE_DIR}/generated/configmap.yaml"
fi
export CONFIGMAP_FILE

# ── Pick template ─────────────────────────────────────────────────
# When a country is set, only a country-specific application file qualifies.
# application.yaml is only used when no COUNTRY is provided (country-less deploys).
if [ -n "$COUNTRY" ] && [ -f "${SERVICE_DIR}/application.${COUNTRY}.yaml" ]; then
  TEMPLATE="templates/template-with-config.yaml"
  TEMPLATE_LABEL="with-config"
elif [ -z "$COUNTRY" ] && [ -f "${SERVICE_DIR}/application.yaml" ]; then
  TEMPLATE="templates/template-with-config.yaml"
  TEMPLATE_LABEL="with-config"
else
  TEMPLATE="templates/template-no-config.yaml"
  TEMPLATE_LABEL="no-config"
fi

# ── Concurrent deploy lock (deploy / restart / rollback only) ────
if [[ "$ACTION" =~ ^--(deploy|restart|rollback)$ ]]; then
  _LOCK_FILE="/tmp/kubeforge-${SERVICE_NAME}-${COUNTRY:-base}.lock"
  exec 9>"$_LOCK_FILE"
  if ! flock -n 9; then
    error_banner "Deploy already in progress" \
      "${SERVICE_NAME} [${COUNTRY:-base}] is already being deployed — try again shortly"
    exit 1
  fi
fi

# ── Dispatch ──────────────────────────────────────────────────────
case "$ACTION" in
  --rollback) do_rollback ;;
  --restart)  do_restart  ;;
  --dry-run)  do_dry_run  ;;
  --status)   do_status   ;;
  --init)     do_init     ;;
  --deploy)   do_deploy   ;;
  --doctor)   do_doctor   ;;
  *)
    error_banner "Unknown action: ${ACTION}" \
      "Valid:  --deploy  --restart  --rollback  --dry-run  --status  --init  --doctor"
    exit 1
    ;;
esac