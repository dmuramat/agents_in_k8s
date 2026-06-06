#!/usr/bin/env bash
set -euo pipefail

# check-readiness-sync.sh — 30-second probe of vCluster pod-condition syncing.
#
# Why this exists: vCluster runs your pods on the host kubelet and syncs their
# status back into the virtual cluster. We have seen (in an emulated/sandbox
# vCluster) the syncer copy containerStatuses[].ready=true while leaving the
# aggregated Ready/ContainersReady *conditions* stuck at False — a state a real
# kubelet cannot produce. Because EndpointSlice readiness keys off the pod Ready
# *condition*, that wedges every Service/Gateway (endpoints never go ready).
#
# A healthy vCluster on a real kubelet does NOT do this. Run this against the
# kubecontext of the vCluster you care about (your real colima cluster) to
# confirm. Exit 0 = condition syncs correctly; exit 1 = the contradiction is
# present (see the publishNotReadyAddresses note in the expose-service skill).
#
# Usage:
#   ./scripts/check-readiness-sync.sh            # uses current kube-context
#   KUBECONFIG=... ./scripts/check-readiness-sync.sh

NS="readiness-sync-check"
IMAGE="${IMAGE:-busybox:1.36}"
TIMEOUT="${TIMEOUT:-30}"   # seconds to wait for the Ready condition to flip

cleanup() { kubectl delete ns "$NS" --now >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "context: $(kubectl config current-context 2>/dev/null || echo '?')"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# A trivially-ready container: sleeps, with an exec readinessProbe that always
# passes. So containerStatuses[].ready goes true almost immediately; the only
# question is whether the pod-level Ready *condition* follows.
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: probe, namespace: $NS }
spec:
  containers:
    - name: c
      image: $IMAGE
      command: ["sleep", "600"]
      readinessProbe:
        exec: { command: ["true"] }
        initialDelaySeconds: 1
        periodSeconds: 2
        failureThreshold: 3
      resources:
        requests: { cpu: 20m, memory: 32Mi }
        limits:   { cpu: 100m, memory: 64Mi }
YAML

cs_ready=""; ready=""
for _ in $(seq 1 "$TIMEOUT"); do
  cs_ready=$(kubectl get pod probe -n "$NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  ready=$(kubectl get pod probe -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$ready" = "True" ] && break
  sleep 1
done

echo "containerStatuses[0].ready = ${cs_ready:-<none>}"
echo "pod Ready condition        = ${ready:-<none>}"

if [ "$ready" = "True" ]; then
  echo "PASS: pod-condition syncing works on this cluster."
  exit 0
fi
if [ "$cs_ready" = "true" ]; then
  echo "FAIL: container is ready but the Ready condition is stuck (${ready:-<none>})."
  echo "      This is the vCluster condition-sync race — endpoints will never go"
  echo "      ready, so Services/Gateways won't route. It is NOT a probe problem."
  echo "      Capture this and report upstream (loft-sh/vcluster); for a one-off"
  echo "      test, publishNotReadyAddresses:true on the Service unblocks routing."
  exit 1
fi
echo "INCONCLUSIVE: container never became ready within ${TIMEOUT}s (image pull? probe?)."
exit 1
