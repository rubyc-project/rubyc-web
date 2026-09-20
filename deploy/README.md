# Container and Kubernetes deployment

## Current target

| Setting | Value |
| --- | --- |
| Namespace | `rubyc` |
| Deployment / Service / IngressRoute | `rubyc-web` |
| Server node | `aumelc1.gamerconnect.zone` |
| Domain | `rubyc.org` |
| Public IPv4 | `46.250.247.74` |
| Public IPv6 | `2407:3641:2350:5998::1` |
| Existing image registry | `10.77.0.2:5000` |
| Existing HTTPS entrypoints | `websecure`, `websecure6` |
| TLS | cert-manager / Let's Encrypt / existing GoDaddy DNS-01 webhook |

The pod is pinned to the server node. The script rejects nodes labeled as development and requires a Ready control-plane node. The existing registry is on the development node, but the website runs on the server and keeps its image cached there. Building/pushing a new version requires that registry to be reachable.

The cluster pod network is IPv4-only. Public IPv4 and IPv6 connections terminate at the existing server Traefik listeners and reach the same internal service; a dual-stack pod network is not required. This deployment uses HTTPS and does not alter shared Traefik listeners or expose public HTTP port 80.

## Deploy

Run from a machine with access to the cluster and image registry:

```sh
./deploy/deploy.sh
```

Dependencies: Bash, Git, Python 3, curl, jq, kubectl, skopeo, and Podman (default) or Docker. The kubeconfig defaults to `KUBECONFIG`, falling back to `~/.kube/aucontabo.yaml`.

Examples:

```sh
KUBECONFIG_PATH="$HOME/.kube/aucontabo.yaml" ./deploy/deploy.sh
CONTAINER_ENGINE=docker ./deploy/deploy.sh
TAG=release-20260920 ./deploy/deploy.sh
```

Each normal run:

1. Checks the server node and required cluster components.
2. Builds the image from digest-pinned .NET SDK and Nginx base images.
3. Runs a temporary non-root, read-only container and checks health, HTML, and missing-asset handling.
4. Pushes an immutable tag and deploys the image by its registry digest.
5. Provisions namespace-scoped DNS-01/TLS resources and waits for a valid certificate.
6. Rolls out the workload, checks Kubernetes readiness, server placement, and the running image digest, then creates the HTTPS route.
7. Reports the deployed image and pod status.

Public IPv4/IPv6 requests, public DNS checks, and SSH verification are not part of deployment. Client connectivity cannot trigger a rollback of a healthy website.

Temporary containers and local rendering files are cleaned up. A failed Kubernetes rollout, placement/image check, or ingress apply restores the previous Deployment spec; a failed first rollout removes the new website workload/service/route. Certificate setup is retained for renewal or troubleshooting.

## DNS and certificate credentials

Set these records at the authoritative DNS provider:

```text
A     @     46.250.247.74
AAAA  @     2407:3641:2350:5998::1
```

The existing GoDaddy credential must cover `rubyc.org`. If `rubyc/godaddy-api-key` is absent, the script transfers the existing secret from `gamerconnectzone-production` through a pipe, without printing or decoding its payload or writing it to disk. Override the source using `DNS_SECRET_SOURCE_NAMESPACE`. Existing destination credentials are left untouched. Never add DNS credentials, kubeconfigs, certificates, or private keys to Git.

The GoDaddy webhook receives `get` access only to the named secret in `rubyc`. The website pod mounts no service-account token and has no secret volumes. ACME notification email defaults to the address already used by the cluster; override `ACME_EMAIL` if needed.

## Container-only workflow

Build from the repository root:

```sh
podman build -f deploy/Dockerfile -t rubyc-web:local .
podman run --rm --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m \
  --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8080:8080 rubyc-web:local
```

Open `http://localhost:8080`. Docker accepts the same commands with `docker` in place of `podman`.

Nginx serves only the published Blazor static files on port 8080. It provides gzip, SPA fallback, a health endpoint, and real 404 responses for missing static assets. No .NET runtime runs in the final image.

## Inspect and roll back

```sh
kubectl --kubeconfig ~/.kube/aucontabo.yaml -n rubyc get pods -o wide
kubectl --kubeconfig ~/.kube/aucontabo.yaml -n rubyc get certificate,issuer,ingressroute
kubectl --kubeconfig ~/.kube/aucontabo.yaml -n rubyc rollout history deployment/rubyc-web
kubectl --kubeconfig ~/.kube/aucontabo.yaml -n rubyc rollout undo deployment/rubyc-web
kubectl --kubeconfig ~/.kube/aucontabo.yaml -n rubyc rollout status deployment/rubyc-web
```

For certificate troubleshooting, inspect Certificate/Order/Challenge status; do not print secret contents. The image registry uses HTTP over the private network, matching the existing cluster setup. `REGISTRY_TLS_VERIFY=false` applies only to this script's registry operations; the script makes no public website requests.

The YAML files are templates rendered by `deploy.sh`; do not apply them directly with unresolved `__PLACEHOLDERS__`.
