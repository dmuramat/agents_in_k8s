---
name: expose-service
description: Expose an HTTP service running in this agent's vCluster so it can be reached from the user's browser at https://<name>.<CLUSTER_DOMAIN>. Use when the user asks to "expose", "publish", "reach in the browser", set up a Gateway/HTTPRoute/ingress, or debug why a deployed web app/page is unreachable or blank.
---

# Expose a service in the vCluster to the browser

This cluster routes browser traffic like this:

```
Mac browser  https://<name>.<CLUSTER_DOMAIN>
   -> (Chrome maps *.localhost to 127.0.0.1; other browsers need /etc/hosts)
host Traefik :443  (TLS passthrough, matches SNI *.<CLUSTER_DOMAIN>)
   -> synced Service  traefik-x-kube-system-x-vcluster:443
vCluster Traefik :8443 (websecure) — TERMINATES TLS here
   -> HTTPRoute -> your Service -> your Pod
```

You only control the vCluster (your `kubectl`). Your job is the part from the
vCluster Traefik inward: a TLS cert, a Gateway with an HTTPS listener, an
HTTPRoute, and a workload **that has a readiness probe**.

`$CLUSTER_DOMAIN` is already set in your env (e.g. `agent-setup-debug.localhost`).
Pick a hostname under it, e.g. `app.$CLUSTER_DOMAIN`.

---

## Give every exposed workload a readinessProbe

A Service only routes to endpoints whose Pod is `Ready`. Without a
`readinessProbe`, a Pod counts as Ready the moment its container starts — so
Traefik sends it traffic before the app can actually serve, and you get a blank
page or `no available server` during startup. Add a `readinessProbe` to anything
you expose so it only receives requests once it is genuinely serving.

Verify the endpoint went ready after deploying:

```bash
kubectl get endpointslice -n <ns> -l kubernetes.io/service-name=<svc> \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses} ready={.conditions.ready}{"\n"}{end}'
# want: ready=true
```

---

## Steps

Set variables (edit these):

```bash
NS=app                       # namespace for your app
NAME=app                     # service/route name
HOST="app.$CLUSTER_DOMAIN"   # browser hostname (must end in .$CLUSTER_DOMAIN)
PORT=80                      # Service port
TARGET=8080                  # container port your app listens on
IMAGE=mendhak/http-https-echo:34   # replace with your image
GW_NS=kube-system            # Traefik's namespace — the shared Gateway + cert live here
```

The Gateway and its TLS cert live in Traefik's namespace (`$GW_NS`), shared by
every service you expose; each app keeps only its Deployment, Service, and
HTTPRoute in its own namespace. A Gateway's `certificateRefs` always resolve in
the Gateway's own namespace, so the cert secret must sit there alongside it.

### 1. App namespace + shared wildcard cert (in Traefik's namespace)

The vCluster Traefik must present a cert matching the SNI. One self-signed
wildcard for `*.$CLUSTER_DOMAIN` covers every service. Create it once; re-runs
reuse it (regenerating it would rotate the cert out from under other services).

```bash
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get secret wildcard-tls -n "$GW_NS" >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout /tmp/wildcard-tls.key -out /tmp/wildcard-tls.crt \
    -subj "/CN=*.$CLUSTER_DOMAIN" \
    -addext "subjectAltName=DNS:*.$CLUSTER_DOMAIN,DNS:$CLUSTER_DOMAIN"
  kubectl create secret tls wildcard-tls -n "$GW_NS" \
    --cert=/tmp/wildcard-tls.crt --key=/tmp/wildcard-tls.key
fi
```

### 2. Deployment (WITH readinessProbe) + Service

```bash
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: $NAME, namespace: $NS, labels: { app: $NAME } }
spec:
  replicas: 1
  selector: { matchLabels: { app: $NAME } }
  template:
    metadata: { labels: { app: $NAME } }
    spec:
      containers:
        - name: $NAME
          image: $IMAGE
          ports: [{ containerPort: $TARGET }]
          # Route traffic only once the app is actually serving.
          readinessProbe:
            tcpSocket: { port: $TARGET }
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 3
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata: { name: $NAME, namespace: $NS }
spec:
  selector: { app: $NAME }
  ports: [{ name: http, port: $PORT, targetPort: $TARGET }]
YAML
```

### 3. Shared Gateway (in Traefik's namespace) + HTTPRoute (with your app)

The Gateway lives in `$GW_NS` next to Traefik and is shared by all services —
`kubectl apply` is idempotent, so re-running is safe; it does not need to be
recreated per app. `allowedRoutes.namespaces.from: All` lets HTTPRoutes in any
namespace attach. The HTTPS listener on port **8443** maps to Traefik's
`websecure` entrypoint, where the host delivers passthrough TLS. Traefik watches
Gateways cluster-wide, so it serves this one even though it lives in `$GW_NS`.

```bash
cat <<YAML | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: web-gateway, namespace: $GW_NS }
spec:
  gatewayClassName: traefik
  listeners:
    - name: web
      protocol: HTTP
      port: 8000
      allowedRoutes: { namespaces: { from: All } }
    - name: websecure
      protocol: HTTPS
      port: 8443
      tls:
        mode: Terminate
        certificateRefs: [{ name: wildcard-tls }]
      allowedRoutes: { namespaces: { from: All } }
YAML
```

The HTTPRoute stays in the app namespace, so its `backendRefs` to your Service
resolve locally with no ReferenceGrant. It attaches across namespaces to the
shared Gateway by naming its namespace in `parentRefs`.

```bash
cat <<YAML | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: $NAME, namespace: $NS }
spec:
  parentRefs:
    - { name: web-gateway, namespace: $GW_NS, sectionName: web }
    - { name: web-gateway, namespace: $GW_NS, sectionName: websecure }
  hostnames: ["$HOST"]
  rules:
    - backendRefs: [{ name: $NAME, port: $PORT }]
YAML
```

Confirm the listeners are programmed and your route attached:

```bash
kubectl get gateway web-gateway -n "$GW_NS" \
  -o jsonpath='{range .status.listeners[*]}{.name}={.attachedRoutes} routes{"\n"}{end}'
kubectl get httproute "$NAME" -n "$NS" \
  -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}{"\n"}'
```

### 4. Self-test from inside the cluster (do this BEFORE telling the user to open a browser)

This proves the vCluster wiring is correct and isolates it from host/DNS issues.
It hits the Traefik ClusterIP on :443 — the exact path the host forwards to.

```bash
TRAEFIK_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}')
kubectl run nettest -n "$NS" --image=curlimages/curl:8.11.1 --restart=Never \
  --command -- sleep 300
kubectl wait --for=condition=Ready pod/nettest -n "$NS" --timeout=60s || sleep 10

# HTTPS (TLS terminated by vCluster Traefik) — expect HTTP 200
kubectl exec -n "$NS" nettest -- curl -sk -o /dev/null -w "https -> %{http_code}\n" \
  --resolve "$HOST:443:$TRAEFIK_IP" "https://$HOST/"
# HTTP — expect HTTP 200
kubectl exec -n "$NS" nettest -- curl -s -o /dev/null -w "http  -> %{http_code}\n" \
  --resolve "$HOST:80:$TRAEFIK_IP" "http://$HOST/"

kubectl delete pod nettest -n "$NS" --now
```

If you get `200`, the vCluster side is correct.

### 5. Tell the user how to reach it

```
URL:  https://<HOST>
- Chrome/Edge: *.localhost auto-resolves to 127.0.0.1, just open it.
- Firefox/Safari (or non-.localhost domains): add to /etc/hosts:
      127.0.0.1  <HOST>
- You'll see a self-signed cert warning — click through (expected for dev).
- Requires the host to expose colima's Traefik on :443 (the cluster's default).
```

---

## Troubleshooting (map symptom -> cause)

- **Self-test `https`/`http` returns nothing / curl exit 7, `no available server`**
  Backend endpoint not ready — usually the app isn't serving yet or the
  Deployment has no `readinessProbe`. Confirm with the endpointslice query above
  (want `ready=true`).

- **Can't connect to the Traefik ClusterIP at all (exit 7 on every host)**
  vCluster Traefik has no ready endpoint — check it is running and `Ready`:
  ```bash
  kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
  ```
  Fix Traefik first; routing can't work until its Service has an endpoint. You
  can still validate your own Gateway/HTTPRoute in isolation by curling the
  Traefik **pod IP** directly (`:8000` for HTTP, `:8443` for HTTPS).

- **Browser fails but the in-cluster self-test passes**
  The vCluster is fine; the problem is host-side: colima not exposing :443,
  missing `/etc/hosts` entry, or the host Traefik / TLSRoute. Tell the user to
  check those — don't keep changing vCluster manifests.

- **TLS handshake works but wrong/empty response**
  The HTTPRoute `hostnames` must match the SNI exactly and end in
  `.$CLUSTER_DOMAIN` so the host's passthrough TLSRoute selects it.

- **HTTPRoute not attaching (`attachedRoutes: 0`, Accepted=False)**
  The shared Gateway must allow your namespace (`allowedRoutes.namespaces.from:
  All`) and your `parentRefs` must include the Gateway's namespace
  (`namespace: $GW_NS`). If you instead move the HTTPRoute *into* `$GW_NS`, its
  cross-namespace `backendRef` to a Service in `$NS` then needs a
  `ReferenceGrant` in `$NS` — keeping the route with the app avoids that.

## Cleanup

```bash
kubectl delete namespace "$NS"   # removes the app, Service, and its HTTPRoute
```

The shared Gateway and wildcard cert in `$GW_NS` are intentionally left in place
for other services. Remove them only when nothing else uses them:

```bash
kubectl delete gateway web-gateway -n "$GW_NS"
kubectl delete secret wildcard-tls -n "$GW_NS"
```
