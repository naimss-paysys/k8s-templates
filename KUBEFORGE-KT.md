# KubeForge — Knowledge Transfer

**Author:** Naimatullah Khan  
**Date:** July 8, 2026  
**Project:** MixxMMP Payment Platform

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Repository Layout](#repository-layout)
4. [Commands](#commands)
5. [service.yaml Reference](#serviceyaml-reference)
6. [Application Config (ConfigMap Source)](#application-config-configmap-source)
7. [ConfigMap Versioning](#configmap-versioning)
8. [Deploy Flow](#deploy-flow)
9. [Templates](#templates)
10. [GitLab CI Integration](#gitlab-ci-integration)
11. [Deployed Services](#deployed-services)
12. [Troubleshooting](#troubleshooting)

---

## Overview

**KubeForge** is an internal bash CLI that wraps `kubectl` to manage multi-country Kubernetes deployments for the MixxMMP payment platform. It lives at `/home/admin-dnf/k8s/` on the deploy server and is accessible system-wide via the `kubeforge` symlink pointing to `deploy.sh`.

It was built to solve a specific problem: MixxMMP services run in **multiple countries** (Tanzania = `tz`, Togo = `tg`) and each needs its own Spring Boot config injected as a Kubernetes ConfigMap, its own TLS secret, and its own Ambassador routing host. Doing this by hand with raw `kubectl apply` was error-prone and hard to repeat.

### What one command does

- Generates a versioned ConfigMap from `application.<country>.yaml`
- Runs `kubectl diff` and shows a color-coded preview before applying anything
- Applies the ConfigMap, Ambassador Mapping, Deployment, Service, and HPA in order
- Automatically restarts pods when only ConfigMap values changed (not the Deployment spec)
- Watches the rollout with a 30-second diagnostic checkpoint and a configurable timeout
- Rolls back to the last stable state on timeout or failure
- Writes an audit log entry to `~/.kubeforge/history.log`

> **Note:** KubeForge wraps kubectl — it does not bypass it. All applies go through `kubectl apply -f`. Run `kubeforge doctor` to verify prerequisites before a first deploy.

---

## Prerequisites

### Tools

| Tool | Purpose | Install |
|------|---------|---------|
| `kubectl` | All Kubernetes operations | Already installed on the deploy server |
| `yq` v4+ | Parse and update `service.yaml` | `sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq` |
| `envsubst` | Render YAML templates | `sudo dnf install gettext` |
| `docker` | Pre-flight image existence check | Optional — deploy continues with a warning if unavailable |
| `colordiff` | Side-by-side ConfigMap diffs | `sudo dnf install colordiff` — falls back to plain `diff` |
| kubeconfig | Cluster access | `~/.kube/config` or `KUBECONFIG` env var |

### Secrets required in the namespace

These Kubernetes secrets must exist in `test-mmp` before any service can be deployed. Check with `kubeforge <service> --country tz --doctor`.

| Secret | Purpose |
|--------|---------|
| `my-registry-secret` | Docker registry pull credentials |
| `dashboard-application-secrets` | Application env vars (DB credentials, API keys) |
| `elk-credentials` | Filebeat to Elasticsearch credentials |
| `mixxmmp-tls-secret` | TLS cert for the Tanzania Ambassador host |
| `tg-tls` | TLS cert for the Togo Ambassador host |

### Shared ConfigMaps required in the namespace

| ConfigMap | Purpose |
|-----------|---------|
| `shared-logback` | Logback XML mounted into all Spring Boot pods |
| `shared-filebeat-config` | Filebeat YAML mounted into all pods |
| `dynamic-lists-configmap` | Dynamic lists JSON for dashboard services |
| `report-queries-configmap` | Report queries YAML for dashboard services |

---

## Repository Layout

```
k8s/
├── deploy.sh                  # entry point — "kubeforge" symlink points here
├── generate-configmap.sh      # generates versioned ConfigMap from application.<country>.yaml
├── gitlab-ci-deploy.yml       # drop-in CI/CD deploy stage definition
│
├── lib/                       # sourced by deploy.sh — do not call directly
│   ├── ui.sh                  # terminal colors, banners, step/progress output
│   ├── config.sh              # loads service.yaml (or legacy values.env)
│   ├── validate.sh            # pre-flight: image exists check, YAML validation
│   ├── create.sh              # do_deploy(), watch_rollout(), show_diagnostics()
│   ├── restart.sh             # do_restart(), do_rollback()
│   ├── audit.sh               # log_audit(), do_history() → ~/.kubeforge/history.log
│   └── doctor.sh              # do_doctor() — cluster health checks
│
├── templates/
│   ├── template-with-config.yaml  # Spring Boot: ConfigMap + Filebeat + initContainer
│   ├── template-no-config.yaml    # Frontend (nginx): Filebeat only, no ConfigMap
│   ├── mapping.yaml.template      # Ambassador Mapping resource
│   └── hpa.yaml.template          # HorizontalPodAutoscaler
│
├── services/                  # one subdirectory per service
│   └── dashboard-backoffice/
│       ├── service.yaml           # image, port, resources, country config
│       ├── application.tz.yaml    # Spring Boot config for Tanzania
│       ├── application.tg.yaml    # Spring Boot config for Togo
│       └── generated/             # gitignored — auto-created on each deploy
│           ├── configmap.tz.yaml
│           └── configmap.tg.yaml
│
└── .kubeforge                 # stores DEFAULT_COUNTRY — managed by "kubeforge default"
```

> **Important:** The `generated/` subfolder inside each service is gitignored. ConfigMap YAML files are regenerated on every deploy and must never be committed. The `application.<country>.yaml` files are committed and are the source of truth for each country's Spring Boot config.

---

## Commands

All commands follow `kubeforge <service> [--country <code>] [action]`. If `--country` is omitted, KubeForge uses the default set with `kubeforge default <code>`.

### Service-level actions

| Command | What it does |
|---------|-------------|
| `kubeforge <svc>` | Full deploy using the default country |
| `kubeforge <svc> --country tg` | Full deploy targeting Togo |
| `kubeforge <svc> --country tz --dry-run` | Renders all YAML and prints it without applying. Safe at any time. |
| `kubeforge <svc> --country tz --restart` | Runs `kubectl rollout restart`. Includes rollout watch with timeout and diagnostics. |
| `kubeforge <svc> --country tz --rollback` | Runs `kubectl rollout undo` to revert to the previous ReplicaSet. |
| `kubeforge <svc> --country tz --status` | Shows current pods, deployment status, and HPA. |
| `kubeforge <svc> --country tg --init` | Scaffolds a new `service.yaml` and `application.tg.yaml` if they don't exist. |
| `kubeforge <svc> --country tz --doctor` | Health check: secrets, shared ConfigMaps, PVC, pod status, image pull errors. |

### Global commands

| Command | What it does |
|---------|-------------|
| `kubeforge list` | Lists all services with namespace, tag, countries, and features (cm / hpa / map) |
| `kubeforge history [N]` | Shows last N deploy records from `~/.kubeforge/history.log`. Default 50. |
| `kubeforge default tz` | Sets `tz` as the default country, saved to `k8s/.kubeforge` |
| `kubeforge default` | Shows the current default country |
| `kubeforge doctor` | Cluster check: kubeconfig valid, API server reachable, namespace accessible |
| `kubeforge help` | Full usage reference |

### Examples

```bash
# One-time setup: set Tanzania as default country
$ kubeforge default tz

# Deploy dashboard-backoffice for Tanzania (uses default country)
$ kubeforge dashboard-backoffice

# Deploy the same service for Togo
$ kubeforge dashboard-backoffice --country tg

# Preview what will change — nothing is applied
$ kubeforge dashboard-backoffice --country tz --dry-run

# Restart pods to pick up a secret change
$ kubeforge dashboard-backoffice --country tz --restart

# Something went wrong — roll back
$ kubeforge dashboard-backoffice --country tz --rollback

# Verify cluster prerequisites before first deploy
$ kubeforge doctor

# See all services at a glance
$ kubeforge list

# Review last 20 deploy events
$ kubeforge history 20
```

> **Concurrent deploy protection:** KubeForge acquires a file lock at `/tmp/kubeforge-<service>-<country>.lock`. A second deploy of the same service/country while one is in progress exits immediately with an error.

---

## service.yaml Reference

Every service has one `service.yaml` in its `services/<name>/` directory. This is the primary file you edit for configuration changes.

### Annotated example

```yaml
# services/dashboard-backoffice/service.yaml

name: dashboard-backoffice    # must match the services/ directory name
image: dashboard-backoffice   # image name in the registry (tag excluded)
port: 5501                    # container port
namespace: test-mmp
tag: 1.0.92-TZ                # base tag — CI overwrites this before deploy
replicas: 1
host_alias_ip: 10.245.0.169   # MetalLB VIP — maps Ambassador host inside pods
config_version: v12           # auto-incremented when ConfigMap YAML keys change
rollout_timeout: 60           # seconds before rollout is declared stuck

resources:
  cpu: 200m/800m              # request/limit — parsed as "req/limit" by a slash
  memory: 1536Mi/2560Mi

routing:                      # both fields needed to create an Ambassador Mapping
  prefix: /dashboard-backoffice/
  rewrite: /

# scaling:                    # all four needed to create an HPA
#   min: 1
#   max: 4
#   cpu_threshold: 70
#   mem_threshold: 75

secrets:                      # checked by --doctor
  - my-registry-secret
  - dashboard-application-secrets
  - elk-credentials
  - mixxmmp-tls-secret

countries:
  tz:
    ambassador_host: mixxmmp-test.tigo.co.tz
    country: tz
    tls_secret: mixxmmp-tls-secret
    tag: 1.0.92-TZ
    previous_tag: 1.0.91-TZ              # written by CI before deploy
    configmap_full_name: dashboard-backoffice-config-tz-v12-1.0.92-tz
    #                    ↑ auto-written by generate-configmap.sh — never edit manually
  tg:
    ambassador_host: togo.mixx.tg
    country: tg
    tls_secret: tg-tls
```

### Field reference

| Field | Required? | Description |
|-------|-----------|-------------|
| `name` | **required** | Service name. Must match the `services/` directory. Becomes the Deployment/Service/pod label prefix. |
| `image` | **required** | Image name in the registry. Full path: `MixxMMP-registry-test.tigo.co.tz/<image>:<tag>`. |
| `port` | **required** | Container port. Used in the Deployment `containerPort` and the Kubernetes Service. |
| `countries.<code>.namespace` | **required** | Kubernetes namespace. All services currently use `test-mmp`. |
| `countries.<code>.tag` | **required** | Image tag for this country. Updated by CI before deploy. Never use `latest`. |
| `countries.<code>.ambassador_host` | **required** | The Ambassador Host selector — must match an existing Host resource in the cluster. |
| `countries.<code>.tls_secret` | **required** | Kubernetes secret with the TLS cert. Mounted into the initContainer for Java trust store import. |
| `replicas` | optional | Pod replicas. Default: 1. Overridable per country. |
| `resources.cpu` | optional | CPU as `request/limit` — e.g. `200m/800m`. Overridable per country. |
| `resources.memory` | optional | Memory as `request/limit` — e.g. `512Mi/1536Mi`. Overridable per country. |
| `host_alias_ip` | optional | Adds a `hostAliases` entry to pod spec. Needed so pods can reach their own public URL internally via MetalLB VIP. Stripped from spec when unset. |
| `rollout_timeout` | optional | Seconds before rollout is declared stuck. Default: 120. At 30s, live pod status is printed. |
| `config_version` | optional | Tracks ConfigMap schema generation. Auto-incremented when YAML keys change. Default: `v1`. Do not edit manually. |
| `routing.prefix` + `routing.rewrite` | optional | Both must be set to create an Ambassador Mapping. `rewrite` is almost always `/`. |
| `scaling.*` | optional | All four fields (`min`, `max`, `cpu_threshold`, `mem_threshold`) must be set to create an HPA. |
| `countries.<code>.configmap_full_name` | **auto** | Written by `generate-configmap.sh`. Never edit manually. |

---

## Application Config (ConfigMap Source)

Spring Boot services read their runtime config from a Kubernetes ConfigMap mounted at `/app/config/application.yaml` inside the pod. The source file is `services/<service>/application.<country>.yaml`.

### The pipeline

Running `kubeforge dashboard-backoffice --country tz`:

1. Reads `services/dashboard-backoffice/application.tz.yaml`
2. Wraps it in a ConfigMap YAML named `dashboard-backoffice-config-tz-v12-1.0.92-tz`
3. Writes it to `services/dashboard-backoffice/generated/configmap.tz.yaml`
4. Applies it to the cluster — the Deployment mounts it at `/app/config/application.yaml`

### Country isolation rule

> **Never share a single application.yaml between countries.** Always create separate `application.tz.yaml` and `application.tg.yaml`. Each gets its own versioned ConfigMap name — they deploy and roll back independently without affecting each other.

### Example application.tz.yaml

```yaml
# services/dashboard-backoffice/application.tz.yaml
# Standard Spring Boot YAML — injected as-is into the ConfigMap.

server:
  port: 5501
  servlet:
    context-path: /dashboard-backoffice

spring:
  datasource:
    url: jdbc:postgresql://db-host:5432/backoffice_tz
  application:
    name: dashboard-backoffice

bo_config:
  base_url: https://mixxmmp-test.tigo.co.tz
  country_code: TZ
```

### Frontend services — no ConfigMap

Frontend services (`backoffice-ui`, `merchant-portal`) have no `application.<country>.yaml`. KubeForge detects this and automatically uses `template-no-config.yaml` — no ConfigMap step at all. Runtime config for frontends is baked into the Docker image at build time via `config.js`.

---

## ConfigMap Versioning

The ConfigMap name encodes service name, country, config version, and image tag:

```
dashboard-backoffice-config-tz-v12-1.0.92-tz
                              ──  ───  ─────────  ──
                              │    │   image tag  country suffix
                              │    └── config_version
                              └─────── "config" literal
```

### When does config_version bump?

KubeForge compares the YAML **keys** between old and new `application.<country>.yaml` — not the values.

| Change type | config_version | Effect on pods |
|-------------|---------------|----------------|
| Value change only (e.g. different DB URL) | No bump — stays at v12 | ConfigMap updated in place. KubeForge triggers `kubectl rollout restart` automatically. |
| New YAML key added | Bumps v12 → v13 | New ConfigMap name → Deployment spec changes → pods restart via normal rollout. |
| YAML key removed or renamed | Bumps | Same as above. |

> **Why versioned names?** Kubernetes won't restart pods just because a ConfigMap was updated in place — the Deployment spec must change to trigger a rollout. The versioned name in the Deployment's volume definition is how structural changes always force a rollout. For value-only changes, KubeForge detects the "unchanged" Deployment and runs `kubectl rollout restart` automatically.

### Old ConfigMap cleanup

After a successful deploy, KubeForge deletes any ConfigMaps in the namespace matching `<service>-config-<country>-*` that are not the current `configmap_full_name`. This prevents accumulation of stale ConfigMaps over time.

---

## Deploy Flow

Every step that runs when you execute `kubeforge <service> --country tz`:

| Step | What happens |
|------|-------------|
| **1. Arg parsing & config load** | `deploy.sh` parses the service name, country, and action. `lib/config.sh` loads `service.yaml` with `yq` and exports all template variables. |
| **2. Concurrent lock** | Acquires `/tmp/kubeforge-<service>-<country>.lock`. A second deploy of the same service/country exits immediately. |
| **3. Pre-flight validation** | Checks image exists in registry. Validates ConfigMap, Mapping, and Deployment YAML using `kubectl apply --dry-run=client`. Fails fast before touching the cluster. |
| **4. ConfigMap generation** | Calls `generate-configmap.sh`. Reads `application.<country>.yaml`, compares keys with the previous generated configmap, bumps `config_version` if keys changed, writes new ConfigMap to `generated/`. Shows side-by-side diff and prompts for confirmation. CI mode auto-confirms. |
| **5. Diff & confirm** | Runs `kubectl diff` across the combined YAML (ConfigMap + Mapping + Deployment + HPA). Shows color-coded diff. Prompts **Apply these changes? [yes/no]**. CI mode skips this. |
| **6. Apply: ConfigMap** | `kubectl apply -f generated/configmap.<country>.yaml`. Tracks whether result was `configured` or `unchanged`. |
| **7. Apply: Mapping (conditional)** | Renders `mapping.yaml.template` with `envsubst` and applies it. Skipped if `routing.prefix`/`routing.rewrite` are absent. |
| **8. Apply: Deployment + Service** | Renders template and applies. **Key behavior:** if ConfigMap was updated but Deployment is `unchanged`, auto-runs `kubectl rollout restart` to push new config values to pods. |
| **9. Apply: HPA (conditional)** | Renders and applies `hpa.yaml.template`. Skipped if all four scaling fields are not set. |
| **10. Rollout watch** | Runs `kubectl rollout status` in background. At **30 seconds**: prints live `kubectl get pods` table if rollout still running. At `rollout_timeout`: shows diagnostics (events + logs), runs `kubectl rollout undo`, exits with failure. |
| **11. Post-deploy cleanup** | Prints live pods table. Deletes stale ConfigMaps. Writes audit record to `~/.kubeforge/history.log`. |

---

## Templates

KubeForge selects the template automatically. If `application.<country>.yaml` exists for the service, it uses `template-with-config.yaml`; otherwise `template-no-config.yaml`.

> All Kubernetes resource names use the pattern `$SERVICE_NAME-$COUNTRY` (e.g. `dashboard-backoffice-tz`). This allows multiple countries to run independently in the same namespace without name collisions.

### template-with-config.yaml — Spring Boot services

Used for: `dashboard-backoffice`, `dashboard-acquiring-api`, `dashboard-merchant-api`, `dashboard-job-processor`, `rest-handler`, `queue-handler`, `web`.

The pod spec contains three containers/init-containers:

- **initContainer `trust-cert`** — copies the JVM `cacerts` file and imports the service's TLS certificate using `keytool`. Required so Java can make TLS calls to the Ambassador host. Runs to completion before the main container starts.
- **Main container (`$SERVICE_NAME`)** — Spring Boot application. Mounts the generated ConfigMap at `/app/config/application.yaml`. Sets `SPRING_CONFIG_LOCATION`, `LOGGING_CONFIG`, and Java trust store env vars. Reads app secrets from `dashboard-application-secrets`.
- **Filebeat sidecar** — ships application logs from the shared `/logs` emptyDir volume to Elasticsearch. Reads credentials from `elk-credentials` secret.

### template-no-config.yaml — Frontend services

Used for: `backoffice-ui`, `merchant-portal`.

- **Main container (`$SERVICE_NAME`)** — nginx serving static frontend assets. No ConfigMap mount, no initContainer, no secrets injection.
- **Filebeat sidecar** — ships nginx access logs to Elasticsearch.

### Ambassador Mapping template

```yaml
apiVersion: getambassador.io/v3alpha1
kind: Mapping
metadata:
  name: $SERVICE_NAME-$COUNTRY-mapping
  namespace: $NAMESPACE
spec:
  host: "$AMBASSADOR_HOST"    # matches Ambassador Host resource (e.g. mixxmmp-test.tigo.co.tz)
  prefix: $PREFIX             # public URL path
  rewrite: $REWRITE           # path the app receives — almost always /
  service: $SERVICE_NAME-$COUNTRY-service.$NAMESPACE.svc.cluster.local:$PORT
  timeout_ms: 30000
```

> **Ambassador cache:** After updating a Mapping, if traffic is split between old and new pods, restart Ambassador: `kubectl rollout restart deployment ambassador -n ambassador`. This requires access to the `ambassador` namespace.

---

## GitLab CI Integration

`k8s/gitlab-ci-deploy.yml` is a ready-made deploy stage. Include it in your service repo's `.gitlab-ci.yml`. One pipeline job deploys all countries defined in `service.yaml` automatically — no per-country jobs needed.

### What the pipeline does

1. Reads all countries from `service.yaml` using `yq '.countries | keys | .[]'`
2. **Multi-module projects** (dashboard-application monorepo): copies `<service>/application.yaml` from the repo to `services/<service>/application.<country>.yaml` on the deploy server via SCP — once per country
3. **Single-module projects** (rest-handler, queue-handler, web): copies from `APP_CONFIG_DIR/application.yaml`
4. **Frontend projects** (backoffice-ui, merchant-portal): skips the config copy entirely
5. For each country: SSH to deploy server, writes new tag into `service.yaml`, runs `CI=true ./deploy.sh <service> --country <country>`

### Required CI/CD Variables

Set in GitLab: **Settings → CI/CD → Variables**

| Variable | Type | Value |
|----------|------|-------|
| `SSH_PRIVATE_KEY` | File | Private SSH key authorized to connect to the deploy server |
| `DEPLOY_USER` | Variable | `admin-dnf` |
| `DEPLOY_HOST` | Variable | IP or hostname of the deploy server |
| `K8S_DIR` | Variable | `/home/admin-dnf/k8s` |
| `CI_RUNNER_TAG` | Variable | GitLab runner tag for deploy jobs |
| `SERVICES` | Variable | Space-separated: `dashboard-acquiring-api dashboard-backoffice` |
| `APP_CONFIG_DIR` | Variable (optional) | Path to `application.yaml` for single-module projects. Default: `.` |

### Adding the deploy stage to a service repo

```yaml
# .gitlab-ci.yml in your service repository

include:
  - project: your-group/k8s
    file: gitlab-ci-deploy.yml

.common-rules:
  rules:
    - if: '$CI_COMMIT_TAG'   # deploy only on version tags (e.g. 1.0.5)
```

> The pipeline sets `CI=true` before running KubeForge, which bypasses all interactive prompts. The configmap diff confirmation and deploy diff confirmation are auto-accepted in CI mode.

---

## Deployed Services

All services run in namespace `test-mmp`. Container registry: `MixxMMP-registry-test.tigo.co.tz`.

| Service | Port | Countries | Current Tag (TZ) | Config Ver. | HPA | Template |
|---------|------|-----------|-----------------|-------------|-----|----------|
| `dashboard-backoffice` | 5501 | tz, tg | 1.0.92-TZ | v12 | off | with-config |
| `dashboard-acquiring-api` | 5503 | tz, tg | 1.0.86-TZ | v8 | 1–2 pods | with-config |
| `dashboard-merchant-api` | 5502 | tz, tg | 1.0.86-TZ | v6 | 1–2 pods | with-config |
| `dashboard-job-processor` | 8085 | tz, tg | 1.0.82-TZ | v4 | off | with-config |
| `rest-handler` | 8081 | tz, tg | 1.0.3 | v4 | off | with-config |
| `queue-handler` | 8080 | tz, tg | 1.0.1 | v1 | off | with-config |
| `web` | 7033 | tz, tg | 1.0.0 | v2 | off | with-config |
| `backoffice-ui` | 80 | tz, tg | 1.0.31 | — | off | no-config |
| `merchant-portal` | 80 | tz, tg | 1.0.21 | — | off | no-config |

### Kubernetes resource names (per service per country)

For example, `dashboard-backoffice` in Tanzania:

| Resource | Name |
|----------|------|
| Deployment | `dashboard-backoffice-tz` |
| Service | `dashboard-backoffice-tz-service` |
| ConfigMap | `dashboard-backoffice-config-tz-v12-1.0.92-tz` |
| Ambassador Mapping | `dashboard-backoffice-tz-mapping` (namespace: `test-mmp`) |
| Pod selector | `app=dashboard-backoffice-tz` |

### Ambassador hosts

| Country | Host | TLS Secret |
|---------|------|------------|
| Tanzania (tz) | `mixxmmp-test.tigo.co.tz` | `mixxmmp-tls-secret` |
| Togo (tg) | `togo.mixx.tg` | `tg-tls` |
| MetalLB VIP | `10.245.0.169` | Used in `hostAliases` so pods can reach their own public URL |

---

## Troubleshooting

### Pod not picking up config changes after deploy

**Symptom:** Deploy succeeds but pods still use old configuration values.

**Cause:** You changed values in `application.<country>.yaml` but the Deployment spec was unchanged (same image tag, same ConfigMap name). KubeForge now handles this automatically — it detects "ConfigMap updated but Deployment unchanged" and triggers `kubectl rollout restart`. If on an older version, run manually:

```bash
$ kubeforge dashboard-backoffice --country tz --restart
```

---

### CrashLoopBackOff after deploy

```bash
$ kubectl logs -n test-mmp -l app=dashboard-backoffice-tz --tail=50
$ kubectl describe pod -n test-mmp -l app=dashboard-backoffice-tz
```

**Common causes:**
- Missing or misspelled key in `application.<country>.yaml` — Spring Boot fails binding
- Wrong DB connection string or credentials in config
- `dashboard-application-secrets` missing a key the app expects
- **nginx only:** non-breaking spaces (U+00A0) in `nginx.conf` from copy-pasting — causes `unknown directive "    listen"`. Detect with `cat -A nginx.conf | grep 'M-BM-'`; fix with `sed -i 's/\xc2\xa0/ /g' nginx.conf`, then rebuild image.

---

### ImagePullBackOff

The image tag doesn't exist in the registry or `my-registry-secret` credentials have expired.

```bash
$ docker manifest inspect MixxMMP-registry-test.tigo.co.tz/dashboard-backoffice:1.0.92-TZ
```

---

### Rollout stuck at 30 seconds

KubeForge prints a live pod table at 30 seconds and auto-rollbacks at `rollout_timeout`. After rollback:

```bash
$ kubectl get events -n test-mmp --sort-by='.lastTimestamp' | tail -20
$ kubectl describe deployment dashboard-backoffice-tz -n test-mmp
```

---

### 404 on SPA assets (backoffice-ui, merchant-portal)

Vite hashes JS/CSS filenames on each build. A browser-cached `index.html` with old hash references causes 404 on assets. The nginx config must serve `index.html` with `Cache-Control: no-cache, no-store, must-revalidate`.

1. Hard-refresh browser: `Ctrl+Shift+R` / `Cmd+Shift+R`
2. Confirm asset exists in the pod: `kubectl exec -n test-mmp <pod> -- ls /usr/share/nginx/html/assets/`
3. If asset exists in pod but URL returns 404 — Ambassador may be routing to a stale upstream. Restart it:

```bash
$ kubectl rollout restart deployment ambassador -n ambassador
```

---

### Inspect a running pod's mounted config

```bash
# Start a temporary pod with the same image to inspect
$ kubectl run temp-inspect -n test-mmp \
    --image=MixxMMP-registry-test.tigo.co.tz/dashboard-backoffice:1.0.92-TZ \
    --restart=Never --command -- sleep 120
$ kubectl exec -n test-mmp temp-inspect -- cat /app/config/application.yaml
$ kubectl delete pod temp-inspect -n test-mmp
```

---

### Full health check

```bash
# Cluster-level: kubeconfig, API server, namespace access
$ kubeforge doctor

# Service-level: secrets, PVC, pod status, ConfigMap, image pull errors
$ kubeforge dashboard-backoffice --country tz --doctor

# Review recent deploy history
$ kubeforge history 30
```

---

*KubeForge — Internal tooling, MixxMMP Payment Platform*  
*Authored by Naimatullah Khan · July 2026*
