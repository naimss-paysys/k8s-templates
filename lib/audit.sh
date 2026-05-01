#!/bin/bash
# ================================================================
# FILE: lib/audit.sh
# Audit log — appends a record to ~/.kubeforge/history.log
# for every deploy, restart, and rollback.
# Requires lib/ui.sh to be sourced.
# ================================================================

KUBEFORGE_LOG_DIR="${HOME}/.kubeforge"
KUBEFORGE_LOG_FILE="${KUBEFORGE_LOG_DIR}/history.log"

log_audit() {
  local action="$1"    # deploy | restart | rollback
  local status="$2"    # SUCCESS | FAILED
  local duration="${3:-0}"

  mkdir -p "$KUBEFORGE_LOG_DIR"

  local ts country_col
  ts=$(date '+%Y-%m-%d %H:%M')
  country_col="${COUNTRY:+[${COUNTRY}]}"
  [ -z "$country_col" ] && country_col="base"

  printf "%-17s  %-38s  %-8s  %-22s  %-10s  %-8s  %ss\n" \
    "$ts" \
    "${SERVICE_NAME:-—}" \
    "$country_col" \
    "${TAG:-—}" \
    "$action" \
    "$status" \
    "$duration" \
    >> "$KUBEFORGE_LOG_FILE"
}

do_history() {
  local limit="${1:-50}"

  echo ""
  echo -e "  ${BOLD}${CYAN}◆  Deploy History${NC}  ${DIM}(last ${limit} entries)${NC}"
  divider
  echo ""

  if [ ! -f "$KUBEFORGE_LOG_FILE" ]; then
    echo -e "  ${DIM}No history yet — deploy something first${NC}"
    echo ""
    return 0
  fi

  printf "  ${BOLD}  %-17s  %-38s  %-8s  %-22s  %-10s  %-8s  %s${NC}\n" \
    "WHEN" "SERVICE" "COUNTRY" "TAG" "ACTION" "STATUS" "DURATION"
  echo ""

  tail -n "$limit" "$KUBEFORGE_LOG_FILE" | while IFS= read -r line; do
    if echo "$line" | grep -q "SUCCESS"; then
      echo -e "  ${GREEN}▸${NC}  $line"
    else
      echo -e "  ${RED}▸${NC}  $line"
    fi
  done

  echo ""
  echo -e "  ${DIM}Log: ${KUBEFORGE_LOG_FILE}${NC}"
  echo ""
}