#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLIMA_PROFILE="${COLIMA_PROFILE:-k3s-bootstrap}"

echo "==> Stopping and deleting colima profile '${COLIMA_PROFILE}'..."
colima delete --profile "${COLIMA_PROFILE}" --force

# colima delete removes the VM instance but NOT colima's persistent data disk.
# k3s state (/var/lib/rancher) and the docker image cache live on that disk, so
# leaving it behind makes the next setup.sh resurrect the old cluster and crash
# loop (cert/identity mismatch against the fresh VM). Remove it for a true wipe.
DATA_DISK="${HOME}/.colima/_lima/_disks/colima-${COLIMA_PROFILE}"
if [[ -d "${DATA_DISK}" ]]; then
  echo "==> Removing persistent data disk '${DATA_DISK}'..."
  rm -rf "${DATA_DISK}"
fi

# Drop the VM-creation-time fingerprint so the next setup.sh starts clean and
# re-records it (otherwise stale settings would trip the drift guard).
rm -f "${SCRIPT_DIR}/.vm-fingerprint"

echo "==> Done. Cluster destroyed."
