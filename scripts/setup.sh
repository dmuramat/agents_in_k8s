#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COLIMA_PROFILE="${COLIMA_PROFILE:-k3s-bootstrap}"

# Load per-machine pointer + committed cluster definition (sets CONFIG_REPO_ROOT,
# PUBLIC_REPO_ROOT, CPUS/MEMORY/DISK, CONSTRICT_MOUNTS, K3S_ARGS, mount helpers).
# shellcheck source=lib-config.sh
source "${SCRIPT_DIR}/lib-config.sh"
load_local_config
load_cluster_conf
validate_config_repo

# k3s manifests destination inside the VM
K3S_MANIFESTS_DIR="/var/lib/rancher/k3s/server/manifests"
K3S_STATIC_PODS_DIR="/var/lib/rancher/k3s/agent/pod-manifests"

log() { echo "==> $*"; }
warn() { echo "==> [WARN] $*" >&2; }
err() { echo "==> [ERROR] $*" >&2; exit 1; }

wait_for_kubectl() {
  log "Waiting for k3s API server..."
  local retries=60
  for ((i = 1; i <= retries; i++)); do
    if kubectl get nodes &>/dev/null; then
      return 0
    fi
    sleep 2
  done
  err "k3s API server not reachable after ${retries} attempts"
}

wait_for_pods() {
  local namespace="$1"
  local label="$2"
  local timeout="${3:-300}"
  log "Waiting for pods ${label} in ${namespace} (timeout: ${timeout}s)..."
  kubectl wait --for=condition=Ready pod \
    -l "${label}" \
    -n "${namespace}" \
    --timeout="${timeout}s" 2>/dev/null || true
}

# Render a *.yaml.tmpl static-pod manifest, substituting the two repo roots.
render_tmpl() {
  sed -e "s#\${PUBLIC_REPO_ROOT}#${PUBLIC_REPO_ROOT}#g" \
      -e "s#\${CONFIG_REPO_ROOT}#${CONFIG_REPO_ROOT}#g" "$1"
}

# --- Step 0: Guard against changing VM-immutable settings on an existing VM ---
check_fingerprint

log "Config repo:   ${CONFIG_REPO_ROOT}"
log "VM resources:  ${CPUS} CPU / ${MEMORY} GiB RAM / ${DISK} GiB disk"

# --- Step 1: Start colima ---
log "Starting colima profile '${COLIMA_PROFILE}' with k3s..."

if colima status --profile "${COLIMA_PROFILE}" &>/dev/null; then
  log "Colima profile '${COLIMA_PROFILE}' is already running."
else
  # Build the colima mount list. When CONSTRICT_MOUNTS=true we pass explicit
  # mounts (public repo, config repo, every agent repo path). Otherwise colima
  # auto-mounts all of $HOME (the historical, broad behavior).
  MOUNT_ARGS=()
  if [[ "${CONSTRICT_MOUNTS}" == "true" ]]; then
    log "Mount policy:  constricted (explicit mounts only)"
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      log "  mount ${path}"
      MOUNT_ARGS+=(--mount "${path}:w")
    done < <(collect_mounts)
    # NOTE: with explicit --mount entries, recent colima serves only those paths.
    # If your colima version still auto-mounts $HOME alongside them, full
    # constriction is not achieved (everything still works, but isolation is
    # weaker) -- verify with: colima ssh --profile ${COLIMA_PROFILE} -- ls "${HOME}"
    # To fall back to the broad mount deliberately, set CONSTRICT_MOUNTS=false
    # in the config repo's cluster.conf.
  else
    warn "Mount policy: broad ($HOME mounted writable). Set CONSTRICT_MOUNTS=true in cluster.conf to restrict."
  fi

  colima start \
    --profile "${COLIMA_PROFILE}" \
    --vm-type vz \
    --runtime docker \
    --kubernetes \
    --cpu "${CPUS}" \
    --memory "${MEMORY}" \
    --disk "${DISK}" \
    "${MOUNT_ARGS[@]}" \
    "${K3S_ARGS[@]/#/--k3s-arg=}"

  # Pin the API server port to 6443 (in K3S_ARGS). colima otherwise assigns a
  # new random --https-listen-port on every start, but k3s persists its
  # control-plane cred kubeconfigs (referencing that port) on the persistent
  # data disk. A fixed port keeps the stored creds consistent across restarts.

  # Record the VM-creation-time fingerprint so future runs can detect drift.
  save_fingerprint
fi

# --- Step 2: Wait for API server ---
wait_for_kubectl

# --- Step 3: Symlink CNI bin path for Docker runtime ---
# k3s puts CNI binaries in /var/lib/rancher/k3s/data/cni/ but Docker's CRI
# looks in /opt/cni/bin/. Symlink so Docker finds Cilium and other CNI plugins.
log "Setting up CNI bin path symlink..."
colima ssh --profile "${COLIMA_PROFILE}" -- sudo mkdir -p /opt/cni
colima ssh --profile "${COLIMA_PROFILE}" -- sudo ln -sfn /var/lib/rancher/k3s/data/cni /opt/cni/bin

# --- Step 4: Copy manifests into the VM (public base, then config overlay) ---
# The config repo wins on filename collisions, so its coredns-custom and any
# other overlays are applied last.
copy_manifests() {
  local src_dir="$1" dest_dir="$2" label="$3"
  shopt -s nullglob
  local manifest filename
  for manifest in "${src_dir}"/*.yaml; do
    filename="$(basename "${manifest}")"
    colima ssh --profile "${COLIMA_PROFILE}" -- \
      sudo tee "${dest_dir}/${filename}" <"${manifest}" >/dev/null
    log "  [${label}] ${filename}"
  done
  shopt -u nullglob
}

log "Copying k3s manifests into the VM..."
copy_manifests "${PUBLIC_REPO_ROOT}/k3s-manifests" "${K3S_MANIFESTS_DIR}" "public"
copy_manifests "${CONFIG_REPO_ROOT}/k3s-manifests" "${K3S_MANIFESTS_DIR}" "config"

log "Copying static pod manifests into the VM..."
colima ssh --profile "${COLIMA_PROFILE}" -- sudo mkdir -p "${K3S_STATIC_PODS_DIR}"
# Templated static pods (e.g. git-server) need the host repo paths injected.
shopt -s nullglob
for tmpl in "${PUBLIC_REPO_ROOT}"/k3s-static-pods/*.yaml.tmpl; do
  filename="$(basename "${tmpl%.tmpl}")"
  render_tmpl "${tmpl}" \
    | colima ssh --profile "${COLIMA_PROFILE}" -- \
        sudo tee "${K3S_STATIC_PODS_DIR}/${filename}" >/dev/null
  log "  [public] ${filename} (rendered)"
done
shopt -u nullglob
copy_manifests "${PUBLIC_REPO_ROOT}/k3s-static-pods" "${K3S_STATIC_PODS_DIR}" "public"
copy_manifests "${CONFIG_REPO_ROOT}/k3s-static-pods" "${K3S_STATIC_PODS_DIR}" "config"

# --- Step 5: Build agent container images (from the config repo's docker/) ---
log "Building agent container images inside colima..."
build_agent_images

# --- Step 6: Wait for core components ---
log "Waiting for Cilium to be ready..."
# Cilium agent runs on hostNetwork, so it can start without a CNI
wait_for_pods "kube-system" "app.kubernetes.io/name=cilium-agent" 300

log "Patching Hubble Relay for single-node connectivity..."
# Hubble Relay can't reach Cilium agent's hostPort 4244 from pod network
# on single-node k3s with kubeProxyReplacement=false. Fix:
# 1. Run Relay on host network so it can reach the agent directly
# 2. Set hostPort on Relay so the hubble-relay Service can still find it
# 3. Set dnsPolicy so it can resolve cluster DNS from host network
kubectl patch deployment hubble-relay -n kube-system --type strategic -p '
{
  "spec": {
    "template": {
      "spec": {
        "hostNetwork": true,
        "dnsPolicy": "ClusterFirstWithHostNet",
        "containers": [{
          "name": "hubble-relay",
          "ports": [{
            "name": "grpc",
            "containerPort": 4245,
            "hostPort": 4245,
            "protocol": "TCP"
          }]
        }]
      }
    }
  }
}' 2>/dev/null || true

log "Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

log "Waiting for ArgoCD to be ready..."
wait_for_pods "argocd" "app.kubernetes.io/name=argocd-server" 300

log "Waiting for git server pod..."
# Static pods have a node name suffix; wait for any pod with our label
retries=30
for ((i = 1; i <= retries; i++)); do
  if kubectl get pod -n git-server -l app=git-server --no-headers 2>/dev/null | grep -q Running; then
    break
  fi
  sleep 5
done

# --- Step 7: Summary ---
echo ""
log "Bootstrap complete!"
echo ""
echo "  Colima profile:  ${COLIMA_PROFILE}"
echo "  Config repo:     ${CONFIG_REPO_ROOT}"
echo "  Cilium:          $(kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo 'pending')"
echo "  Traefik:         $(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo 'pending')"
echo "  ArgoCD:          $(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo 'pending')"
echo "  Git server:      $(kubectl get pod -n git-server -l app=git-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo 'pending')"
echo ""
echo "  ArgoCD UI:       kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  ArgoCD password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
