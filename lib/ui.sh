#!/bin/bash
# ================================================================
# FILE: lib/ui.sh
# All terminal colors, banners, step indicators, and kubectl
# result formatting. Source this file — do not execute directly.
# ================================================================

# ── Colors & styles ──────────────────────────────────────────────
BLUE_BG='\033[48;5;39m'
DONE_BG='\033[48;5;40m'
FAIL_BG='\033[48;5;196m'
WARN_BG='\033[48;5;214m'
BLACK='\033[38;5;16m'
GREY='\033[38;5;245m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;38;5;39m'
CYAN='\033[0;36m'
WHITE='\033[0;97m'
BOLD='\033[1m'
DIM='\033[2m'
ITALIC='\033[3m'
NC='\033[0m'
KG='\033[1;32m'

# ── Boot banner ───────────────────────────────────────────────────
boot_banner() {
  echo -e "\033[1;32m"
  cat << "EOF"
██╗  ██╗██╗   ██╗██████╗ ███████╗███████╗ ██████╗ ██████╗   ██████╗ ███████╗
██║ ██╔╝██║   ██║██╔══██╗██╔════╝██╔════╝██╔═══██╗██╔══██╗ ██╔════╝ ██╔════╝
█████╔╝ ██║   ██║██████╔╝█████╗  █████╗  ██║   ██║██████╔╝ ██║  ███╗█████╗
██╔═██╗ ██║   ██║██╔══██╗██╔══╝  ██╔══╝  ██║   ██║██╔══██╗ ██║   ██║██╔══╝
██║  ██╗╚██████╔╝██║  ██║███████╗██║     ╚██████╔╝██║  ██║ ╚██████╔╝███████╗
╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝      ╚═════╝ ╚═╝  ╚═╝  ╚═════╝ ╚══════╝
EOF
  echo -e "\033[0m"
  echo -e "\033[1;36m      ⚙  KUBEFORGE ENGINE INITIALIZED\033[0m"
  echo -e "\033[2m      → Kubernetes Template Deployment System\033[0m"
  echo ""
}

# ── Layout helpers ────────────────────────────────────────────────
divider() {
  echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
}

section_header() {
  local label="$1"
  echo ""
  echo -e "  ${BOLD}${CYAN}${label}${NC}"
  divider
}

# ── Info / status banners ─────────────────────────────────────────
banner() {
  local title="$1"
  local line2="${2:-}"
  local line3="${3:-}"
  local line4="${4:-}"
  echo -e "\n  ${BLUE_BG}${BLACK}${BOLD} INFO ${NC} ${BOLD}${WHITE}${title}${NC}"
  [ -n "$line2" ] && echo -e "         ${GREY}→ ${line2}${NC}"
  [ -n "$line3" ] && echo -e "         ${GREY}→ ${line3}${NC}"
  [ -n "$line4" ] && echo -e "         ${GREY}→ ${line4}${NC}"
  echo ""
}

success_banner() {
  local msg="$1"
  local duration="${2:-}"
  echo -e "\n  ${DONE_BG}${BLACK}${BOLD} DONE ${NC} ${BOLD}${WHITE} ${msg}${NC}"
  echo -e "         ${GREY}→ Status:    ${NC}${GREEN}Live${NC}"
  echo -e "         ${GREY}→ Namespace: ${NC}${WHITE}${NAMESPACE:-default}${NC}"
  [ -n "$duration" ] && echo -e "         ${GREY}→ Metrics:   ${NC}${WHITE}Duration: ${duration}${NC}"
  echo ""
}

error_banner() {
  local msg="$1"
  local sub="${2:-}"
  local ctx_ns="${NAMESPACE:-default}"
  local ctx_app="${SERVICE_NAME:-unknown}"
  echo -e "\n  ${FAIL_BG}${BLACK}${BOLD} FAIL ${NC} ${BOLD}${WHITE} ${msg}${NC}"
  echo -e "         ${GREY}→ Target:    ${NC}${WHITE}deployment/${ctx_app}${NC} ${DIM}(ns: ${ctx_ns})${NC}"
  [ -n "$sub" ] && echo -e "         ${GREY}→ Reason:    ${NC}${RED}${sub}${NC}"
  echo -e "         ${GREY}→ Debug:     ${NC}${DIM}kubectl describe pod -n ${ctx_ns} -l app=${ctx_app}${NC}"
  echo -e "         ${GREY}→ Logs:      ${NC}${DIM}kubectl logs -n ${ctx_ns} -l app=${ctx_app} --tail=50${NC}"
  echo ""
}

warn_banner() {
  local msg="$1"
  local sub="${2:-}"
  echo -e "\n  ${WARN_BG}${BLACK}${BOLD} WARN ${NC} ${BOLD}${WHITE} ${msg}${NC}"
  [ -n "$sub" ] && echo -e "         ${GREY}→ Notice:    ${NC}${YELLOW}${sub}${NC}"
  echo ""
}

# ── Step progress indicators ──────────────────────────────────────
step() {
  local num="$1"
  local total="$2"
  local msg="$3"
  printf "  ${DIM}[${num}/${total}]${NC}  %-40s" "$msg"
}

step_done()    { echo -e "${GREEN}✔  done${NC}"; }
step_skipped() { echo -e "${YELLOW}⊘  skipped${NC}"; }
step_fail()    { echo -e "${RED}✖  failed${NC}"; }

# ── kubectl apply result display ──────────────────────────────────
# Parses each line of kubectl apply output and colour-codes it:
#   created    → green   (new resource)
#   configured → cyan    (updated resource)
#   unchanged  → dim     (no change)
kubectl_result() {
  local output="$1"
  [ -z "$output" ] && return
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -q " created$"; then
      echo -e "         ${GREY}→${NC} ${GREEN}${line}${NC}"
    elif echo "$line" | grep -q " configured$"; then
      echo -e "         ${GREY}→${NC} ${CYAN}${line}${NC}"
    elif echo "$line" | grep -q " unchanged$"; then
      echo -e "         ${GREY}→${NC} ${DIM}${line}${NC}"
    else
      echo -e "         ${GREY}→${NC} ${line}"
    fi
  done <<< "$output"
}