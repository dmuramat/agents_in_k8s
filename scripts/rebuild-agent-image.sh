#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLIMA_PROFILE="${COLIMA_PROFILE:-k3s-bootstrap}"

# Rebuilds the agent container images declared in the config repo's cluster.conf
# (AGENT_IMAGES), from the Dockerfiles in <config-repo>/docker/.
# shellcheck source=lib-config.sh
source "${SCRIPT_DIR}/lib-config.sh"
load_local_config
load_cluster_conf

build_agent_images

echo ""
echo "Done. Restart agent pods to pick up the new image(s):"
echo "  kubectl delete pod agent-cli -n <agent-namespace>"
