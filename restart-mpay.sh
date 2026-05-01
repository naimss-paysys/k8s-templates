#!/bin/bash
# ================================================================
# FILE: restart-mpay.sh
# Restarts MPAY frontend services: web, queue-handler, rest-handler
# Usage:
#   ./restart-mpay.sh                  restart (base/default namespace)
#   ./restart-mpay.sh --country tz     restart Tanzania pods
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source lib/ui.sh

COUNTRY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --country|-c)
      COUNTRY="${2:-}"
      shift 2
      ;;
    --help|-h)
      echo ""
      echo -e "  Usage:  ./restart-mpay.sh [--country <code>]"
      echo -e "  Example: ./restart-mpay.sh --country tz"
      echo ""
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

SERVICES=(web queue-handler rest-handler)
COUNTRY_LABEL="${COUNTRY:+ [${COUNTRY}]}"

echo ""
echo -e "  ${BOLD}${CYAN}◆  MPAY Service Restart${NC}${COUNTRY_LABEL}"
divider
echo -e "  ${DIM}Services:${NC}  web  ·  queue-handler  ·  rest-handler"
echo ""

declare -a PASSED=()
declare -a FAILED=()

for svc in "${SERVICES[@]}"; do
  section_header "Restarting  ${svc}${COUNTRY_LABEL}"

  set +e
  if [ -n "$COUNTRY" ]; then
    ./deploy.sh "$svc" --country "$COUNTRY" --restart
  else
    ./deploy.sh "$svc" --restart
  fi
  SVC_EXIT=$?
  set -e

  if [ $SVC_EXIT -eq 0 ]; then
    PASSED+=("$svc")
  else
    FAILED+=("$svc")
    echo -e "\n  ${RED}✖${NC}  ${svc} failed — continuing to next service"
  fi

  echo ""
done

# ── Summary ───────────────────────────────────────────────────────
divider
echo ""
echo -e "  ${BOLD}${WHITE}Restart Summary${NC}${COUNTRY_LABEL}"
echo ""

if [ ${#PASSED[@]} -gt 0 ]; then
  for svc in "${PASSED[@]}"; do
    echo -e "  ${GREEN}✔${NC}  ${svc}"
  done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  for svc in "${FAILED[@]}"; do
    echo -e "  ${RED}✖${NC}  ${svc}"
  done
  echo ""
  echo -e "  ${RED}${BOLD}${#FAILED[@]} service(s) failed to restart${NC}"
  echo ""
  exit 1
fi

echo ""
success_banner "All MPAY services restarted${COUNTRY_LABEL}"