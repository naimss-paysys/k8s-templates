# Resource Reference
# Based on kubectl top output from your cluster.
# Copy the right block into your service's values.env.

# ── HEAVY (dashboard-backoffice, dashboard-merchant-api) ──────────
# Actual: ~3-12m CPU / 1000-1300Mi RAM
CPU_REQUEST=200m
MEMORY_REQUEST=1536Mi
CPU_LIMIT=1000m
MEMORY_LIMIT=2560Mi

# ── MEDIUM (dashboard-job-processor) ──────────────────────────────
# Actual: ~4m CPU / 832Mi RAM
CPU_REQUEST=100m
MEMORY_REQUEST=1024Mi
CPU_LIMIT=500m
MEMORY_LIMIT=2048Mi

# ── LIGHT (queue-handler, rest-handler, web) ──────────────────────
# Actual: ~2m CPU / 290-315Mi RAM
CPU_REQUEST=100m
MEMORY_REQUEST=512Mi
CPU_LIMIT=500m
MEMORY_LIMIT=768Mi

# ── FRONTEND (backoffice-ui) ───────────────────────────────────────
# Actual: ~1m CPU / 40Mi RAM
CPU_REQUEST=50m
MEMORY_REQUEST=128Mi
CPU_LIMIT=200m
MEMORY_LIMIT=256Mi
