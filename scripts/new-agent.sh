#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve CONFIG_REPO_ROOT (agent files live in the config repo, not here).
# shellcheck source=lib-config.sh
source "${SCRIPT_DIR}/lib-config.sh"
load_local_config

usage() {
  cat <<'EOF'
Usage: new-agent.sh <agent-name> [--repo=<host-path>]...

Creates a new agent config file at <config-repo>/agents/<agent-name>.yaml.
ArgoCD will automatically provision the agent environment from this file.

Arguments:
  agent-name             Name for the agent (namespace, hostname, etc.)
  --repo=<host-path>     Mount a local git repo for the agent to work on.
                         Mounted read-write at /repos/<basename>, cloned to
                         /workspace/<basename> with main/master branch protection.
                         Can be specified multiple times.

Example:
  ./scripts/new-agent.sh agent-alpha \
    --repo=/Users/me/projects/myapp \
    --repo=/Users/me/projects/shared-lib

The host paths must be under your home directory (colima mounts ~ by default).
EOF
  exit 1
}

if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  usage
fi

AGENT_NAME="$1"
shift

REPOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo=*)
      REPOS+=("${1#--repo=}")
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

VALUES_FILE="${CONFIG_REPO_ROOT}/agents/${AGENT_NAME}.yaml"

mkdir -p "${CONFIG_REPO_ROOT}/agents"

if [ -f "${VALUES_FILE}" ]; then
  echo "Error: Agent config already exists: ${VALUES_FILE}" >&2
  exit 1
fi

# Build the values file
cat > "${VALUES_FILE}" <<YAML
name: ${AGENT_NAME}
YAML

if [[ ${#REPOS[@]} -gt 0 ]]; then
  echo "" >> "${VALUES_FILE}"
  echo "repos:" >> "${VALUES_FILE}"
  for host_path in "${REPOS[@]}"; do
    echo "  - hostPath: ${host_path}" >> "${VALUES_FILE}"
  done
fi

echo ""
echo "Created agent config: ${VALUES_FILE}"
echo ""
cat "${VALUES_FILE}"
echo ""
if [[ ${#REPOS[@]} -gt 0 ]]; then
  echo "Repo mapping:"
  for host_path in "${REPOS[@]}"; do
    repo_name="$(basename "${host_path}")"
    echo "  ${host_path} -> /repos/${repo_name} (mount) -> /workspace/${repo_name} (clone)"
  done
  echo ""
  echo "NOTE: Host paths must be under your home directory (colima mounts ~ by default)."
fi
echo ""
echo "To activate, commit in the config repo and push:"
echo "  git -C ${CONFIG_REPO_ROOT} add agents/${AGENT_NAME}.yaml && git -C ${CONFIG_REPO_ROOT} commit -m 'add ${AGENT_NAME}'"
echo "ArgoCD will sync automatically (the git-server serves the config repo's main branch)."
echo ""
echo "NOTE: if --repo paths add a NEW host directory and mounts are constricted,"
echo "      the colima VM must be recreated to mount it: ./scripts/teardown.sh && ./scripts/setup.sh"
