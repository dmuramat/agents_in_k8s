#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve CONFIG_REPO_ROOT (agent files live in the config repo, not here).
# shellcheck source=lib-config.sh
source "${SCRIPT_DIR}/lib-config.sh"
load_local_config

usage() {
  cat <<'EOF'
Usage: remove-agent.sh <agent-name>

Removes an agent environment. Deletes the agent values file (in the config
repo) and cleans up the ArgoCD cluster secret. After committing in the config
repo, ArgoCD will remove all agent resources automatically.

Example:
  ./scripts/remove-agent.sh agent-alpha
EOF
  exit 1
}

if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  usage
fi

AGENT_NAME="$1"
VALUES_FILE="${CONFIG_REPO_ROOT}/agents/${AGENT_NAME}.yaml"

if [ ! -f "${VALUES_FILE}" ]; then
  echo "Warning: Agent config not found: ${VALUES_FILE}" >&2
fi

# Delete the ArgoCD cluster secret (stops the vcluster-traefik ApplicationSet
# from generating an Application targeting the now-dead vCluster)
if kubectl get secret "cluster-${AGENT_NAME}" -n argocd &>/dev/null; then
  echo "Deleting ArgoCD cluster secret: cluster-${AGENT_NAME}"
  kubectl delete secret "cluster-${AGENT_NAME}" -n argocd
else
  echo "No ArgoCD cluster secret found for ${AGENT_NAME} (already cleaned up)"
fi

# Delete the agent values file
if [ -f "${VALUES_FILE}" ]; then
  echo "Deleting agent config: ${VALUES_FILE}"
  rm "${VALUES_FILE}"
else
  echo "No agent config file to delete"
fi

echo ""
echo "Agent ${AGENT_NAME} removed."
echo "Commit in the config repo to finalize:"
echo "  git -C ${CONFIG_REPO_ROOT} add -A && git -C ${CONFIG_REPO_ROOT} commit -m 'remove ${AGENT_NAME}'"
