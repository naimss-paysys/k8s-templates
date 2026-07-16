#!/bin/bash
# ================================================================
# FILE: lib/restart.sh
# Restart and rollback actions. Requires lib/ui.sh to be sourced.
# ================================================================

do_restart() {
  banner "↺  Restarting  ·  $SERVICE_NAME" \
    "Namespace  :  $NAMESPACE"

  step 1 1 "Restarting deployment..."

  local RESTART_OUTPUT RESTART_EXIT
  set +e
  RESTART_OUTPUT=$(kubectl rollout restart "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" 2>&1)
  RESTART_EXIT=$?
  set -e

  if [ $RESTART_EXIT -eq 0 ]; then
    step_done
    kubectl_result "$RESTART_OUTPUT"
  else
    step_fail
    error_banner "Restart failed" "$RESTART_OUTPUT"
    exit 1
  fi

  echo ""
  divider
  watch_rollout
  _KFORGE_STATUS="SUCCESS"
  success_banner "$DEPLOY_NAME restarted successfully"
}

do_rollback() {
  banner "↩  Rolling Back  ·  $SERVICE_NAME" \
    "Namespace  :  $NAMESPACE"

  step 1 1 "Rolling back deployment..."

  local RB_OUTPUT RB_EXIT
  set +e
  RB_OUTPUT=$(kubectl rollout undo "deployment/${DEPLOY_NAME}" -n "$NAMESPACE" 2>&1)
  RB_EXIT=$?
  set -e

  if [ $RB_EXIT -eq 0 ]; then
    step_done
    kubectl_result "$RB_OUTPUT"
  else
    step_fail
    error_banner "Rollback failed" "$RB_OUTPUT"
    exit 1
  fi

  echo ""
  divider
  watch_rollout
  _KFORGE_STATUS="SUCCESS"
  success_banner "$DEPLOY_NAME rolled back successfully"
}