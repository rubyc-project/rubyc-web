#!/usr/bin/env bash
# Build, publish, deploy and verify RubyC on the server. Never prints secret values.
set +x
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KUBECONFIG_PATH=${KUBECONFIG_PATH:-${KUBECONFIG:-$HOME/.kube/aucontabo.yaml}}
CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
REGISTRY=${REGISTRY:-10.77.0.2:5000}
REGISTRY_TLS_VERIFY=${REGISTRY_TLS_VERIFY:-false}
SERVER_NODE=${SERVER_NODE:-aumelc1.gamerconnect.zone}
DOMAIN=${DOMAIN:-rubyc.org}
ACME_EMAIL=${ACME_EMAIL:-noreply@gamerconnect.zone}
DNS_SECRET_SOURCE_NAMESPACE=${DNS_SECRET_SOURCE_NAMESPACE:-gamerconnectzone-production}
PUBLIC_IPV4=${PUBLIC_IPV4:-46.250.247.74}
PUBLIC_IPV6=${PUBLIC_IPV6:-2407:3641:2350:5998::1}
IPV6_VERIFY_SSH_HOST=${IPV6_VERIFY_SSH_HOST:-}
IPV4_VERIFY_SSH_HOST=${IPV4_VERIFY_SSH_HOST:-$IPV6_VERIFY_SSH_HOST}
TAG=${TAG:-$(git -C "$ROOT" rev-parse --short HEAD)-$(date -u +%Y%m%d%H%M%S)}
IMAGE="$REGISTRY/rubyc-web:$TAG"
K=(kubectl --kubeconfig "$KUBECONFIG_PATH")
for tool in "$CONTAINER_ENGINE" kubectl jq skopeo curl python3; do command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }; done
[[ "$CONTAINER_ENGINE" == podman || "$CONTAINER_ENGINE" == docker ]] || { echo 'Use podman or docker.' >&2; exit 1; }
[[ "$REGISTRY_TLS_VERIFY" == true || "$REGISTRY_TLS_VERIFY" == false ]] || exit 1
[[ "$SERVER_NODE" =~ ^[a-zA-Z0-9.-]+$ && "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ && "$TAG" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo 'Invalid node, domain or tag.' >&2; exit 1; }
[[ "$PUBLIC_IPV4" =~ ^[0-9.]+$ && "$PUBLIC_IPV6" =~ ^[a-fA-F0-9:]+$ && "$IPV4_VERIFY_SSH_HOST" =~ ^[a-zA-Z0-9_.@-]*$ && "$IPV6_VERIFY_SSH_HOST" =~ ^[a-zA-Z0-9_.@-]*$ ]] || { echo 'Invalid verification endpoint.' >&2; exit 1; }
[[ "$REGISTRY" =~ ^[a-zA-Z0-9.:-]+$ && "$ACME_EMAIL" =~ ^[a-zA-Z0-9._+@-]+$ ]] || { echo 'Invalid registry or email.' >&2; exit 1; }
# Refuse the development node even if someone overrides SERVER_NODE.
NODE_JSON=$("${K[@]}" get node "$SERVER_NODE" -o json)
jq -e '.metadata.labels["gamerconnect.zone/environment"] != "development" and .metadata.labels["gamerconnect.zone/node-purpose"] != "development" and .metadata.labels["node-role.kubernetes.io/control-plane"] == "true" and any(.status.conditions[]; .type == "Ready" and .status == "True")' <<<"$NODE_JSON" >/dev/null || { echo 'Target must be the Ready server/control-plane node, not development.' >&2; exit 1; }
"${K[@]}" get crd ingressroutes.traefik.io certificates.cert-manager.io >/dev/null
"${K[@]}" -n cert-manager get serviceaccount godaddy-webhook >/dev/null

WORK=$(mktemp -d)
LOCAL_CONTAINER=""
WORKLOAD_CHANGED=false
PREVIOUS=false
rollback() {
    local code=$?
    trap - ERR
    if [[ "$WORKLOAD_CHANGED" == true ]]; then
        if [[ "$PREVIOUS" == true ]]; then
            echo 'Deployment failed; restoring previous Deployment spec.' >&2
            "${K[@]}" -n rubyc patch deployment rubyc-web --type=json --patch-file "$WORK/rollback.json" || true
            "${K[@]}" -n rubyc rollout status deployment/rubyc-web --timeout=180s || true
        else
            echo 'First deployment failed; removing this new workload and route.' >&2
            "${K[@]}" -n rubyc delete ingressroute,service,deployment rubyc-web --ignore-not-found || true
        fi
    fi
    exit "$code"
}
cleanup() {
    [[ -z "$LOCAL_CONTAINER" ]] || "$CONTAINER_ENGINE" rm -f "$LOCAL_CONTAINER" >/dev/null 2>&1 || true
    rm -rf -- "$WORK"
}
trap rollback ERR
trap cleanup EXIT

# Dockerfile pins both base images by digest. Build context excludes local state.
"$CONTAINER_ENGINE" build --platform linux/amd64 -f "$ROOT/deploy/Dockerfile" -t "$IMAGE" "$ROOT"
LOCAL_CONTAINER=$("$CONTAINER_ENGINE" run -d --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,size=32m -p 127.0.0.1::8080 "$IMAGE")
LOCAL_PORT=$("$CONTAINER_ENGINE" port "$LOCAL_CONTAINER" 8080/tcp | sed 's/.*://')
curl --noproxy '*' --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 "http://127.0.0.1:$LOCAL_PORT/healthz" >/dev/null
curl --noproxy '*' --fail --silent --show-error "http://127.0.0.1:$LOCAL_PORT/" -o "$WORK/index.html"
grep -q 'RubyC' "$WORK/index.html"
[[ $(curl --noproxy '*' --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$LOCAL_PORT/missing.wasm") == 404 ]]
"$CONTAINER_ENGINE" rm -f "$LOCAL_CONTAINER" >/dev/null
LOCAL_CONTAINER=""
if [[ "$CONTAINER_ENGINE" == podman ]]; then
    podman push --tls-verify="$REGISTRY_TLS_VERIFY" "$IMAGE"
else
    # Copy through the local Docker daemon; no daemon-wide insecure-registry change.
    skopeo copy --dest-tls-verify="$REGISTRY_TLS_VERIFY" "docker-daemon:$IMAGE" "docker://$IMAGE"
fi
DIGEST=$(skopeo inspect --tls-verify="$REGISTRY_TLS_VERIFY" --format '{{.Digest}}' "docker://$IMAGE")
PINNED_IMAGE="$REGISTRY/rubyc-web@$DIGEST"
[[ "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]

"${K[@]}" get namespace rubyc >/dev/null 2>&1 || "${K[@]}" create namespace rubyc
# Reuse the existing DNS integration. Secret payload stays in a pipe: never logged,
# decoded, written to a file, or stored in kubectl last-applied annotations.
if ! "${K[@]}" -n rubyc get secret godaddy-api-key >/dev/null 2>&1; then
    "${K[@]}" -n "$DNS_SECRET_SOURCE_NAMESPACE" get secret godaddy-api-key -o json |
        jq '{apiVersion:"v1",kind:"Secret",metadata:{name:"godaddy-api-key",namespace:"rubyc"},type:.type,data:.data}' |
        "${K[@]}" create -f -
fi
export PINNED_IMAGE SERVER_NODE DOMAIN ACME_EMAIL
python3 - "$ROOT/deploy" "$WORK" <<'PY'
import os, pathlib, sys
source, out = map(pathlib.Path, sys.argv[1:])
values = {"__IMAGE__":os.environ["PINNED_IMAGE"],"__NODE__":os.environ["SERVER_NODE"],"__DOMAIN__":os.environ["DOMAIN"],"__ACME_EMAIL__":os.environ["ACME_EMAIL"]}
for name in ("tls.yaml", "workload.yaml", "ingress.yaml"):
    text = (source/name).read_text()
    for token, value in values.items(): text = text.replace(token, value)
    (out/name).write_text(text)
PY
"${K[@]}" apply --dry-run=server -f "$WORK/tls.yaml" -f "$WORK/workload.yaml" -f "$WORK/ingress.yaml" >/dev/null
"${K[@]}" apply -f "$WORK/tls.yaml"
"${K[@]}" -n rubyc wait certificate/rubyc-org --for=condition=Ready --timeout=600s
if "${K[@]}" -n rubyc get deployment rubyc-web -o json > "$WORK/previous.json" 2>/dev/null; then
    PREVIOUS=true
    jq '[{op:"replace",path:"/spec",value:.spec}]' "$WORK/previous.json" > "$WORK/rollback.json"
fi
WORKLOAD_CHANGED=true
"${K[@]}" apply -f "$WORK/workload.yaml"
"${K[@]}" -n rubyc rollout status deployment/rubyc-web --timeout=180s
"${K[@]}" -n rubyc get pods -l app.kubernetes.io/name=rubyc-web -o json |
    jq -e --arg node "$SERVER_NODE" --arg digest "$DIGEST" '[.items[] | select(.metadata.deletionTimestamp == null)] | length > 0 and all(.[]; .spec.nodeName == $node and any(.status.conditions[]; .type == "Ready" and .status == "True") and all(.status.containerStatuses[]; .imageID | endswith($digest)))' >/dev/null
"${K[@]}" apply -f "$WORK/ingress.yaml"
# Validate listeners with SNI and normal certificate verification. Optional SSH
# handles clients with no IPv6 egress; it does not claim an external-path test.
if [[ -n "$IPV4_VERIFY_SSH_HOST" ]]; then
    echo "Verifying IPv4 via SSH host $IPV4_VERIFY_SSH_HOST."
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$IPV4_VERIFY_SSH_HOST" "curl --noproxy '*' -4 --fail --silent --show-error --retry 12 --retry-delay 2 --retry-all-errors --connect-timeout 5 --max-time 15 --resolve '$DOMAIN:443:$PUBLIC_IPV4' 'https://$DOMAIN/'" > "$WORK/public.html"
else
    curl --noproxy '*' -4 --fail --silent --show-error --retry 12 --retry-delay 2 --retry-all-errors --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:443:$PUBLIC_IPV4" "https://$DOMAIN/" -o "$WORK/public.html"
fi
grep -q 'RubyC' "$WORK/public.html"
if [[ -n "$IPV6_VERIFY_SSH_HOST" ]]; then
    echo "Verifying IPv6 via SSH host $IPV6_VERIFY_SSH_HOST (external-path testing is separate)."
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$IPV6_VERIFY_SSH_HOST" "curl --noproxy '*' -6 --fail --silent --show-error --retry 12 --retry-delay 2 --retry-all-errors --connect-timeout 5 --max-time 15 --resolve '$DOMAIN:443:[$PUBLIC_IPV6]' 'https://$DOMAIN/'" > "$WORK/ipv6.html"
else
    curl --noproxy '*' -6 --fail --silent --show-error --retry 12 --retry-delay 2 --retry-all-errors --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:443:[$PUBLIC_IPV6]" "https://$DOMAIN/" -o "$WORK/ipv6.html"
fi
grep -q 'RubyC' "$WORK/ipv6.html"
# A DNS/client-network failure here does not undo an otherwise healthy deployment.
WORKLOAD_CHANGED=false
"${K[@]}" -n rubyc get pods -l app.kubernetes.io/name=rubyc-web -o wide
printf 'Deployed %s\nImage: %s\n' "https://$DOMAIN" "$PINNED_IMAGE"
DNS_FAILED=false
if [[ -n "$IPV4_VERIFY_SSH_HOST" ]]; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$IPV4_VERIFY_SSH_HOST" "curl --noproxy '*' -4 --fail --silent --show-error --connect-timeout 10 --max-time 20 'https://$DOMAIN/'" > "$WORK/dns4.html"; then DNS_FAILED=true; fi
elif ! curl --noproxy '*' -4 --fail --silent --show-error --connect-timeout 10 --max-time 20 "https://$DOMAIN/" -o "$WORK/dns4.html"; then
    DNS_FAILED=true
fi
if [[ "$DNS_FAILED" == true ]] || ! grep -q 'RubyC' "$WORK/dns4.html"; then
    echo 'Deployment is healthy, but IPv4 public DNS/network verification failed.' >&2
    DNS_FAILED=true
fi
if [[ -n "$IPV6_VERIFY_SSH_HOST" ]]; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$IPV6_VERIFY_SSH_HOST" "curl --noproxy '*' -6 --fail --silent --show-error --connect-timeout 10 --max-time 20 'https://$DOMAIN/'" > "$WORK/dns6.html"; then DNS_FAILED=true; fi
elif ! curl --noproxy '*' -6 --fail --silent --show-error --connect-timeout 10 --max-time 20 "https://$DOMAIN/" -o "$WORK/dns6.html"; then
    DNS_FAILED=true
fi
if ! grep -q 'RubyC' "$WORK/dns6.html"; then
    echo 'Deployment is healthy, but IPv6 public DNS/network verification failed.' >&2
    DNS_FAILED=true
fi
[[ "$DNS_FAILED" == false ]]
