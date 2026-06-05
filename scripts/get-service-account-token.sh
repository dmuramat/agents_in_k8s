#!/bin/bash

# --- Default Values ---
TOKEN_LIFETIME_SEC=1200
REFRESH_INTERVAL=900
SECRET_NAME="remote-kubeconfig"

# --- Help Function ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

A CLI tool to rotate short-lived Kubernetes tokens from a source cluster 
and sync them as a kubeconfig Secret to a destination cluster.

Required Flags:
    --src-context      Context name for the source cluster (where the SA lives).
    --dest-context     Context name for the destination cluster (where Secret is stored).
    --sa-name          Name of the Service Account to impersonate.
    --sa-namespace     Namespace of the Service Account.
    --dest-namespace   Namespace to store the Secret.

Optional Flags:
    --secret-name      Name of the Secret to create/update (default: $SECRET_NAME).
    --lifetime         Token lifetime in seconds (default: $TOKEN_LIFETIME_SEC).
    --interval         Refresh interval in seconds (default: $REFRESH_INTERVAL).
    -h, --help         Display this help message.

Example:
    $(basename "$0") --src-context prod-cluster --dest-context mgmt-cluster --sa-name external-scaler
EOF
    exit 0
}

# --- Parse Arguments ---
PARAMS=$(getopt -o h --long src-context:,dest-context:,sa-name:,sa-namespace:,dest-namespace:,secret-name:,lifetime:,interval:,help -n "$0" -- "$@")
if [ $? -ne 0 ]; then usage; fi
eval set -- "$PARAMS"

while true; do
    case "$1" in
        --src-context)    SOURCE_CONTEXT=$2; shift 2 ;;
        --dest-context)   DEST_CONTEXT=$2; shift 2 ;;
        --sa-name)        SA_NAME=$2; shift 2 ;;
        --sa-namespace)   SA_NAMESPACE=$2; shift 2 ;;
        --dest-namespace) DEST_NAMESPACE=$2; shift 2 ;;
        --secret-name)    SECRET_NAME=$2; shift 2 ;;
        --lifetime)       TOKEN_LIFETIME_SEC=$2; shift 2 ;;
        --interval)       REFRESH_INTERVAL=$2; shift 2 ;;
        -h|--help)        usage ;;
        --)               shift; break ;;
        *)                usage ;;
    esac
done

# --- Validation ---
if [[ -z "$SOURCE_CONTEXT" || -z "$DEST_CONTEXT" || -z "$SA_NAME" || -z "$SA_NAMESPACE" || -z "$DEST_NAMESPACE" ]]; then
    echo "Error: --src-context, --dest-context, --sa-namespace, --dest-namespace, and --sa-name are required."
    usage
fi

# --- Core Logic ---
rotate_token() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S')] 🔄 Refreshing token for $SA_NAME..."

    # Extract Cluster Info
    CLUSTER_NAME=$(kubectl config view --context "$SOURCE_CONTEXT" -o jsonpath='{.contexts[?(@.name=="'"$SOURCE_CONTEXT"'")].context.cluster}')
    ENDPOINT=$(kubectl config view --context "$SOURCE_CONTEXT" -o jsonpath='{.clusters[?(@.name=="'"$CLUSTER_NAME"'")].cluster.server}')
    CA_DATA=$(kubectl config view --context "$SOURCE_CONTEXT" --flatten -o jsonpath='{.clusters[?(@.name=="'"$CLUSTER_NAME"'")].cluster.certificate-authority-data}')

    # Generate Token
    TOKEN=$(kubectl --context "$SOURCE_CONTEXT" create token "$SA_NAME" \
        --namespace "$SA_NAMESPACE" \
        --duration="${TOKEN_LIFETIME_SEC}s" 2>/dev/null)

    if [ -z "$TOKEN" ]; then
        echo "❌ Failed to generate token. Check permissions on $SOURCE_CONTEXT."
        return 1
    fi

    # Build Kubeconfig YAML
    KUBECONFIG_YAML=$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA_DATA
    server: $ENDPOINT
  name: target-cluster
contexts:
- context:
    cluster: target-cluster
    user: sa-user
  name: target-context
current-context: target-context
users:
- name: sa-user
  user:
    token: $TOKEN
EOF
)

    # Sync to Destination
    echo "$KUBECONFIG_YAML" | kubectl --context "$DEST_CONTEXT" create secret generic "$SECRET_NAME" \
        --namespace "$DEST_NAMESPACE" \
        --from-file=config=/dev/stdin \
        --dry-run=client -o yaml | kubectl --context "$DEST_CONTEXT" apply -f - > /dev/null

    if [ $? -eq 0 ]; then
        echo "✅ Secret '$SECRET_NAME' updated in cluster '$DEST_CONTEXT'."
    else
        echo "❌ Failed to update secret in destination cluster."
        return 1
    fi
}

# --- Main Loop ---
while true; do
    rotate_token
    sleep "$REFRESH_INTERVAL"
done
