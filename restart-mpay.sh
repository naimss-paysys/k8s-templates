#!/bin/bash

set -e

BASE_DIR="/home/admin-dnf/k8s"
cd $BASE_DIR

echo "🚀 Restarting MPAY services..."

SERVICES=(
  web
  queue-handler
  rest-handler
)

for svc in "${SERVICES[@]}"; do
  echo "🔄 Restarting $svc..."
  ./deploy.sh $svc --restart
done

echo "✅ All services restarted successfully!"
