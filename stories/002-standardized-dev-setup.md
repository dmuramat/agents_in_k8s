# Story 002: Standardized Development Setup

## Context

This project bootstraps a local colima k3s cluster for running AI coding agents
(claude-cli, opencode, etc.) in isolated environments. Story 001 (completed) set
up the base cluster with Cilium, Traefik (Gateway API), ArgoCD, and a local git
server.

This story implements the per-agent development environment.

## Architecture Overview

```
┌─────────────────────────── k3s host cluster ───────────────────────────┐
│  ArgoCD (manages everything below)                                     │
│  Cilium (L7 network policies for agent isolation)                      │
│  Git server (static pod, serves config repo)                           │
│                                                                        │
│  ┌──── agent namespace (one per agent instance) ────────────────────┐  │
│  │                                                                  │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────────────┐     │  │
│  │  │ Agent CLI    │  │ MCP Server  │  │ MCP Server           │     │  │
│  │  │ container    │  │ (dedicated) │  │ (dedicated)          │     │  │
│  │  │ /workspace   │  │             │  │                      │     │  │
│  │  └─────────────┘  └─────────────┘  └──────────────────────┘     │  │
│  │                                                                  │  │
│  │  ┌──────────────────────────────────────────────────────────┐    │  │
│  │  │ vCluster (isolated mode)                                 │    │  │
│  │  │  - Traefik + Gateway API inside                          │    │  │
│  │  │  - K8s NetworkPolicies enforced                          │    │  │
│  │  │  - Managed remotely by host ArgoCD                       │    │  │
│  │  │  - Agent has full access via kubeconfig                  │    │  │
│  │  │  - Agent commits to git → ArgoCD syncs to vCluster       │    │  │
│  │  └──────────────────────────────────────────────────────────┘    │  │
│  │                                                                  │  │
│  │  CiliumNetworkPolicy: agent can reach MCP, vCluster, git only   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

## Decided Design Choices

These were discussed and agreed upon in story 001:

1. **MCP deployment**: Separate pod per agent (not sidecars, not shared).
   Exposed via Service in the same namespace. Independent lifecycle from agent.

2. **vCluster mode**: Use "isolated mode" (OSS feature) which adds
   NetworkPolicies, ResourceQuotas, LimitRanges. K8s-level netpol enforcement
   inside vCluster is sufficient; Cilium L7 policies are for host-cluster
   isolation of the agent container itself.

3. **ArgoCD manages vCluster contents remotely**: ArgoCD runs on the host
   cluster and manages applications inside each vCluster (multi-cluster pattern).
   Agents commit code to a git repo; ArgoCD watches the repo and syncs to the
   vCluster. Agents do NOT kubectl apply directly.

4. **Branch protection**: Use server-side `pre-receive` hook on the git server
   to reject pushes to `refs/heads/main`. Agents can only push branches.
   Consider upgrading to Gitea in a future story for PR support.

5. **Source repos**: Mounted as remote git repos into the agent container.
   Agent clones into `/workspace` (writable volume). Agent cannot merge to main.

6. **Docker runtime**: The cluster uses `--runtime docker` (colima), so
   `docker build` is available inside the VM for building agent/MCP images.

## Open Design Decisions (need resolution)

### 1. ApplicationSet generator
How are new agent environments triggered? Options discussed:
- **Git directory generator**: A directory per agent in this repo
- **List generator**: A config file listing active environments
- **Pull Request generator**: Tied to PR lifecycle
- **Manual**: `kubectl apply` an Application CR

Recommendation: Start with a List generator or a simple config directory.
The trigger mechanism can be refined later.

### 2. Agent container image / Dockerfile
Needs to be created. Should include:
- Git CLI
- Language runtimes (TBD — Python? Node? Both?)
- Claude CLI or opencode (or mounted as a volume?)
- SSH client (for git operations)
- kubeconfig for the vCluster (injected via init container or mounted secret)

### 3. MCP container images
Which MCP servers to run? This depends on the use case. The infrastructure
should be generic — each MCP is a container image + port + optional config.

### 4. vCluster version and distro
vCluster supports k3s, k0s, or vanilla k8s internally. k3s is lightest.
Check latest vCluster Helm chart for isolated mode configuration.

### 5. Network policy specifics
What domains/IPs should the agent be allowed to reach?
- Definitely: MCP services, vCluster API, git server
- Maybe: Container registries (for pulling images inside vCluster)
- Block: Internet at large (anti-exfiltration)

### 6. Traefik inside vCluster
How is Traefik provisioned inside each vCluster? Options:
- ArgoCD Application targeting the vCluster
- Part of the vCluster Helm values (init.manifests)

## Existing Infrastructure (from story 001)

### Repo structure
```
k3s-bootstrap/
├── scripts/
│   ├── setup.sh              # Bootstrap entrypoint
│   └── teardown.sh           # Destroy cluster
├── k3s-manifests/            # Copied to /var/lib/rancher/k3s/server/manifests/
│   ├── 00-cilium-helmchart.yaml
│   ├── 01-traefik-gateway-config.yaml
│   ├── 02-argocd-helmchart.yaml
│   ├── 03-git-server-namespace.yaml
│   ├── 03-git-server-service.yaml
│   ├── 04-argocd-repo-secret.yaml
│   └── 04-argocd-root-app.yaml
├── k3s-static-pods/          # Copied to /var/lib/rancher/k3s/agent/pod-manifests/
│   └── git-server.yaml
├── argocd-apps/              # Watched by ArgoCD app-of-apps (add apps here)
│   └── .gitkeep
└── stories/                  # Story descriptions
```

### Key details
- **Colima profile**: `k3s-bootstrap` (VM type: vz, runtime: docker)
- **k3s flags**: `--flannel-backend=none --disable-network-policy`
  (kube-proxy is NOT disabled — needed for Cilium operator bootstrap)
- **CNI symlink**: Setup script creates `/opt/cni/bin → /var/lib/rancher/k3s/data/cni`
  because Docker CRI looks in `/opt/cni/bin` while k3s installs CNI binaries elsewhere
- **Git server**: Static pod running `alpine:latest` with `git-daemon` package,
  serves repo at `git://git-server.git-server.svc.cluster.local/k3s-bootstrap`
- **ArgoCD root app**: Watches `argocd-apps/` directory — any Application YAML
  committed there gets auto-synced
- **ArgoCD accesses committed git state only** (not working tree changes)

### Gotchas discovered during implementation
1. `alpine/git` image does NOT include `git daemon` — use `alpine` + `apk add git-daemon`
2. Cilium `kubeProxyReplacement: true` causes operator bootstrap failure on single-node
   (operator pod can't reach API server at 127.0.0.1 without hostNetwork) — left disabled
3. Colima `--runtime docker` makes Docker available but k3s still uses its own containerd
   for CRI; however the CNI bin paths differ from a pure containerd setup
4. Colima needs `--vm-type vz` on macOS (no qemu installed)
5. HelmChartConfig for Traefik: `namespacePolicy` in gateway listeners must not be a
   plain string — use Traefik chart defaults instead of customizing listener details

## Suggested Implementation Order

1. **vCluster Helm chart as ArgoCD Application** — Get a single vCluster running,
   managed by ArgoCD. Place the Application YAML in `argocd-apps/`.
2. **Agent container Dockerfile** — Build a basic agent container image.
3. **Agent namespace manifests** — Pod spec for agent + MCP containers,
   Services for MCPs, vCluster kubeconfig injection.
4. **CiliumNetworkPolicy** — Restrict agent namespace egress.
5. **Pre-receive hook** — Add branch protection to git server.
6. **ApplicationSet** — Templatize the above for multiple agents.
7. **ArgoCD multi-cluster** — Configure ArgoCD to manage vCluster contents.

## How to test

```bash
./scripts/teardown.sh && ./scripts/setup.sh   # Clean bootstrap
kubectl get pods -A                            # All pods Running
kubectl get applications -n argocd             # Root app synced
```
