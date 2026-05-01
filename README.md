# KubeForge

> **Multi-country Kubernetes deployment engine for microservice platforms**

A production-grade bash-based deployment CLI built for teams managing the same microservice stack across multiple regional deployments (countries, regions, environments). KubeForge replaces ad-hoc `kubectl apply` commands with a structured, auditable, CI/CD-friendly workflow that handles ConfigMap versioning, rolling updates, automatic rollback, and multi-country config overlays — all from a single command.

```
██╗  ██╗██╗   ██╗██████╗ ███████╗███████╗ ██████╗ ██████╗   ██████╗ ███████╗
██║ ██╔╝██║   ██║██╔══██╗██╔════╝██╔════╝██╔═══██╗██╔══██╗ ██╔════╝ ██╔════╝
█████╔╝ ██║   ██║██████╔╝█████╗  █████╗  ██║   ██║██████╔╝ ██║  ███╗█████╗
██╔═██╗ ██║   ██║██╔══██╗██╔══╝  ██╔══╝  ██║   ██║██╔══██╗ ██║   ██║██╔══╝
██║  ██╗╚██████╔╝██║  ██║███████╗██║     ╚██████╔╝██║  ██║ ╚██████╔╝███████╗
╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝      ╚═════╝ ╚═╝  ╚═╝  ╚═════╝ ╚══════╝
```

---

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Multi-Country Deployment](#multi-country-deployment)
- [Command Reference](#command-reference)
- [Deployment Flow](#deployment-flow)
- [ConfigMap Versioning](#configmap-versioning)
- [CI/CD Integration](#cicd-integration)
- [Audit Log](#audit-log)
- [Troubleshooting](#troubleshooting)
- [Design Decisions](#design-decisions)

---

## Features

| Feature | Description |
|---------|-------------|
| **Multi-country overlays** | Base config + per-country override files. Only overridden keys differ. |
| **ConfigMap versioning** | Auto-generated, tagged names (`service-v2-1.0.22`). Keeps newest 3, deletes older. |
| **Zero-downtime rolling updates** | `maxSurge: 1 / maxUnavailable: 0` — new pod starts before old one stops. |
| **Automatic rollback** | Rollout timeout triggers instant `kubectl rollout undo` with diagnostics. |
| **Pre-flight validation** | `kubectl --dry-run=client` validates all YAML before anything is applied. |
| **Country scaffolding** | `--init` creates per-country config files from base templates in one command. |
| **Audit trail** | Every deploy/restart/rollback logged to `~/.kubeforge/history.log`. |
| **Dry-run preview** | Full rendered YAML shown without applying — useful for code review. |
| **Status dashboard** | Live pods, deployment wide, service, HPA in one command. |
| **Batch service restart** | Restart multiple services together with per-service result tracking. |
| **CI-aware** | `CI=true` disables all interactive prompts for pipeline use. |
| **GitLab CI integration** | Country-gated jobs — only the matching country job runs per pipeline. |
| **HPA support** | Dual CPU + memory autoscaling with banking-grade conservative scale-down. |
| **Ambassador mapping** | Auto-generated `Mapping` resource for API gateway routing. |
| **ELK logging** | Filebeat sidecar injected into every deployment automatically. |
| **TLS trust injection** | Init container imports TLS certificate into JVM truststore at startup. |

---

## Architecture

### Repository Layout

```
k8s/
├── deploy.sh                     # Entry point — thin orchestrator
├── generate-configmap.sh         # Standalone ConfigMap generator
├── restart-mpay.sh               # Batch restart for a service group
├── gitlab-ci-deploy.yml          # GitLab CI deploy stage (drop-in)
│
├── lib/
│   ├── ui.sh                     # Terminal styling, banners, step indicators
│   ├── create.sh                 # deploy, dry-run, status, init, rollout watch
│   ├── restart.sh                # restart, rollback actions
│   ├── validate.sh               # Pre-flight YAML validation
│   └── audit.sh                  # Audit log and history display
│
├── templates/
│   ├── template-with-config.yaml # Spring Boot deployment (with ConfigMap)
│   ├── template-no-config.yaml   # Frontend/GUI deployment (no ConfigMap)
│   ├── hpa.yaml.template         # HorizontalPodAutoscaler
│   └── mapping.yaml.template     # Ambassador API gateway Mapping
│
└── services/
    └── <service-name>/
        ├── values.env            # Base config (all countries)
        ├── values.tz.env         # Tanzania overrides (NAMESPACE, TAG)
        ├── values.tg.env         # Togo overrides
        ├── application.yaml      # Base Spring Boot config
        ├── application.tz.yaml   # Tanzania-specific app config
        ├── application.tg.yaml   # Togo-specific app config
        ├── configmap.yaml        # Generated — do not edit manually
        └── configmap.tz.yaml     # Generated — Tanzania ConfigMap
```

### Module Dependency Graph

```
deploy.sh
  ├── lib/ui.sh          (sourced — colors, banners, step indicators)
  ├── lib/validate.sh    (sourced — pre-flight kubectl dry-run)
  ├── lib/restart.sh     (sourced — do_restart, do_rollback)
  ├── lib/create.sh      (sourced — do_deploy, do_dry_run, do_status, do_init)
  └── lib/audit.sh       (sourced — log_audit, do_history)
        │
        └── generate-configmap.sh   (called as subprocess during deploy)
```

All library modules are **sourced** (not subshells), so all variables are shared across functions without disk round-trips.

### Config Merge Strategy

```
values.env  (base — IMAGE, PORT, PREFIX, HPA, resources, AMBASSADOR_HOST)
    +
values.tz.env  (country override — NAMESPACE, TAG)
    ↓
 merged environment  (later source wins on conflict)
    ↓
 envsubst → rendered YAML → kubectl apply
```

---

## Prerequisites

### Tools (on the deploy host)

| Tool | Purpose | Required |
|------|---------|----------|
| `kubectl` | Apply resources, watch rollouts | Yes |
| `bash` 4.x+ | Script runtime | Yes |
| `envsubst` (gettext) | Template variable substitution | Yes |
| `sed`, `awk`, `grep` | Config file manipulation | Yes |
| `colordiff` | Colored ConfigMap diff | No (falls back to `diff`) |
| `yamllint` | YAML syntax fallback if kubectl unavailable | No |

Install on RHEL/CentOS:
```bash
sudo dnf install -y gettext colordiff
```

Install on Ubuntu/Debian:
```bash
sudo apt install -y gettext-base colordiff
```

### Kubernetes Cluster Prerequisites

The following resources must exist in your target namespace **before** the first deploy. KubeForge does not create these — they are managed separately.

#### Secrets

```bash
# Application credentials (injected into every Spring Boot container via envFrom)
kubectl create secret generic <app-secrets-name> \
  --from-env-file=application-secrets.env \
  -n <your-namespace>

# Container registry pull credentials
kubectl create secret docker-registry <registry-secret-name> \
  --docker-server=<your-registry> \
  --docker-username=<user> \
  --docker-password=<password> \
  -n <your-namespace>

# TLS certificate (mounted into init container + app containers)
kubectl create secret generic <tls-secret-name> \
  --from-file=fullchain.crt=<path-to-cert> \
  -n <your-namespace>

# ELK/Elasticsearch credentials (used by Filebeat sidecar)
kubectl create secret generic <elk-secret-name> \
  --from-literal=ELK_USERNAME=<user> \
  --from-literal=ELK_PASSWORD=<pass> \
  -n <your-namespace>
```

#### Shared ConfigMaps

```bash
# Logback XML config (mounted into every Spring Boot service)
kubectl create configmap shared-logback \
  --from-file=logback.xml=<path-to-logback.xml> \
  -n <your-namespace>

# Filebeat config (mounted into every Filebeat sidecar)
kubectl create configmap shared-filebeat-config \
  --from-file=filebeat.yml=<path-to-filebeat.yml> \
  -n <your-namespace>
```

#### PersistentVolumeClaim

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: file-storage
  namespace: <your-namespace>
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
EOF
```

#### Other Requirements
- Ambassador / Emissary-Ingress CRDs installed (for `Mapping` resources)
- Target namespace must exist: `kubectl create namespace <your-namespace>`
- `kubectl` context must be pointing at the correct cluster before running

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/naimss-paysys/k8s-templates.git ~/k8s
cd ~/k8s
chmod +x deploy.sh generate-configmap.sh restart-mpay.sh
```

### 2. Make `kubeforge` available system-wide

```bash
# Create a symlink in your PATH
mkdir -p ~/.local/bin
ln -s ~/k8s/deploy.sh ~/.local/bin/kubeforge

# Verify it's in PATH (add to ~/.bashrc if not)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Test
kubeforge help
```

---

## Quick Start

### Deploy a service

```bash
# Deploy to default (base) country
kubeforge my-service

# Deploy to a specific country
kubeforge my-service --country tz

# Preview what will be applied without deploying
kubeforge my-service --country tz --dry-run
```

### Add a new country for an existing service

```bash
# 1. Scaffold the country files
kubeforge my-service --country tg --init

# 2. Edit the generated files
#    → services/my-service/values.tg.env     (set NAMESPACE and TAG)
#    → services/my-service/application.tg.yaml  (update app config)

# 3. Preview
kubeforge my-service --country tg --dry-run

# 4. Deploy
kubeforge my-service --country tg
```

---

## Configuration Reference

### `values.env` — Complete Key Reference

Every service has a `values.env` in its directory. Country override files (`values.tz.env`, `values.tg.env`) contain only the keys that differ.

#### Required (base `values.env`)

| Key | Example | Description |
|-----|---------|-------------|
| `SERVICE_NAME` | `payment-api` | Kubernetes Deployment and Service name |
| `IMAGE` | `payment-api` | Container image name (registry prefix in template) |
| `TAG` | `1.0.0` | Image tag |
| `PORT` | `8080` | Container port |
| `ENVIRONMENT` | `test` | Injected as `APP_ENVIRONMENT` env var |
| `CONFIGMAP_NAME` | `payment-api-config` | Base name for versioned ConfigMaps |
| `CONFIG_VERSION` | `v1` | Manually bumped when ConfigMap structure changes |

#### Required (country override file, e.g. `values.tz.env`)

| Key | Example | Description |
|-----|---------|-------------|
| `NAMESPACE` | `production-tz` | Kubernetes namespace for this country |
| `TAG` | `1.0.22-TZ` | Country-specific image tag |

#### Optional — Routing (enables Ambassador Mapping)

Both must be set to activate:

| Key | Example | Description |
|-----|---------|-------------|
| `PREFIX` | `/payment-api/` | Public URL path (what the client sends) |
| `REWRITE` | `/` | Path the app receives (almost always `/`) |
| `AMBASSADOR_HOST` | `api.example.com` | Ambassador `host:` selector for this environment |
| `HOST_ALIAS_IP` | `10.0.0.1` | IP added to pod `/etc/hosts` for internal TLS resolution |

#### Optional — HPA (all four required to enable autoscaling)

| Key | Example | Description |
|-----|---------|-------------|
| `HPA_MIN` | `2` | Minimum pods (recommend 2 for production) |
| `HPA_MAX` | `6` | Maximum pods |
| `HPA_CPU_THRESHOLD` | `60` | CPU % that triggers scale-up |
| `HPA_MEM_THRESHOLD` | `75` | Memory % that triggers scale-up |

#### Optional — Resources

| Key | Example | Description |
|-----|---------|-------------|
| `CPU_REQUEST` | `200m` | CPU reservation |
| `CPU_LIMIT` | `800m` | CPU hard limit |
| `MEMORY_REQUEST` | `512Mi` | Memory reservation |
| `MEMORY_LIMIT` | `1536Mi` | Memory hard limit |

#### Optional — Behaviour

| Key | Default | Description |
|-----|---------|-------------|
| `REPLICAS` | `1` | Number of pod replicas (recommend `2` for production) |
| `ROLLOUT_TIMEOUT` | `120` | Seconds before rollout is considered stuck |

### Per-Service File Layout

```
services/<service-name>/
│
├── values.env            ← base: SERVICE_NAME, IMAGE, PORT, CONFIGMAP_NAME,
│                           ENVIRONMENT, resources, HPA, PREFIX, REWRITE
│
├── values.tz.env         ← Tanzania: NAMESPACE, TAG  (+ any overrides)
├── values.tg.env         ← Togo: NAMESPACE, TAG
│
├── application.yaml      ← base Spring Boot application config
├── application.tz.yaml   ← Tanzania-specific app config (DB URLs, etc.)
├── application.tg.yaml   ← Togo-specific app config
│
├── configmap.yaml        ← auto-generated — do not edit
├── configmap.tz.yaml     ← auto-generated for Tanzania
└── configmap.tg.yaml     ← auto-generated for Togo
```

---

## Multi-Country Deployment

KubeForge uses a **layered config merge** pattern. The base `values.env` defines everything that is common across countries. Each `values.<country>.env` file only contains what differs.

### How the merge works

```bash
# deploy.sh loads in order — later source wins on conflict:
source services/<service>/values.env        # base
source services/<service>/values.tz.env     # country override (wins)
```

**Example:** `dashboard-api` deployed to Tanzania

```
values.env                      values.tz.env
──────────────────────          ──────────────────────
SERVICE_NAME=dashboard-api      NAMESPACE=prod-tz
IMAGE=dashboard-api             TAG=1.0.22-TZ
PORT=8080              ──┐
ENVIRONMENT=production   │
CONFIGMAP_NAME=...       │      ← Tanzania overrides NAMESPACE and TAG
CPU_REQUEST=200m         │      ← everything else inherits from base
HPA_MIN=2                │
AMBASSADOR_HOST=...      │
NAMESPACE=dev         ←──┘  (overridden by values.tz.env)
TAG=1.0.0             ←──┘  (overridden by values.tz.env)
```

### Adding a new country

```bash
# Step 1 — scaffold (creates values.tg.env + application.tg.yaml)
kubeforge dashboard-api --country tg --init

# Step 2 — fill in values.tg.env
NAMESPACE=prod-tg
TAG=1.0.22-TG

# Step 3 — update application.tg.yaml with Togo-specific config
#           (DB connection, URLs, etc.)

# Step 4 — preview
kubeforge dashboard-api --country tg --dry-run

# Step 5 — deploy
kubeforge dashboard-api --country tg
```

### Country file rules

- `values.tz.env` is a **minimal override** — only keys different from base
- `application.tz.yaml` is the **full application config** for that country (Spring Boot `application.yaml` format)
- ConfigMaps are generated per-country: `configmap.tz.yaml`, `configmap.tg.yaml`
- `CONFIGMAP_FULL_NAME` is written back to the owning country env file after generation

---

## Command Reference

### Syntax

```
kubeforge <service> [--country <code>] [--action]
kubeforge <global-command>
```

### Actions

| Command | Description |
|---------|-------------|
| `kubeforge <service>` | Deploy with base config |
| `kubeforge <service> --country tz` | Deploy for Tanzania |
| `kubeforge <service> --country tz --dry-run` | Preview all YAML — nothing applied |
| `kubeforge <service> --country tz --restart` | Rolling restart (no image change) |
| `kubeforge <service> --country tz --rollback` | Undo last deployment |
| `kubeforge <service> --country tz --status` | Show live pods, deployment, service, HPA |
| `kubeforge <service> --country tg --init` | Scaffold `values.tg.env` + `application.tg.yaml` |

### Global commands

| Command | Description |
|---------|-------------|
| `kubeforge list` | List all services with country files, namespaces, active features |
| `kubeforge history` | Show last 50 deploy records |
| `kubeforge history 20` | Show last 20 deploy records |
| `kubeforge help` | Full usage and variable reference |

### Batch restart

```bash
# Restart a fixed group of services (web, queue-handler, rest-handler)
./restart-mpay.sh

# With country flag
./restart-mpay.sh --country tz
```

---

## Deployment Flow

When you run `kubeforge <service> --country tz`, this is the exact execution order:

```
1.  Load base values.env
2.  Overlay values.tz.env  (wins on conflict)
3.  Validate required variables (SERVICE_NAME, IMAGE, TAG, PORT, NAMESPACE, ENVIRONMENT)
4.  Select template:
      application.<country>.yaml exists → template-with-config.yaml
      application.yaml exists          → template-with-config.yaml
      neither                          → template-no-config.yaml

5.  Pre-flight:
      ├── Namespace exists?            (kubectl get namespace)
      ├── TAG == "latest"?             (warn — rollback won't work)
      └── kubectl dry-run on all YAML  (configmap, mapping, HPA, deployment)

6.  Step 1 — Generate ConfigMap:
      ├── Load values + country overlay → compute CONFIGMAP_FULL_NAME
      ├── Render application.<country>.yaml into ConfigMap YAML
      ├── Compare against existing configmap.<country>.yaml
      │     identical content + same name  → skip (no-op)
      │     identical content + new name   → update name only
      │     content changed               → show diff, apply (CI: auto-apply)
      └── Write CONFIGMAP_FULL_NAME → values.<country>.env

7.  Step 1 — Apply ConfigMap  (kubectl apply -f configmap.<country>.yaml)

8.  Step 2 — Apply Mapping    (if PREFIX + REWRITE set)

9.  Step 3 — Apply Deployment + Service

10. Step 4 — Apply HPA        (if HPA_MIN/MAX/THRESHOLD all set)

11. Watch rollout:
      ├── Background: kubectl rollout status
      ├── Every 2s: check if still running
      ├── At 25% timeout: warn if taking long
      └── At 100% timeout: kill watch, auto-rollback, show diagnostics

12. On success:
      ├── success_banner with total duration
      ├── Show live pod table
      ├── Clean up old ConfigMaps (keep newest 3, delete older)
      └── Write audit log entry

13. On failure:
      ├── error_banner
      ├── Show failing pod events + last 15 log lines
      ├── kubectl rollout undo
      └── Write audit log entry (FAILED)
```

---

## ConfigMap Versioning

ConfigMaps are versioned using the pattern:

```
{CONFIGMAP_NAME}-{CONFIG_VERSION}-{TAG}

# Example:
payment-api-config-v2-1.0.22-tz
```

- `CONFIG_VERSION` is manually bumped in `values.env` when the ConfigMap **structure** changes (new keys, sections removed). Value-only changes don't need a version bump.
- `TAG` automatically updates the name on every deploy, creating a new ConfigMap in the cluster.
- After a successful deploy, KubeForge keeps the **3 newest** ConfigMaps and deletes older ones. This preserves rollback capability across 3 versions.
- In CI (`CI=true`), cleanup runs automatically without prompting.

### ConfigMap diff behaviour

When `application.<country>.yaml` has changed:

- **Interactive mode** (local): shows a side-by-side diff, prompts `y/n`
- **CI mode** (`CI=true`): auto-applies without prompting
- **Colordiff**: used if available, falls back to plain `diff -y`

---

## CI/CD Integration

### GitLab CI (included: `gitlab-ci-deploy.yml`)

Drop the contents of `gitlab-ci-deploy.yml` into your `.gitlab-ci.yml`. The pipeline uses a single variable `COUNTRY` to determine which job runs — only one country deploys per pipeline execution.

```
COUNTRY=tz  →  deploy-tz job runs,  deploy-tg skipped
COUNTRY=tg  →  deploy-tg job runs,  deploy-tz skipped
```

#### Required CI/CD Variables

Set these in **Settings → CI/CD → Variables**:

| Variable | Type | Description |
|----------|------|-------------|
| `SSH_PRIVATE_KEY` | File | Private key to reach the deploy host |
| `DEPLOY_USER` | Variable | SSH user on deploy host |
| `DEPLOY_HOST` | Variable | Deploy host IP or hostname |
| `K8S_DIR` | Variable | Absolute path to this repo on the host |
| `CI_RUNNER_TAG` | Variable | Runner tag for deploy jobs |
| `SERVICES` | Variable | Space-separated service names to deploy |
| `COUNTRY` | Variable | `tz` or `tg` — controls which job runs |

#### What the pipeline does per service

```
1. SSH connectivity check (ConnectTimeout=10s)
2. Validate services/<service>/values.<country>.env exists
3. sed replace TAG in values.<country>.env → CI_COMMIT_TAG
4. CI=true ./deploy.sh <service> --country <country>
      ↳ Full KubeForge deploy (validate → configmap → apply → rollout)
      ↳ CI=true disables all interactive prompts
5. Accumulate failures — all services attempted before reporting
```

#### `CI=true` behaviour

`CI=true` is passed explicitly in the SSH command (not inherited from the runner environment — SSH sessions don't inherit runner env vars):

- `generate-configmap.sh` → skips "Apply these changes?" prompt
- `cleanup_old_configmaps` → auto-deletes without "Delete N configmaps?" prompt

---

## Audit Log

Every deploy, restart, and rollback is automatically recorded at:

```
~/.kubeforge/history.log
```

#### View history

```bash
kubeforge history       # last 50 entries
kubeforge history 20    # last 20 entries
```

#### Log format

```
WHEN               SERVICE                  COUNTRY   TAG                     ACTION     STATUS    DURATION
2025-01-15 14:32   payment-api              [tz]      1.0.22-TZ               deploy     SUCCESS   41s
2025-01-15 09:10   dashboard-backoffice     [tz]      1.0.18-TZ               deploy     FAILED    8s
2025-01-14 17:55   queue-handler            [tz]      1.0.3                   restart    SUCCESS   12s
```

Green rows = SUCCESS, red rows = FAILED.

---

## Troubleshooting

### Deploy stuck / rollout timeout

KubeForge auto-rolls back after `ROLLOUT_TIMEOUT` seconds (default 120s) and shows:
- Recent Kubernetes events for the failing pod
- Last 15 lines of container logs

```bash
# Manually check pod status
kubeforge payment-api --country tz --status

# Check events directly
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# Get logs
kubectl logs -l app=payment-api -n <namespace> --tail=50
```

### ConfigMap name mismatch

If the deployed configmap name doesn't match the image tag, check:

```bash
grep "^TAG=\|^CONFIGMAP_FULL_NAME=" services/payment-api/values.tz.env
```

The `CONFIGMAP_FULL_NAME` in `values.tz.env` should reflect the latest deployed tag. Running `kubeforge payment-api --country tz` regenerates it correctly.

### `values.tz.env not found` error

Run init first:

```bash
kubeforge payment-api --country tz --init
# Then fill in NAMESPACE and TAG in the generated file
```

### Dry-run passes but deploy fails

```bash
# Preview exactly what will be applied
kubeforge payment-api --country tz --dry-run

# Validate against live cluster schema
kubectl apply --dry-run=client -f services/payment-api/configmap.tz.yaml
```

### Missing cluster prerequisite

If pods show `CreateContainerConfigError`, a required Secret or ConfigMap is missing. Check:

```bash
kubectl get secret,configmap -n <namespace> | grep -E "shared-|app-secrets|elk-|tls-|registry-"
```

---

## Design Decisions

### Why bash, not Helm or Kustomize?

KubeForge was built for a specific operational pattern: multiple countries sharing identical infrastructure templates with minimal per-country config differences. Helm adds templating complexity and chart versioning overhead. Kustomize requires learning its patch model. Bash with `envsubst` is transparent — the template is exactly what gets applied, variables are explicit, and any engineer can read and debug the output without tooling knowledge.

### Why `source` instead of subshells for library files?

All `lib/*.sh` files are sourced into the main process, not called as subshells. This means all variables (`SERVICE_NAME`, `NAMESPACE`, `CONFIGMAP_FULL_NAME`, etc.) are shared across every function without any disk round-trips or export gymnastics. The tradeoff is that all function names must be unique across all lib files — a reasonable constraint for a deployment tool.

### Why per-country `values.tz.env` instead of a single file with sections?

A single file with sections (like `[tanzania]`) would require a custom parser and makes `source` unusable. Two files with `source values.env && source values.tz.env` gives merge-for-free: later source wins on conflict. Adding a new country is adding one file, not editing a shared file that could accidentally break another country.

### Why ConfigMap names include the image tag?

The ConfigMap name `service-v2-1.0.22-tz` encodes the tag so:
1. Rolling back via `kubectl rollout undo` automatically picks up the old ConfigMap (Kubernetes stores previous Deployment revisions that reference the old ConfigMap name)
2. You can see exactly which config version is active by looking at the pod spec
3. Two countries can be at different tags with completely independent ConfigMaps in the same cluster

### Why `maxUnavailable: 0` in rolling update strategy?

For a payment platform, traffic must never be dropped during deploy. `maxUnavailable: 0` guarantees the old pod keeps running until the new pod is confirmed `Running` by Kubernetes. Combined with a readiness probe (recommended addition), this ensures zero dropped requests during rollout.

---

## License

This project was independently designed and built as a personal infrastructure tool. All company-specific configuration has been excluded from this repository.

---

*Built with bash, kubectl, and a strong dislike for manual deployments.*