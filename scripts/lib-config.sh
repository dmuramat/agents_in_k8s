#!/usr/bin/env bash
# Shared configuration resolution for k3s-bootstrap scripts.
# Sourced by setup.sh, new-agent.sh, remove-agent.sh.
#
# Model: the public repo holds reusable code; a separate (private) "config repo"
# holds this cluster's definition (agents, DNS, egress, VM sizing, mount policy).
# A gitignored per-machine pointer file (config.local.sh) names where that config
# repo lives on this host. This lib loads both and derives everything setup.sh
# needs: VM settings, the colima mount set, and a drift-detection fingerprint.

# Guard against double-sourcing.
[[ -n "${_K3S_LIB_CONFIG_LOADED:-}" ]] && return 0
_K3S_LIB_CONFIG_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_REPO_ROOT="$(cd "${_LIB_DIR}/.." && pwd)"
LOCAL_CONFIG_FILE="${_LIB_DIR}/config.local.sh"
FINGERPRINT_FILE="${_LIB_DIR}/.vm-fingerprint"

# VM-creation-time k3s args. These are baked in at `colima start` and cannot be
# changed without recreating the VM, so they are part of the immutable fingerprint.
#   - flannel:        replaced by Cilium CNI
#   - network-policy: Cilium handles this
#   - metrics-server: its APIService panics ArgoCD when it has no backing pods
#   - traefik:        we install Traefik ourselves via HelmChart CR
#   - https-listen-port pinned so persisted k3s creds keep matching the port
K3S_ARGS=(
  '--https-listen-port=6443'
  '--flannel-backend=none'
  '--disable-network-policy'
  '--disable=metrics-server'
  '--disable=traefik'
)

_cfg_err() { echo "==> [ERROR] $*" >&2; exit 1; }

# Load the per-machine pointer file and resolve CONFIG_REPO_ROOT.
load_local_config() {
  if [[ ! -f "${LOCAL_CONFIG_FILE}" ]]; then
    _cfg_err "Missing ${LOCAL_CONFIG_FILE}
    This file points at your (private) config repo. Create it:
      cp ${_LIB_DIR}/config.local.sh.example ${LOCAL_CONFIG_FILE}
      \$EDITOR ${LOCAL_CONFIG_FILE}"
  fi
  # shellcheck disable=SC1090
  source "${LOCAL_CONFIG_FILE}"

  [[ -n "${CONFIG_REPO_ROOT:-}" ]] || _cfg_err "CONFIG_REPO_ROOT is not set in ${LOCAL_CONFIG_FILE}"
  CONFIG_REPO_ROOT="${CONFIG_REPO_ROOT/#\~/${HOME}}"
  [[ -d "${CONFIG_REPO_ROOT}" ]] || _cfg_err "CONFIG_REPO_ROOT does not exist: ${CONFIG_REPO_ROOT}"
  CONFIG_REPO_ROOT="$(cd "${CONFIG_REPO_ROOT}" && pwd)"
  export CONFIG_REPO_ROOT PUBLIC_REPO_ROOT
}

# Verify the config repo has the structure setup.sh depends on.
validate_config_repo() {
  [[ -f "${CONFIG_REPO_ROOT}/cluster.conf" ]] \
    || _cfg_err "config repo is missing cluster.conf: ${CONFIG_REPO_ROOT}/cluster.conf"
  [[ -d "${CONFIG_REPO_ROOT}/agents" ]] \
    || _cfg_err "config repo is missing the agents/ directory: ${CONFIG_REPO_ROOT}/agents"
  [[ -f "${CONFIG_REPO_ROOT}/k3s-manifests/05-coredns-custom.yaml" ]] \
    || _cfg_err "config repo is missing k3s-manifests/05-coredns-custom.yaml"
}

# Load cluster.conf (committed cluster definition) and resolve VM settings.
# Precedence: cluster.conf is the base; values set via env or config.local.sh
# take precedence over it (snapshotted here because config.local.sh is already
# sourced by the time this runs).
load_cluster_conf() {
  local _ov_cpus="${CPUS:-}" _ov_mem="${MEMORY:-}" _ov_disk="${DISK:-}"

  EXTRA_MOUNTS=()
  AGENT_IMAGES=()
  # shellcheck disable=SC1091
  source "${CONFIG_REPO_ROOT}/cluster.conf"

  [[ -n "${_ov_cpus}" ]] && CPUS="${_ov_cpus}"
  [[ -n "${_ov_mem}" ]] && MEMORY="${_ov_mem}"
  [[ -n "${_ov_disk}" ]] && DISK="${_ov_disk}"

  CPUS="${CPUS:-4}"
  MEMORY="${MEMORY:-16}"
  DISK="${DISK:-100}"
  CONSTRICT_MOUNTS="${CONSTRICT_MOUNTS:-true}"
  export CPUS MEMORY DISK CONSTRICT_MOUNTS
}

# Print every host path referenced as a repo hostPath in the config repo agents.
collect_agent_repo_paths() {
  shopt -s nullglob
  local f
  for f in "${CONFIG_REPO_ROOT}"/agents/*.yaml; do
    sed -nE 's/^[[:space:]]*-?[[:space:]]*hostPath:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "${f}"
  done
  shopt -u nullglob
}

# Print the unique, absolute host directories that must be mounted into the VM:
# the public repo, the config repo, every agent's repo path, plus EXTRA_MOUNTS.
collect_mounts() {
  local m
  {
    printf '%s\n' "${PUBLIC_REPO_ROOT}" "${CONFIG_REPO_ROOT}"
    collect_agent_repo_paths
    for m in "${EXTRA_MOUNTS[@]:-}"; do
      [[ -n "${m}" ]] && printf '%s\n' "${m/#\~/${HOME}}"
    done
    # Force a success status: with EXTRA_MOUNTS empty the loop's last command is
    # a failed `[[ -n "" ]]`, which under `set -o pipefail` would make the whole
    # pipeline (and any `$(collect_mounts)` caller under `set -e`) abort.
    :
  } | sed -E 's#/+$##' | awk 'NF' | LC_ALL=C sort -u
}

# Hash of everything fixed at VM-creation time. Drift here means the running VM
# can no longer satisfy the requested config without being recreated.
compute_fingerprint() {
  {
    echo "cpus=${CPUS}"
    echo "memory=${MEMORY}"
    echo "disk=${DISK}"
    echo "constrict=${CONSTRICT_MOUNTS}"
    printf 'k3sarg=%s\n' "${K3S_ARGS[@]}"
    collect_mounts | sed 's/^/mount=/'
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

_vm_profile_exists() { [[ -d "${HOME}/.colima/${COLIMA_PROFILE:-k3s-bootstrap}" ]]; }

# Refuse to continue if a VM already exists and an immutable setting changed.
check_fingerprint() {
  local current stored
  current="$(compute_fingerprint)"
  if _vm_profile_exists && [[ -f "${FINGERPRINT_FILE}" ]]; then
    stored="$(cat "${FINGERPRINT_FILE}")"
    if [[ "${stored}" != "${current}" ]]; then
      _cfg_err "VM-creation-time settings changed since this cluster was created.
    cpu/memory/disk, k3s args, the mount policy, or the set of agent repo paths
    differ from what the VM was built with. These cannot be applied to a running
    colima VM. To rebuild with the new settings:
      ./scripts/teardown.sh && ./scripts/setup.sh
    (stored ${stored} != current ${current})"
    fi
  fi
}

save_fingerprint() { compute_fingerprint >"${FINGERPRINT_FILE}"; }

# Build the agent container images declared in cluster.conf's AGENT_IMAGES.
# Each entry is "<dir>=<tag>": build <config-repo>/docker/<dir> as <tag> inside
# the VM. The config repo is mounted, so the build context is reachable there.
# Images are NOT part of the VM fingerprint -- they can be rebuilt any time
# without recreating the VM (see rebuild-agent-image.sh).
build_agent_images() {
  if [[ ${#AGENT_IMAGES[@]} -eq 0 ]]; then
    echo "==> No AGENT_IMAGES declared in cluster.conf; skipping image build."
    return 0
  fi
  local entry dir tag ctx
  for entry in "${AGENT_IMAGES[@]}"; do
    dir="${entry%%=*}"
    tag="${entry#*=}"
    if [[ -z "${dir}" || -z "${tag}" || "${dir}" == "${tag}" ]]; then
      _cfg_err "AGENT_IMAGES entry '${entry}' must be in '<dir>=<tag>' form"
    fi
    ctx="${CONFIG_REPO_ROOT}/docker/${dir}"
    [[ -f "${ctx}/Dockerfile" ]] || _cfg_err "AGENT_IMAGES '${entry}': no Dockerfile at ${ctx}"
    echo "==> Building ${tag} from docker/${dir}..."
    colima ssh --profile "${COLIMA_PROFILE:-k3s-bootstrap}" -- \
      docker build -t "${tag}" "${ctx}"
  done
}
