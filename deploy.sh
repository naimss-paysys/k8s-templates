#!/bin/bash
# ================================================================
# FILE: deploy.sh
# LOCATION: k8s/ -- always run from this folder
# ================================================================

set -e

# ── Colors & styles ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # reset

# ── Helpers ───────────────────────────────────────────────────────
banner() {
  local title="$1"
  local line="$2"
  local line2="$3"
  local line3="$4"
  local line4="$5"
  local width=50
  echo ""
  echo -e "${BLUE}${BOLD}  ╔$(printf '═%.0s' $(seq 1 $width))╗${NC}"
  printf "${BLUE}${BOLD}  ║${NC}  %-${width}s${BLUE}${BOLD}║${NC}\n" "$title"
  [ -n "$line"  ] && printf "${BLUE}${BOLD}  ║${NC}  ${DIM}%-${width}s${BLUE}${BOLD}${NC}${BLUE}${BOLD}║${NC}\n" "$line"
  [ -n "$line2" ] && printf "${BLUE}${BOLD}  ║${NC}  ${DIM}%-${width}s${BLUE}${BOLD}${NC}${BLUE}${BOLD}║${NC}\n" "$line2"
  [ -n "$line3" ] && printf "${BLUE}${BOLD}  ║${NC}  ${DIM}%-${width}s${BLUE}${BOLD}${NC}${BLUE}${BOLD}║${NC}\n" "$line3"
  [ -n "$line4" ] && printf "${BLUE}${BOLD}  ║${NC}  ${DIM}%-${width}s${BLUE}${BOLD}${NC}${BLUE}${BOLD}║${NC}\n" "$line4"
  echo -e "${BLUE}${BOLD}  ╚$(printf '═%.0s' $(seq 1 $width))╝${NC}"
  echo ""
}

success_banner() {
  local msg="$1"
  local sub="$2"
  local width=50
  echo ""
  echo -e "${GREEN}${BOLD}  ╔$(printf '═%.0s' $(seq 1 $width))╗${NC}"
  printf "${GREEN}${BOLD}  ║${NC}  ${GREEN}${BOLD}✔  %-${width}s${GREEN}${BOLD}║${NC}\n" "$msg"
  [ -n "$sub" ] && printf "${GREEN}${BOLD}  ║${NC}     ${DIM}%-$((width-3))s${GREEN}${BOLD}║${NC}\n" "$sub"
  echo -e "${GREEN}${BOLD}  ╚$(printf '═%.0s' $(seq 1 $width))╝${NC}"
  echo ""
}

error_banner() {
  local msg="$1"
  local sub="$2"
  local width=50
  echo ""
  echo -e "${RED}${BOLD}  ╔$(printf '═%.0s' $(seq 1 $width))╗${NC}"
  printf "${RED}${BOLD}  ║${NC}  ${RED}${BOLD}✖  %-${width}s${RED}${BOLD}║${NC}\n" "$msg"
  [ -n "$sub" ] && printf "${RED}${BOLD}  ║${NC}     ${DIM}%-$((width-3))s${RED}${BOLD}║${NC}\n" "$sub"
  echo -e "${RED}${BOLD}  ╚$(printf '═%.0s' $(seq 1 $width))╝${NC}"
  echo ""
}

step() {
  local num="$1"
  local total="$2"
  local msg="$3"
  printf "  ${BOLD}[${num}/${total}]${NC}  %-35s" "$msg"
}

step_done()    { echo -e "${GREEN}✔ done${NC}"; }
step_skipped() { echo -e "${YELLOW}⊘ skipped${NC}"; }
step_fail()    { echo -e "${RED}✖ failed${NC}"; }

# ── Args ──────────────────────────────────────────────────────────
SERVICE=$1
ACTION=${2:-"--deploy"}
SERVICE_DIR="services/${SERVICE}"
ENV_FILE="${SERVICE_DIR}/values.env"
CONFIGMAP_FILE="${SERVICE_DIR}/configmap.yaml"

# ── Help ──────────────────────────────────────────────────────────
if [ "$SERVICE" == "help" ] || [ "$SERVICE" == "--help" ] || [ "$SERVICE" == "-h" ]; then
  echo ""
  echo -e "  ${BOLD}deploy.sh${NC} -- deploy a service to Kubernetes"
  echo ""
  echo -e "  ${BOLD}LOCATION${NC}"
  echo "    Always run from the k8s/ folder:"
  echo "      cd k8s && ./deploy.sh <service-name>"
  echo ""
  echo -e "  ${BOLD}USAGE${NC}"
  echo "    ./deploy.sh <service>               deploy service"
  echo "    ./deploy.sh <service> --dry-run     preview YAML, do not apply"
  echo "    ./deploy.sh <service> --rollback    roll back to previous version"
  echo "    ./deploy.sh <service> --restart     restart pods without new image"
  echo "    ./deploy.sh list                    list all available services"
  echo "    ./deploy.sh help                    show this help"
  echo ""
  echo -e "  ${BOLD}OPTIONAL FILE${NC} (per service, only if needed)"
  echo "    configmap.yaml   application.yaml for Spring Boot services"
  echo "                     skip for GUI/frontend services"
  echo ""
  echo -e "  ${BOLD}MAPPING (Ambassador routing)${NC}"
  echo "    No file needed per service."
  echo "    Just add PREFIX and REWRITE to values.env -- mapping"
  echo "    is applied from k8s/templates/mapping.yaml.template automatically."
  echo "    Leave PREFIX/REWRITE out of values.env to skip mapping."
  echo ""
  echo -e "  ${BOLD}FOLDER STRUCTURE${NC}"
  echo "    k8s/"
  echo "    ├── deploy.sh"
  echo "    ├── templates/"
  echo "    │   ├── template-with-config.yaml"
  echo "    │   ├── template-no-config.yaml"
  echo "    │   ├── mapping.yaml.template"
  echo "    │   └── hpa.yaml.template"
  echo "    └── services/"
  echo "        ├── dashboard-backoffice/    Spring Boot with mapping"
  echo "        │   ├── values.env           has PREFIX + REWRITE set"
  echo "        │   └── configmap.yaml       optional"
  echo "        ├── payment-service/         Spring Boot no mapping"
  echo "        │   ├── values.env           no PREFIX/REWRITE"
  echo "        │   └── configmap.yaml"
  echo "        └── frontend-ui/             GUI, no configmap needed"
  echo "            └── values.env           may have PREFIX/REWRITE"
  echo ""
  echo -e "  ${BOLD}VALUES.ENV KEYS${NC}"
  echo "    NAME         required   service name"
  echo "    IMAGE        required   registry image path"
  echo "    TAG          required   image tag"
  echo "    PORT         required   container port"
  echo "    NAMESPACE    required   kubernetes namespace"
  echo "    ENVIRONMENT  required   test / staging / prod"
  echo "    PREFIX            optional   public URL path (triggers mapping)"
  echo "    REWRITE           optional   path app receives (triggers mapping)"
  echo "    HPA_MIN           optional   minimum pods       (all 4 needed to enable HPA)"
  echo "    HPA_MAX           optional   maximum pods       (all 4 needed to enable HPA)"
  echo "    HPA_CPU_THRESHOLD optional   CPU % threshold    (all 4 needed to enable HPA)"
  echo "    HPA_MEM_THRESHOLD optional   memory % threshold (all 4 needed to enable HPA)"
  echo ""
  echo -e "  ${BOLD}RECOMMENDED BANKING VALUES${NC}"
  echo "    HPA_MIN=2          never go below 2 pods -- no single point of failure"
  echo "    HPA_MAX=5          tune based on your service"
  echo "    HPA_CPU_THRESHOLD=60   scale before CPU is exhausted"
  echo "    HPA_MEM_THRESHOLD=75   scale before heap pressure hits GC"
  echo ""
  exit 0
fi

# ── List ──────────────────────────────────────────────────────────
if [ "$SERVICE" == "list" ]; then
  echo ""
  echo -e "  ${BOLD}Available services:${NC}"
  ls -d services/*/ | xargs -I{} basename {} | sed 's/^/    /'
  echo ""
  exit 0
fi

# ── Validate service ──────────────────────────────────────────────
if [ -z "$SERVICE" ]; then
  error_banner "No service name given" "Run ./deploy.sh help to see usage"
  exit 1
fi

if [ ! -d "$SERVICE_DIR" ]; then
  error_banner "Service not found" "services/${SERVICE}/ does not exist"
  echo -e "  ${DIM}Available services:${NC}"
  ls -d services/*/ | xargs -I{} basename {} | sed 's/^/    /'
  echo ""
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  error_banner "values.env missing" "${ENV_FILE} is required"
  exit 1
fi

# ── Load values ───────────────────────────────────────────────────
set -a
source "$ENV_FILE"
set +a

# ── Validate required vars ────────────────────────────────────────
MISSING=""
[ -z "$NAME"        ] && MISSING="${MISSING}\n    NAME"
[ -z "$IMAGE"       ] && MISSING="${MISSING}\n    IMAGE"
[ -z "$TAG"         ] && MISSING="${MISSING}\n    TAG"
[ -z "$PORT"        ] && MISSING="${MISSING}\n    PORT"
[ -z "$NAMESPACE"   ] && MISSING="${MISSING}\n    NAMESPACE"
[ -z "$ENVIRONMENT" ] && MISSING="${MISSING}\n    ENVIRONMENT"

if [ -n "$MISSING" ]; then
  error_banner "Missing required vars in values.env"     "services/${SERVICE}/values.env"
  echo -e "  ${RED}Missing:${NC}${MISSING}"
  echo ""
  echo -e "  ${DIM}Required keys: NAME  IMAGE  TAG  PORT  NAMESPACE  ENVIRONMENT${NC}"
  echo ""
  exit 1
fi

# ── Mapping: driven by PREFIX + REWRITE in values.env ────────────
# If PREFIX and REWRITE are set → apply mapping from root template.
# If not set → skip mapping entirely.
if [ -n "$PREFIX" ] && [ -n "$REWRITE" ]; then
  HAS_MAPPING=true
else
  HAS_MAPPING=false
fi

# ── HPA: driven by HPA_MIN, HPA_MAX, HPA_CPU_THRESHOLD, HPA_MEM_THRESHOLD
# All four must be set → apply HPA from root template.
# If any are missing → skip HPA entirely.
if [ -n "$HPA_MIN" ] && [ -n "$HPA_MAX" ] && [ -n "$HPA_CPU_THRESHOLD" ] && [ -n "$HPA_MEM_THRESHOLD" ]; then
  HAS_HPA=true
else
  HAS_HPA=false
fi

# ── Pick template ─────────────────────────────────────────────────
if [ -f "$CONFIGMAP_FILE" ]; then
  TEMPLATE="templates/template-with-config.yaml"
  TEMPLATE_LABEL="with-config"
else
  TEMPLATE="templates/template-no-config.yaml"
  TEMPLATE_LABEL="no-config"
fi

# ── Rollback ──────────────────────────────────────────────────────
if [ "$ACTION" == "--rollback" ]; then
  banner "Rolling back ${BOLD}$NAME${NC}" \
    "Namespace : $NAMESPACE"
  echo -e "  Undoing last deployment..."
  kubectl rollout undo deployment/$NAME -n $NAMESPACE
  echo ""
  echo -e "  Waiting for rollback..."
  kubectl rollout status deployment/$NAME -n $NAMESPACE
  success_banner "$NAME rolled back successfully"
  exit 0
fi

# ── Restart ───────────────────────────────────────────────────────
if [ "$ACTION" == "--restart" ]; then
  banner "Restarting ${BOLD}$NAME${NC}" \
    "Namespace : $NAMESPACE"
  kubectl rollout restart deployment/$NAME -n $NAMESPACE
  echo ""
  echo -e "  Waiting for restart..."
  kubectl rollout status deployment/$NAME -n $NAMESPACE
  success_banner "$NAME restarted successfully"
  exit 0
fi

# ── Render template ───────────────────────────────────────────────
RENDERED=$(envsubst < "$TEMPLATE")

# ── Dry run ───────────────────────────────────────────────────────
if [ "$ACTION" == "--dry-run" ]; then
  banner "Dry run: $NAME" \
    "Namespace : $NAMESPACE" \
    "Image     : $IMAGE:$TAG" \
    "Template  : $TEMPLATE_LABEL"

  if [ -f "$CONFIGMAP_FILE" ]; then
    echo -e "  ${BOLD}── configmap.yaml ────────────────────────────────${NC}"
    cat "$CONFIGMAP_FILE"
    echo ""
  else
    echo -e "  ${YELLOW}⊘ configmap.yaml not present -- will be skipped${NC}"
    echo ""
  fi

  if [ "$HAS_MAPPING" == "true" ]; then
    echo -e "  ${BOLD}── mapping (from template) ───────────────────────${NC}"
    envsubst < "templates/mapping.yaml.template"
    echo ""
  else
    echo -e "  ${YELLOW}⊘ PREFIX/REWRITE not set -- mapping will be skipped${NC}"
    echo ""
  fi

  if [ "$HAS_HPA" == "true" ]; then
    echo -e "  ${BOLD}── hpa (from template) ───────────────────────────${NC}"
    envsubst < "templates/hpa.yaml.template"
    echo ""
  else
    echo -e "  ${YELLOW}⊘ HPA_MIN/MAX/THRESHOLD not set -- HPA will be skipped${NC}"
    echo ""
  fi

  echo -e "  ${BOLD}── rendered deployment ───────────────────────────${NC}"
  echo "$RENDERED"
  echo -e "  ${DIM}Dry run complete -- nothing was applied${NC}"
  echo ""
  exit 0
fi

# ── Deploy ────────────────────────────────────────────────────────
# Count total steps
TOTAL=1
[ -f "$CONFIGMAP_FILE" ]         && TOTAL=$((TOTAL + 1))
[ "$HAS_MAPPING" == "true" ]     && TOTAL=$((TOTAL + 1))
[ "$HAS_HPA" == "true" ]         && TOTAL=$((TOTAL + 1))
STEP_NUM=1
START_TIME=$(date +%s)

# trim image path so it fits in banner
IMAGE_SHORT="${IMAGE##*/}:${TAG}"
banner "Deploying $NAME" \
  "Namespace : $NAMESPACE" \
  "Image     : $IMAGE_SHORT" \
  "Template  : $TEMPLATE_LABEL"

# Step: configmap
if [ -f "$CONFIGMAP_FILE" ]; then
  step $STEP_NUM $TOTAL "Applying configmap..."
  kubectl apply -f "$CONFIGMAP_FILE" > /dev/null 2>&1 && step_done || { step_fail; error_banner "Configmap apply failed" "Run --dry-run to inspect the file"; exit 1; }
  STEP_NUM=$((STEP_NUM + 1))
else
  echo -e "  ${DIM}[skip]${NC}  ${YELLOW}configmap.yaml not found -- skipping${NC}"
fi

# Step: mapping (only if PREFIX + REWRITE set in values.env)
if [ "$HAS_MAPPING" == "true" ]; then
  step $STEP_NUM $TOTAL "Applying mapping..."
  envsubst < "templates/mapping.yaml.template" | kubectl apply -f - > /dev/null 2>&1 && step_done || { step_fail; error_banner "Mapping apply failed" "Check PREFIX/REWRITE in values.env"; exit 1; }
  STEP_NUM=$((STEP_NUM + 1))
else
  echo -e "  ${DIM}[skip]${NC}  ${YELLOW}PREFIX/REWRITE not set -- mapping skipped${NC}"
fi

# Step: deployment + service
step $STEP_NUM $TOTAL "Applying deployment + service..."
echo "$RENDERED" | kubectl apply -f - > /dev/null 2>&1 && step_done || { step_fail; error_banner "Deployment apply failed" "Run --dry-run to inspect rendered YAML"; exit 1; }
STEP_NUM=$((STEP_NUM + 1))

# Step: HPA (only if HPA_MIN, HPA_MAX, HPA_CPU_THRESHOLD set)
if [ "$HAS_HPA" == "true" ]; then
  step $STEP_NUM $TOTAL "Applying HPA..."
  envsubst < "templates/hpa.yaml.template" | kubectl apply -f - > /dev/null 2>&1 && step_done || { step_fail; error_banner "HPA apply failed" "Check HPA_MIN HPA_MAX HPA_CPU_THRESHOLD in values.env"; exit 1; }
else
  echo -e "  ${DIM}[skip]${NC}  ${YELLOW}HPA_MIN/MAX/THRESHOLD not set -- HPA skipped${NC}"
fi

echo ""
echo -e "  ${DIM}Waiting for rollout...${NC}"

# ── Rollout watch with 30s debug trigger ─────────────────────────
ROLLOUT_START=$(date +%s)
DEBUG_TRIGGERED=false

# run rollout status in background
kubectl rollout status deployment/$NAME -n $NAMESPACE &
ROLLOUT_PID=$!

while kill -0 $ROLLOUT_PID 2>/dev/null; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - ROLLOUT_START))

  # if rollout takes more than 30s, run describe to check for issues
  if [ $ELAPSED -ge 30 ] && [ "$DEBUG_TRIGGERED" == "false" ]; then
    DEBUG_TRIGGERED=true
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠  Rollout taking longer than 30s -- checking pod status...${NC}"
    echo ""

    # get the pod name
    POD=$(kubectl get pods -n $NAMESPACE -l app=$NAME \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$POD" ]; then
      echo -e "  ${BOLD}── kubectl describe pod: $POD ──────────────────${NC}"
      kubectl describe pod $POD -n $NAMESPACE | grep -A 20 "Events:" || true
      echo ""
      echo -e "  ${BOLD}── last 20 log lines ────────────────────────────${NC}"
      kubectl logs $POD -n $NAMESPACE --tail=20 -c $NAME 2>/dev/null || \
        echo -e "  ${DIM}No logs yet -- container may still be starting${NC}"
      echo ""
      echo -e "  ${DIM}Continuing to wait for rollout...${NC}"
    else
      echo -e "  ${YELLOW}No pod found yet for $NAME${NC}"
    fi
  fi

  sleep 2
done

# wait for rollout to finish and capture exit code
wait $ROLLOUT_PID
ROLLOUT_EXIT=$?

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [ $ROLLOUT_EXIT -eq 0 ]; then
  success_banner "$NAME is live" "Time: ${ELAPSED}s  |  Namespace: $NAMESPACE"
else
  error_banner "Rollout failed" "Run: kubectl describe pod -n $NAMESPACE -l app=$NAME"
  exit 1
fi
