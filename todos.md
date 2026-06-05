# Completed

## Story 001: Base Cluster
- [x] Git server setup (using alpine + git-daemon as static pod)
- [x] ArgoCD HelmChart CR and app-of-apps root Application
- [x] Cilium CNI HelmChart CR
- [x] Colima setup script with k3s flags
- [x] Bootstrap manifest structure (k3s-manifests/, k3s-static-pods/)
- [x] Test full bootstrap cycle

## Story 002: Standardized Dev Setup
- [x] Traefik installed by ArgoCD (argocd-apps/traefik.yaml) with Gateway API + experimentalChannel
- [x] Gateway API experimental CRDs (TLSRoute) as bootstrap manifest
- [x] Gateway resource with TLS passthrough listener (argocd-apps/agent-gateway.yaml)
- [x] ApplicationSet: git file generator for agents/*.yaml (argocd-apps/agent-appset.yaml)
- [x] ApplicationSet: deploy Traefik into each vCluster (argocd-apps/vcluster-traefik-appset.yaml)
- [x] Helm chart: agent-env (namespace, pod w/ repo cloning + pre-commit hooks, CiliumNetworkPolicy, TLSRoute)
- [x] Helm chart: agent-vcluster (vCluster app, RBAC, cluster registration Job, Cilium policies)
- [x] Agent CLI Dockerfile (git, python3, node, kubectl, claude-code, karellen-lsp-mcp + pylsp)
- [x] setup.sh: build agent-cli image, disable metrics-server + traefik in k3s, CoreDNS fix
- [x] new-agent.sh: generates agent values file with --repo= args
- [x] Fix CoreDNS: forward to 8.8.8.8 (colima VM has no local DNS resolver)
- [x] Fix vCluster: CiliumNetworkPolicies for API server, ArgoCD, and agent pod access
- [x] Fix vCluster: exportKubeConfig.server with FQDN, insecure TLS in cluster secret
- [x] Fix vCluster: k8s distro pinned to v1.32.3 (latest available image)
- [x] Fix vCluster Traefik: ClusterIP + resource limits (ArgoCD panics on pods without limits)
- [x] Fix init container: use alpine/git (no network in isolated mode namespace)
- [x] Fix agent UID: userdel ubuntu, useradd -u 1000 agent, chown workspace in init container
- [x] Verified: full teardown + setup cycle works end-to-end
- [x] Verified: agent-cli pod runs with cloned repo, pre-commit hooks, kubectl into vCluster, claude-code

# Remaining

- [x] Verify CiliumNetworkPolicy FQDN egress rules (allowed sites respond, blocked sites timeout)
- [x] Fix FQDN policy: removed egressDeny (overrides allow rules), added dns proxy rules for FQDN cache
- [x] Fix host Traefik: moved from k3s HelmChartConfig to ArgoCD Application (avoids CRD conflict)
- [x] README with architecture, usage, and repo structure

## Story 002: Open Items
- [x] Configurable agent images: allow per-agent override of `image.repository`/`image.tag` in agents/*.yaml (docker/claude-cli and docker/gemini-cli already exist)
- [x] Toggleable vCluster: add `vcluster.enabled` (default: true) so agents can opt out of vCluster provisioning. All agent-vcluster templates conditional.
- [x] Exchangeable CLAUDE.md configmap: `agentConfig.configMapName` (default: "claude-md") + `agentConfig.enabled` (default: true). Chart only creates default ConfigMap when name is "claude-md".
- [x] Adapt agent-pod.yaml to handle missing vCluster (no kubeconfig volume mount when vCluster is disabled)
- [x] External cluster kubeconfig support: `externalClusters` list mounts pre-existing Secrets as kubeconfigs (directory mount for token rotation)
- [ ] Verify TLS passthrough routing end-to-end (needs a real workload deployed in vCluster)
- [ ] Investigate ArgoCD health assessment on vCluster resources (cosmetic: shows Progressing)
- [ ] Colima mounts: paths outside ~ not available; may need explicit --mount
- [ ] Agent git config: set user.name/email inside agent container for commits

## Future Stories
- [ ] MCP server pods: deploy dedicated MCP containers (e.g. filesystem, browser) as separate pods per agent, exposed via Service (role: mcp label for netpol)
- [ ] Writable git server: upgrade git-daemon to SSH/HTTP transport so agents can push branches; enforce pre-receive hook rejecting main pushes
- [ ] Gitea: replace minimal git server with Gitea for PR-based workflow
- [ ] Clean bootstrap test: automate teardown+setup+verify as a CI-like script
