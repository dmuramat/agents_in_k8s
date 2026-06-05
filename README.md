# k3s-bootstrap

Local [colima](https://github.com/abiosoft/colima) k3s cluster that provisions isolated development environments for AI coding agents (Claude Code, OpenCode, etc.). Each agent gets its own namespace, vCluster, and network-isolated workspace.

## Prerequisites

- macOS with Apple Silicon (colima uses `--vm-type vz`)
- [colima](https://github.com/abiosoft/colima) installed
- [kubectl](https://kubernetes.io/docs/tasks/tools/) installed
- [helm](https://helm.sh/docs/intro/install/) installed

## Config repo

This repo holds reusable code only. Everything that describes *your* cluster —
agent definitions, DNS, egress allowlists, VM sizing, mount policy — lives in a
separate **config repo** you keep private. Start from the
[`k3s-bootstrap-config-template`](../k3s-bootstrap-config-template) and point at
it via a gitignored `scripts/config.local.sh`:

```bash
# Clone the template, make it private, then:
cp scripts/config.local.sh.example scripts/config.local.sh
# edit scripts/config.local.sh -> CONFIG_REPO_ROOT=/abs/path/to/your-config-repo
```

`setup.sh` mounts the config repo into the VM, serves it from the in-cluster
git-server alongside this repo, and ArgoCD reconciles agents from its `main`
branch. The config repo is **required** (it can define zero agents for an empty
cluster).

## Quick Start

```bash
# 0. One-time: clone the config template, make it private, wire it up
cp scripts/config.local.sh.example scripts/config.local.sh   # set CONFIG_REPO_ROOT

# 1. Define an agent (writes into your config repo)
./scripts/new-agent.sh agent-alpha \
  --repo=/Users/me/projects/myapp \
  --repo=/Users/me/projects/shared-lib

# 2. Commit in the CONFIG repo so the git-server/ArgoCD can see it
git -C "$CONFIG_REPO_ROOT" add agents/agent-alpha.yaml \
  && git -C "$CONFIG_REPO_ROOT" commit -m "add agent-alpha"

# 3. Bootstrap the cluster (takes ~3 minutes)
./scripts/setup.sh

# Check status
kubectl get applications -n argocd

# Shell into the agent
kubectl exec -it -n agent-alpha agent-cli -- bash
```

> Note: under constricted mounts, adding an agent whose repo path is a new host
> directory means the colima VM must be recreated to mount it
> (`./scripts/teardown.sh && ./scripts/setup.sh`). setup.sh's drift guard will
> tell you when a VM-creation-time setting changed.

First time validating the config-repo separation? Follow
[`TESTING.md`](TESTING.md) — non-destructive checks first, then the full
teardown/rebuild and end-to-end verification.

## Architecture

```
┌─────────────────── k3s host cluster ────────────────────┐
│  ArgoCD (manages everything via app-of-apps)            │
│  Cilium (CNI + L7 network policies)                     │
│  Traefik (Gateway API, TLS passthrough)                 │
│  Git server (static pod, serves code + config repos)    │
│                                                         │
│  ┌──── agent namespace (one per agent) ──────────────┐  │
│  │  Agent CLI pod (/workspace, kubectl, claude-code)  │  │
│  │  CiliumNetworkPolicy (FQDN-based egress allowlist)│  │
│  │  TLSRoute (SNI passthrough to vCluster)           │  │
│  │                                                    │  │
│  │  vCluster (isolated mode, K8s v1.32.3)            │  │
│  │    ├── Traefik (terminates TLS, same as prod)     │  │
│  │    └── Agent deploys workloads here               │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Traffic flow (browser → agent's app)

```
Mac browser → https://agent-alpha.local
    │  TLSRoute (SNI passthrough, no termination)
Host Traefik
    │  backendRef → synced vCluster Traefik Service
vCluster Traefik (terminates TLS, mirrors test/prod)
    │  HTTPRoutes inside vCluster
Keycloak / Backend / Frontend
```

## What `setup.sh` does

1. Starts a colima VM with k3s (flannel disabled, Cilium as CNI)
2. Copies bootstrap manifests into the VM:
   - Cilium HelmChart
   - Gateway API experimental CRDs (TLSRoute support)
   - ArgoCD HelmChart
   - Git server namespace + service
   - ArgoCD root Application + repo secret
   - CoreDNS custom forwarder (colima DNS fix)
3. Copies the git server static pod manifest
4. Builds the `agent-cli` Docker image inside colima
5. Waits for Cilium, node Ready, ArgoCD, and git server

After setup, ArgoCD takes over:
- Root app syncs `argocd-apps/` → installs Traefik, Gateway, ApplicationSets
- ApplicationSets discover `agents/*.yaml` **in the config repo** → provision
  agent environments (multi-source: chart from this repo, values from config repo)

## What `new-agent.sh` does

Creates a values file at `<config-repo>/agents/<name>.yaml`. Once committed in the config repo, ArgoCD automatically provisions:

| Resource | Chart | Purpose |
|----------|-------|---------|
| Namespace, Pod, CiliumNetworkPolicy, TLSRoute | `charts/agent-env` | Agent workspace + network isolation |
| vCluster Application, RBAC, registration Job | `charts/agent-vcluster` | Isolated K8s cluster for the agent |
| Traefik inside vCluster | `argocd-apps/vcluster-traefik-appset.yaml` | TLS termination (mirrors test/prod) |

### Repo mounting

```bash
./scripts/new-agent.sh agent-alpha --repo=/Users/me/projects/myapp
```

- Host repo mounted read-write at `/repos/myapp`
- Cloned to `/workspace/myapp` (init container)
- Pre-commit hook on the clone blocks commits to `main`/`master`
- Agent pushes branches to origin (`/repos/myapp` = your local repo)
- Host paths must be under `~` (colima mounts home dir by default)

### Customizing per agent

Override any chart default in `agents/<name>.yaml`:

```yaml
name: my-agent

# Use a different CLI image (default: agent-cli:latest)
image:
  repository: gemini-cli
  tag: latest

# Disable vCluster (default: true)
vcluster:
  enabled: false

# Use a different instructions configmap (default: claude-md, created by chart)
agentConfig:
  configMapName: gemini-md   # must exist in the agent namespace
  # enabled: false           # or disable entirely

# Mount external cluster kubeconfigs (e.g. read-only prod access)
externalClusters:
  - name: prod-readonly
    secretName: prod-kubeconfig
```

**External clusters**: Create the Secret before or after the agent starts (the pod will wait). The Secret must have a `config` key containing a kubeconfig file. Mounted as a directory (not subPath) so the kubelet auto-rotates it when the Secret changes.

```bash
# Create a read-only kubeconfig Secret for production
kubectl create secret generic prod-kubeconfig -n my-agent \
  --from-file=config=/path/to/prod-readonly-kubeconfig

# Inside the agent pod, switch contexts:
kubectl config get-contexts    # shows all available clusters
kubectl config use-context prod-readonly
```

When both vCluster and external clusters are configured, `KUBECONFIG` is set to a colon-separated list and kubectl merges all contexts.

**Overriding in-cluster discovery**: Kubernetes auto-injects `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT` into every pod, pointing at the host cluster API. If the agent should default to an external cluster, override these with `extraEnv` so tools that use in-cluster config reach the right API server:

```yaml
extraEnv:
  - name: KUBERNETES_SERVICE_HOST
    value: "my-cluster.example.com"
  - name: KUBERNETES_SERVICE_PORT
    value: "6443"
```

## Inside the agent pod

```bash
kubectl exec -it -n agent-alpha agent-cli -- bash

# Tools available:
claude --version      # Claude Code CLI
kubectl get nodes     # kubectl with vCluster kubeconfig
git branch            # repos cloned to /workspace/<name>
python3 --version     # Python 3
node --version        # Node.js / npm
```

The agent has `kubectl` access to its vCluster (kubeconfig auto-mounted). It can deploy workloads there but cannot access the host cluster or other agents' namespaces.

## Network isolation

The agent pod's egress is restricted by a CiliumNetworkPolicy with FQDN-based rules:

| Category | Allowed destinations |
|----------|---------------------|
| In-cluster | MCP services (same ns), vCluster API, git server, kube-dns |
| Docs | github.com, kubernetes.io, helm.sh, go.dev, pkg.go.dev, pypi.org, npmjs.com, stackoverflow.com, artifacthub.io, docs.docker.com |
| Registries | docker.io, ghcr.io, registry.k8s.io |
| APIs | api.anthropic.com |
| Certs | letsencrypt.org |

Everything else is blocked (default-deny). The full list is configurable in `charts/agent-env/values.yaml`.

## Repo structure

```
k3s-bootstrap/
├── scripts/
│   ├── setup.sh              # Bootstrap the cluster
│   ├── teardown.sh           # Destroy the cluster
│   ├── new-agent.sh          # Create a new agent environment (writes to config repo)
│   ├── lib-config.sh         # Shared config/mount/fingerprint resolution
│   └── config.local.sh.example  # Per-machine pointer to the config repo (copy -> config.local.sh)
├── k3s-manifests/            # Copied to k3s server manifests at bootstrap (config repo overlays on top)
│   ├── 00-cilium-helmchart.yaml
│   ├── 01-gateway-api-crds.yaml
│   ├── 02-argocd-helmchart.yaml
│   ├── 03-git-server-*.yaml
│   ├── 04-argocd-*.yaml      # repo secrets for both the code + config repos
│   └── 05-coredns-custom.yaml.example  # active coredns-custom comes from the config repo
├── k3s-static-pods/          # Copied to k3s static pod manifests
│   └── git-server.yaml.tmpl  # rendered with both repo paths at bootstrap (serves code + config)
├── argocd-apps/              # Synced by ArgoCD root app
│   ├── traefik.yaml          # Host Traefik (Gateway API)
│   ├── agent-gateway.yaml    # TLS passthrough Gateway
│   ├── agent-appset.yaml     # Agent env + vCluster ApplicationSets (multi-source)
│   └── vcluster-traefik-appset.yaml  # Traefik inside each vCluster
├── charts/
│   ├── agent-env/            # Helm chart: namespace, pod, netpol, TLSRoute
│   └── agent-vcluster/       # Helm chart: vCluster, RBAC, registration
├── agents/                   # empty here — agent value files live in the config repo
└── stories/                  # Design documents
```

The cluster's definition (agents, DNS, egress, VM sizing, mounts, **and the
agent container images** in `docker/`) lives in a separate **config repo** — see
[Config repo](#config-repo) and the `k3s-bootstrap-config-template`. setup.sh
builds the images listed in the config repo's `cluster.conf` (`AGENT_IMAGES`).

## Teardown

```bash
./scripts/teardown.sh    # Destroys the colima VM entirely
```

Cluster state is recoverable: `setup.sh` re-bootstraps from the code + config repos. Agent environments are recreated automatically from the committed `agents/*.yaml` files in the config repo.

## Design decisions

Non-obvious choices and why they were made:

### Traefik installed via ArgoCD, not k3s HelmChart

k3s bundles Traefik and installs its CRDs automatically. Those built-in CRDs conflict with the experimental Gateway API CRDs (TLSRoute, TCPRoute) we need for TLS passthrough. Disabling k3s's Traefik (`--disable=traefik`) and installing it via an ArgoCD Application gives us full control over CRD installation order and Traefik configuration.

### kubeProxyReplacement: false

Cilium's `kubeProxyReplacement: true` causes bootstrap failure on single-node k3s. The Cilium operator pod can't reach the API server at 127.0.0.1:6443 without hostNetwork when kube-proxy isn't running yet. Keeping kube-proxy avoids this chicken-and-egg problem.

### Hubble Relay hostNetwork patch (setup.sh)

With `kubeProxyReplacement: false`, pod-to-hostPort traffic doesn't work reliably on single-node k3s. Hubble Relay needs to reach the Cilium agent's hostPort 4244. The fix: run Relay on hostNetwork with its own hostPort 4245, and set `dnsPolicy: ClusterFirstWithHostNet` so it can still resolve cluster DNS. This is applied as a strategic merge patch in setup.sh after Cilium starts.

### metrics-server disabled

ArgoCD v3.3.6 has a bug where `populatePodInfo` panics (`assignment to entry in nil map`) when processing pods without resource limits in remote clusters. The `v1beta1.metrics.k8s.io` APIService (registered by metrics-server) triggers this code path even if metrics-server has no running pods. Disabling metrics-server entirely avoids the panic.

### vCluster isolated mode + CiliumNetworkPolicies

vCluster's isolated mode adds K8s NetworkPolicies, ResourceQuotas, and LimitRanges inside the virtual cluster. However, K8s NetworkPolicies in Cilium behave differently than vanilla kube-proxy: a ports-only egress rule (no `to` selector) means "allow to any pod," not "allow to any IP." Since the K8s API ClusterIP isn't a pod, vCluster can't reach it. This is why `charts/agent-vcluster` includes dedicated CiliumNetworkPolicies for API server, ArgoCD, agent pod, and host Traefik access.

### Registration Job for vCluster → ArgoCD

ArgoCD needs a cluster Secret to manage workloads inside each vCluster. But the vCluster kubeconfig (Secret `vc-vcluster`) doesn't exist until vCluster starts, creating a chicken-and-egg problem. The `cluster-registration-job.yaml` solves this: it waits for the Secret, extracts the kubeconfig, and creates an ArgoCD cluster Secret with `purpose: agent-vcluster` label. The vCluster Traefik ApplicationSet uses this label as its cluster generator selector.

### Role names include agent name

The ArgoCD namespace Role for writing cluster Secrets (`argocd-cluster-secret-writer-{{ .Values.name }}`) must be unique per agent. If two agents share the same Role name, ArgoCD's tracking annotation ping-pongs between the two Applications, causing perpetual OutOfSync.

### CoreDNS custom forwarder

colima's `--vm-type vz` VMs have `/etc/resolv.conf` pointing to 192.168.5.3, but nothing listens on :53 at that IP. CoreDNS inherits this broken upstream. The fix is a ConfigMap that overrides the forward plugin to use 8.8.8.8 directly.

### FQDN egress rules require dns proxy config

CiliumNetworkPolicy FQDN-based egress rules (e.g. `toFQDNs: matchName: "github.com"`) only work if Cilium's DNS proxy has seen the DNS response. The DNS allow rule must include `rules.dns` with `matchPattern: "*"` — this tells Cilium to intercept DNS traffic and populate its FQDN cache. Without it, FQDN rules silently match nothing. Also: never combine `egressDeny` with `egress` in the same policy — deny rules take precedence and override the allow rules.

### All vCluster workloads need resource limits

Due to the ArgoCD panic bug mentioned above, every pod deployed into a vCluster (including Traefik, user workloads) must have resource requests and limits. The vCluster's LimitRange provides defaults, but explicit limits are safer.

## Known issues

- **ArgoCD health on vCluster resources**: `traefik-agent-alpha` may show `Progressing` instead of `Healthy` — cosmetic, all pods are actually running
- **Colima mounts**: Only paths under `~` are available inside the VM. Paths like `/opt` or external volumes won't work without explicit `--mount` flags
- **vCluster K8s version**: Pinned to v1.32.3 (latest available `ghcr.io/loft-sh/kubernetes` image). ArgoCD v3.3.6 panics on pods without resource limits in remote clusters, so all workloads inside vCluster must have resource requests/limits set
