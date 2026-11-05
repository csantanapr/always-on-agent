#!/usr/bin/env bash
# Copyright 2026 The Agent Substrate Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# Deploy the always-on-agent demo on EKS with Agent Substrate v1.0.0-rc.3.
#
# One idempotent command. It builds the three images with plain `docker build`,
# pushes them to private ECR, pins them by digest, then applies the namespace,
# the gateway-token Secret, the WorkerPool, the ActorTemplate, the gateway, the
# dashboard, the demo actor and its egress policy, and prints how to reach it
# all with port-forwards. Nothing it creates is reachable from outside the
# cluster: both Services are ClusterIP and there is no Ingress.
#
# The model is Claude on Amazon Bedrock behind the in-cluster LLM gateway at
# http://llm-gateway.llm-gateway.svc.cluster.local, which this script does not
# deploy. Actors hold no LLM credential: their egress policy has Substrate's
# egress gateway put an actor JWT (audience llm-gateway) in the Authorization
# header of every request to it.
#
# Requirements: kubectl pointed at the EKS cluster (or KUBE_CONTEXT), aws, docker,
# jq, openssl, sha256sum (or shasum), and a static kubectl-ate built from the v1.0.0-rc.3 source at
# build/bin/kubectl-ate (or KUBECTL_ATE_BIN). See demo/README.md, "Running on EKS".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EKS_DIR="$REPO_DIR/manifests/eks"

# --- Config (override via env) ---
PROFILE="${PROFILE:-}"                             # AWS CLI profile; empty = default chain
REGION="${REGION:-us-west-2}"                      # ECR region
KUBE_CONTEXT="${KUBE_CONTEXT:-}"                   # kubeconfig context; empty = current
IMAGE_TAG="${IMAGE_TAG:-}"                         # empty = eks-<commit>-<kubectl-ate hash>
BUILD_IMAGES="${BUILD_IMAGES:-auto}"               # auto | true | false
ECR_PREFIX="${ECR_PREFIX:-substrate-day}"          # ECR repository namespace
KUBECTL_ATE_BIN="${KUBECTL_ATE_BIN:-$REPO_DIR/build/bin/kubectl-ate}" # static rc.3 kubectl-ate
DEPLOY_DASHBOARD="${DEPLOY_DASHBOARD:-true}"
WHATSAPP_PEER="${WHATSAPP_PEER:-}"                 # optional E.164 number; unset = no WhatsApp
WORKER_REPLICAS="${WORKER_REPLICAS:-5}"
STORAGE_CLASS="${STORAGE_CLASS:-}"                 # gateway PVC class; empty = cluster default
FORCE_TEMPLATE="${FORCE_TEMPLATE:-false}"          # recreate the ActorTemplate even if unchanged
GOLDEN_TIMEOUT="${GOLDEN_TIMEOUT:-600}"            # seconds to wait for the golden snapshot

SUBSTRATE_VERSION="${SUBSTRATE_VERSION:-v1.0.0-rc.3}"  # the release the cluster runs
# The released ateworker-gvisor for that release, pinned by digest. Empty: the
# image in manifests/eks/workerpool.yaml.
WORKER_IMAGE="${WORKER_IMAGE:-}"
NAMESPACE="openclaw"
ATESPACE="openclaw-demo"
ACTOR_NAME="oc-agent"
TEMPLATE="openclaw-agent"
GATEWAY_PRINCIPAL="user:system:serviceaccount:${NAMESPACE}:openclaw-gateway"
GATEWAY_SPIFFE_ID="spiffe://cluster.local/ns/${NAMESPACE}/sa/openclaw-gateway"
DASHBOARD_SPIFFE_ID="spiffe://cluster.local/ns/${NAMESPACE}/sa/openclaw-dashboard"
LLM_GATEWAY_NS="llm-gateway"
LLM_GATEWAY_SVC="llm-gateway"

echo "=== OpenClaw on Agent Substrate ${SUBSTRATE_VERSION}: EKS demo ==="
echo ""

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
need() { command -v "$1" &>/dev/null || die "$1 not found. Install it first."; }

KCTX=()
if [ -n "$KUBE_CONTEXT" ]; then KCTX=(--context "$KUBE_CONTEXT"); fi
k() { kubectl ${KCTX[@]+"${KCTX[@]}"} "$@"; }
# kubectl-ate acts as the shared ate-client identity here (it mints that token),
# which the install makes a bootstrap owner. It prints a warning saying so on
# every call; that is expected.
ate() { "$ATE_BIN" ${KCTX[@]+"${KCTX[@]}"} "$@"; }
AWS_ARGS=(--region "$REGION")
[ -z "$PROFILE" ] || AWS_ARGS+=(--profile "$PROFILE")
awsc() { aws "${AWS_ARGS[@]}" "$@"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -f "$TMP_DIR"/*; rmdir "$TMP_DIR"' EXIT

# --- [0/9] Prerequisites ---
echo "[0/9] Checking prerequisites..."
need kubectl
need jq
need openssl
need python3
need git
command -v sha256sum >/dev/null || need shasum
[ -x "$KUBECTL_ATE_BIN" ] || die "No kubectl-ate at $KUBECTL_ATE_BIN. Build it static from the ${SUBSTRATE_VERSION} source:
    (cd /path/to/substrate && CGO_ENABLED=0 go build -o $REPO_DIR/build/bin/kubectl-ate ./cmd/kubectl-ate)"
ATE_BIN="$KUBECTL_ATE_BIN"
ate_version="$("$ATE_BIN" --version 2>&1 || true)"
grep -Fq -- "$SUBSTRATE_VERSION" <<<"$ate_version" \
  || die "kubectl-ate at $ATE_BIN is not ${SUBSTRATE_VERSION}: $ate_version"
echo "    kubectl-ate: $ate_version"
echo "    kube context: ${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo unknown)}"

k get namespace ate-system &>/dev/null \
  || die "Agent Substrate is not installed (no ate-system namespace in this context)."
k -n ate-system get deployment ate-api-server &>/dev/null \
  || die "ate-api-server not found in ate-system; Substrate may be partially installed."
router_args="$(k -n ate-system get deployment atenet-router -o json 2>/dev/null \
  | jq -r '[.spec.template.spec.containers[] | (.args // [])[], (.command // [])[]] | join(" ")' || true)"
[ -n "$router_args" ] || die "atenet-router not found in ate-system."
grep -q -- "$GATEWAY_SPIFFE_ID" <<<"$router_args" \
  || warn "atenet-router's --ingress-allowed-spiffe-ids does not list $GATEWAY_SPIFFE_ID; the gateway's turns to actors will be refused until it does."
if [ "$DEPLOY_DASHBOARD" = "true" ] && ! grep -q -- "$DASHBOARD_SPIFFE_ID" <<<"$router_args"; then
  warn "the router does not allow $DASHBOARD_SPIFFE_ID either; the dashboard's Burst and Churn buttons need it, its read-only panels do not."
fi
k -n "$LLM_GATEWAY_NS" get service "$LLM_GATEWAY_SVC" &>/dev/null \
  || warn "service $LLM_GATEWAY_NS/$LLM_GATEWAY_SVC not found; actors will have no model until the LLM gateway is deployed."
[ -n "$(k get nodes -l ate.dev/pool=gvisor -o name 2>/dev/null)" ] \
  || warn "no nodes labeled ate.dev/pool=gvisor; the worker pods will stay Pending."
if [ -z "$STORAGE_CLASS" ] && ! k get storageclass -o json 2>/dev/null \
    | jq -e '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")' >/dev/null; then
  warn "no default StorageClass; set STORAGE_CLASS or the gateway PVC stays Pending."
fi
[[ "$WORKER_REPLICAS" =~ ^[0-9]+$ ]] || die "WORKER_REPLICAS must be a number, got $WORKER_REPLICAS"

# Reuse the token from a previous run: the gateway pod reads it at start and the
# template bakes it into the golden, so rotating it here would break both.
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  OPENCLAW_GATEWAY_TOKEN=$(k -n "$NAMESPACE" get secret openclaw-secrets \
    -o jsonpath='{.data.gateway-token}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 32)}"
# It is written into a quoted YAML string in the ActorTemplate, so keep it plain.
[[ "$GATEWAY_TOKEN" =~ ^[A-Za-z0-9._~-]{16,}$ ]] \
  || die "OPENCLAW_GATEWAY_TOKEN must be at least 16 characters of [A-Za-z0-9._~-]"

# --- [1/9] Images ---
need aws
ACCOUNT_ID="$(awsc sts get-caller-identity --query Account --output text)" \
  || die "aws sts get-caller-identity failed${PROFILE:+ for profile $PROFILE}."
# The images are tagged by the commit they are built from and the kubectl-ate
# they carry, so a changed checkout or release builds new ones. Uncommitted
# changes always rebuild.
if [ -z "$IMAGE_TAG" ]; then
  IMAGE_TAG="eks-$(git -C "$REPO_DIR" rev-parse --short=12 HEAD)-$(sha256 "$KUBECTL_ATE_BIN" | cut -c1-8)"
  if [ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ]; then
    IMAGE_TAG+="-dirty"; BUILD_IMAGES=true
  fi
fi
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
GATEWAY_IMAGE="${REGISTRY}/${ECR_PREFIX}/openclaw-gateway"
ACTOR_IMAGE="${REGISTRY}/${ECR_PREFIX}/openclaw-actor"
DASHBOARD_IMAGE="${REGISTRY}/${ECR_PREFIX}/openclaw-dashboard"
REPOS=(openclaw-gateway openclaw-actor)
[ "$DEPLOY_DASHBOARD" = "true" ] && REPOS+=(openclaw-dashboard)

image_tag_exists() {
  awsc ecr describe-images --repository-name "${ECR_PREFIX}/$1" \
    --image-ids "imageTag=${IMAGE_TAG}" &>/dev/null
}
build_needed=false
if [ "$BUILD_IMAGES" = "true" ]; then
  build_needed=true
elif [ "$BUILD_IMAGES" = "auto" ]; then
  for r in "${REPOS[@]}"; do image_tag_exists "$r" || build_needed=true; done
fi

if [ "$build_needed" = "true" ]; then
  need docker
  echo "[1/9] Building and pushing images to ${REGISTRY}/${ECR_PREFIX} (tag ${IMAGE_TAG})..."
  for r in "${REPOS[@]}"; do
    if ! awsc ecr describe-repositories --repository-names "${ECR_PREFIX}/$r" &>/dev/null; then
      echo "    creating ECR repository ${ECR_PREFIX}/$r"
      awsc ecr create-repository --repository-name "${ECR_PREFIX}/$r" \
        --image-scanning-configuration scanOnPush=true \
        --tags Key=auto-delete,Value=no Key=project,Value=always-on-agent >/dev/null
    fi
  done
  awsc ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

  # The build host cannot reach the Go module proxy, so both images copy this
  # prebuilt kubectl-ate instead of compiling it (KUBECTL_ATE_PREBUILT=true).
  # Each Dockerfile looks for it at build/bin/kubectl-ate in its build context.
  mkdir -p "$REPO_DIR/build/bin" "$REPO_DIR/demo/dashboard/build/bin"
  [ "$KUBECTL_ATE_BIN" -ef "$REPO_DIR/build/bin/kubectl-ate" ] \
    || install -m 0755 "$KUBECTL_ATE_BIN" "$REPO_DIR/build/bin/kubectl-ate"
  install -m 0755 "$KUBECTL_ATE_BIN" "$REPO_DIR/demo/dashboard/build/bin/kubectl-ate"

  docker build --platform linux/amd64 -f "$REPO_DIR/build/gateway.Dockerfile" \
    --build-arg KUBECTL_ATE_PREBUILT=true \
    -t "${GATEWAY_IMAGE}:${IMAGE_TAG}" "$REPO_DIR"
  docker build --platform linux/amd64 -f "$REPO_DIR/build/actor.Dockerfile" \
    --build-arg ACTOR_CONFIG=build/actor/openclaw.eks.json \
    -t "${ACTOR_IMAGE}:${IMAGE_TAG}" "$REPO_DIR"
  docker push "${GATEWAY_IMAGE}:${IMAGE_TAG}"
  docker push "${ACTOR_IMAGE}:${IMAGE_TAG}"
  if [ "$DEPLOY_DASHBOARD" = "true" ]; then
    docker build --platform linux/amd64 -f "$REPO_DIR/demo/dashboard/Dockerfile" \
      --build-arg KUBECTL_ATE_PREBUILT=true \
      -t "${DASHBOARD_IMAGE}:${IMAGE_TAG}" "$REPO_DIR/demo/dashboard"
    docker push "${DASHBOARD_IMAGE}:${IMAGE_TAG}"
  fi
else
  echo "[1/9] Skipping build (all images present in ECR; set BUILD_IMAGES=true to force)."
fi

# --- [2/9] Resolve digests (snapshots require @sha256-pinned images) ---
echo "[2/9] Resolving image digests..."
digest_of() {
  local d
  d="$(awsc ecr describe-images --repository-name "${ECR_PREFIX}/$1" \
    --image-ids "imageTag=${IMAGE_TAG}" --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || true)"
  [[ "$d" == sha256:* ]] || die "Cannot resolve ${ECR_PREFIX}/$1:${IMAGE_TAG}; build it first (BUILD_IMAGES=true)."
  echo "$d"
}
GATEWAY_DIGEST="$(digest_of openclaw-gateway)"
ACTOR_DIGEST="$(digest_of openclaw-actor)"
echo "    gateway @ ${GATEWAY_DIGEST}"
echo "    actor   @ ${ACTOR_DIGEST}"
DASHBOARD_DIGEST=""
if [ "$DEPLOY_DASHBOARD" = "true" ]; then
  DASHBOARD_DIGEST="$(digest_of openclaw-dashboard)"
  echo "    dash    @ ${DASHBOARD_DIGEST}"
fi
ACTOR_REF="${ACTOR_IMAGE}@${ACTOR_DIGEST}"

# Values that differ with WHATSAPP_PEER. The ACP binding is keyed by one
# concrete E.164 number (see ../deploy-demo.sh for why there is no wildcard).
EGRESS_POLICY_JSON="$(jq -c . "$EKS_DIR/egress-policy.json")"
if [ -n "$WHATSAPP_PEER" ]; then
  INSTALL_WHATSAPP=true
  PLUGINS_ALLOW_JSON='["substrate","whatsapp"]'
  BINDINGS_JSON="$(jq -cn --arg peer "$WHATSAPP_PEER" '[{type:"acp",agentId:"main",
    match:{channel:"whatsapp",accountId:"default",peer:{kind:"direct",id:$peer}},
    acp:{backend:"substrate"}}]')"
  CHANNELS_JSON='{"whatsapp":{"enabled":true,"dmPolicy":"open","allowFrom":["*"]}}'
else
  INSTALL_WHATSAPP=false
  PLUGINS_ALLOW_JSON='["substrate"]'
  BINDINGS_JSON='[]'
  CHANNELS_JSON='{}'
fi

# render: substitute images, digests and values into a manifest on stdout.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
render() {
  local storage_expr=(-e "s|REPLACE_WITH_STORAGE_CLASS|$(sed_escape "$STORAGE_CLASS")|g")
  [ -n "$STORAGE_CLASS" ] || storage_expr=(-e '/storageClassName: REPLACE_WITH_STORAGE_CLASS/d')
  local worker_expr=()
  [ -z "$WORKER_IMAGE" ] || worker_expr=(-e "s|^\(  workerImage: \).*|\1$(sed_escape "$WORKER_IMAGE")|")
  sed -e "s|REPLACE_WITH_GATEWAY_IMAGE|${GATEWAY_IMAGE}|g" \
      -e "s|REPLACE_WITH_GATEWAY_DIGEST|${GATEWAY_DIGEST}|g" \
      -e "s|REPLACE_WITH_ACTOR_IMAGE|${ACTOR_IMAGE}|g" \
      -e "s|REPLACE_WITH_ACTOR_DIGEST|${ACTOR_DIGEST}|g" \
      -e "s|REPLACE_WITH_DASHBOARD_IMAGE|${DASHBOARD_IMAGE}|g" \
      -e "s|REPLACE_WITH_DASHBOARD_DIGEST|${DASHBOARD_DIGEST}|g" \
      -e "s|REPLACE_WITH_WORKER_REPLICAS|${WORKER_REPLICAS}|g" \
      -e "s|REPLACE_WITH_INSTALL_WHATSAPP|${INSTALL_WHATSAPP}|g" \
      -e "s|REPLACE_WITH_PLUGINS_ALLOW_JSON|$(sed_escape "$PLUGINS_ALLOW_JSON")|g" \
      -e "s|REPLACE_WITH_BINDINGS_JSON|$(sed_escape "$BINDINGS_JSON")|g" \
      -e "s|REPLACE_WITH_CHANNELS_JSON|$(sed_escape "$CHANNELS_JSON")|g" \
      -e "s|REPLACE_WITH_EGRESS_POLICY_JSON|$(sed_escape "$EGRESS_POLICY_JSON")|g" \
      -e "s|REPLACE_WITH_CONFIG_SHA256|${CONFIG_SHA256:-}|g" \
      "${storage_expr[@]}" ${worker_expr[@]+"${worker_expr[@]}"} "$1" \
    | GATEWAY_TOKEN="$GATEWAY_TOKEN" python3 -c '
import os, sys
sys.stdout.write(sys.stdin.read().replace("REPLACE_WITH_GATEWAY_TOKEN", os.environ["GATEWAY_TOKEN"]))'
}
# The token reaches python above through its environment and kubectl below
# on stdin, never as a command-line argument.

# --- [3/9] Namespace + secret ---
echo "[3/9] Namespace + secret..."
k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f -
# ate-api-server's NetworkPolicy admits clients only from labeled namespaces.
k label namespace "$NAMESPACE" ate.dev/api-access=true --overwrite >/dev/null
# The gateway token only. There is no LLM key anywhere in this deployment.
k -n "$NAMESPACE" create secret generic openclaw-secrets \
  --from-file=gateway-token=/dev/stdin --dry-run=client -o yaml < <(printf '%s' "$GATEWAY_TOKEN") | k apply -f -

# --- [4/9] WorkerPool ---
echo "[4/9] Applying the WorkerPool (${WORKER_REPLICAS} gVisor workers)..."
render "$EKS_DIR/workerpool.yaml" | k apply -f -
deadline=$((SECONDS + 300))
while ((SECONDS < deadline)); do
  ready="$(k -n "$NAMESPACE" get workerpool openclaw -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [ "${ready:-0}" -ge 1 ] && break
  sleep 5
done
echo "    workers ready: ${ready:-0}/${WORKER_REPLICAS}"

# --- [5/9] Atespace, access policy, ActorTemplate ---
echo "[5/9] Atespace, access policy and ActorTemplate..."
ate get atespace "$ATESPACE" &>/dev/null || ate create atespace "$ATESPACE" >/dev/null
echo "    atespace $ATESPACE ready"

# The gateway authenticates to ateapi as its own ServiceAccount, so it needs a
# role in the atespace: editor creates, suspends and deletes actors and their
# egress policies. Nothing outside openclaw-demo.
policy="$(ate get access-policy -a "$ATESPACE" -o json 2>/dev/null || true)"
if [ -z "$policy" ]; then
  jq -n --arg m "$GATEWAY_PRINCIPAL" '{metadata:{name:"default"},bindings:[{role:"editor",members:[$m]}]}' \
    | ate create access-policy -a "$ATESPACE" -f - >/dev/null
  echo "    access policy created: $GATEWAY_PRINCIPAL is editor"
elif jq -e --arg m "$GATEWAY_PRINCIPAL" \
    '[.bindings[]? | select(.role == "editor" or .role == "owner") | .members[]?] | index($m)' <<<"$policy" >/dev/null; then
  echo "    access policy already grants $GATEWAY_PRINCIPAL"
else
  jq --arg m "$GATEWAY_PRINCIPAL" 'if any(.bindings[]?; .role == "editor")
      then .bindings |= map(if .role == "editor" then .members += [$m] else . end)
      else .bindings = ((.bindings // []) + [{role:"editor",members:[$m]}]) end' <<<"$policy" \
    | ate update access-policy -a "$ATESPACE" -f - >/dev/null
  echo "    access policy updated: $GATEWAY_PRINCIPAL is editor"
fi

# Templates are immutable, so a changed image or token means delete and
# recreate. An unchanged one is left alone, which keeps a re-run from throwing
# away the golden and every actor built on it.
recreate=true
existing="$(ate get actor-template "$TEMPLATE" -a "$ATESPACE" -o json 2>/dev/null || true)"
if [ -n "$existing" ] && [ "$FORCE_TEMPLATE" != "true" ]; then
  cur_image="$(jq -r '.containers[0].image // empty' <<<"$existing")"
  cur_token="$(jq -r '.containers[0].env[]? | select(.name == "OPENCLAW_GATEWAY_TOKEN") | .value' <<<"$existing")"
  cur_err="$(jq -r '.status.goldenSnapshotStatus.errorMessage // empty' <<<"$existing")"
  if [ "$cur_image" = "$ACTOR_REF" ] && { [ -z "$cur_token" ] || [ "$cur_token" = "$GATEWAY_TOKEN" ]; } && [ -z "$cur_err" ]; then
    recreate=false
    echo "    actor template unchanged, keeping it and its golden"
  fi
fi
if [ "$recreate" = "true" ]; then
  if [ -n "$existing" ]; then
    # Actors built on the old template point at a golden that is about to go.
    # Only the demo's own actors live in this atespace: the oc-agent fleet the
    # dashboard creates, and one conv-<hash> actor per conversation.
    for a in $(ate get actors -a "$ATESPACE" -o json 2>/dev/null \
        | jq -r '.actors[]?.metadata.name | select(test("^(oc-agent(-[0-9]+)?|conv-[0-9a-f]{12})$"))'); do
      echo "    deleting actor $a (its template is being replaced)"
      ate suspend actor "$a" -a "$ATESPACE" &>/dev/null || true
      ate delete actor "$a" -a "$ATESPACE" >/dev/null || warn "could not delete actor $a"
    done
    echo "    replacing actor template $TEMPLATE"
    ate delete actor-template "$TEMPLATE" -a "$ATESPACE" >/dev/null
  fi
  # The rendered template carries the gateway token, so it goes through a pipe
  # and never lands in the working tree.
  render "$EKS_DIR/actortemplate.yaml" | ate create actor-template -f - >/dev/null
  echo "    actor template $TEMPLATE created"
fi

# --- [6/9] Gateway ---
echo "[6/9] Deploying the gateway..."
render "$EKS_DIR/gateway-config.yaml" >"$TMP_DIR/gateway-config.yaml"
jq -e . >/dev/null 2>&1 < <(sed -n '/openclaw.json: |/,$p' "$TMP_DIR/gateway-config.yaml" | tail -n +2) \
  || die "rendered gateway openclaw.json is not valid JSON"
CONFIG_SHA256="$(sha256 "$TMP_DIR/gateway-config.yaml")"
k apply -f "$TMP_DIR/gateway-config.yaml"
render "$EKS_DIR/gateway.yaml" | k apply -f -
k -n "$NAMESPACE" rollout status deployment/openclaw-gateway --timeout=300s

# --- [7/9] Dashboard (optional, read-only) ---
if [ "$DEPLOY_DASHBOARD" = "true" ]; then
  echo "[7/9] Deploying the lifecycle dashboard..."
  render "$EKS_DIR/dashboard.yaml" | k apply -f -
  k -n "$NAMESPACE" rollout status deployment/openclaw-dashboard --timeout=180s \
    || echo "    dashboard did not become ready; the demo itself is unaffected."
else
  echo "[7/9] Skipping the dashboard (DEPLOY_DASHBOARD=false)."
fi

# --- [8/9] Golden snapshot, demo actor, egress policy ---
echo "[8/9] Waiting for the golden snapshot, then creating $ACTOR_NAME..."
golden_ready() {
  local deadline=$((SECONDS + GOLDEN_TIMEOUT)) json tag err
  while ((SECONDS < deadline)); do
    if json=$(ate get actor-template "$TEMPLATE" -a "$ATESPACE" -o json 2>/dev/null); then
      tag=$(jq -r '.status.goldenSnapshotStatus.goldenTag.name // empty' <<<"$json")
      [ -n "$tag" ] && { echo "    golden snapshot ready: tag $tag"; return 0; }
      err=$(jq -r '.status.goldenSnapshotStatus.errorMessage // empty' <<<"$json")
      [ -n "$err" ] && { echo "    golden snapshot FAILED: $err" >&2; return 1; }
    fi
    sleep 5
  done
  echo "    timed out after ${GOLDEN_TIMEOUT}s waiting for the golden snapshot" >&2
  return 1
}
golden_ready || echo "    (continuing; the actor resumes once the golden is ready)"

out="$(ate create actor "$ACTOR_NAME" -a "$ATESPACE" --template "$TEMPLATE" 2>&1)" \
  || grep -qi "already exists" <<<"$out" \
  || die "creating actor $ACTOR_NAME failed: $out"
echo "    actor $ACTOR_NAME ready"

# The same policy the gateway plugin gives every conversation actor. Without one
# the actor has no outbound network at all, including DNS.
ensure_egress_policy() {
  local actor="$1" current
  current="$(ate get egress-policy "$actor" -a "$ATESPACE" -o json 2>/dev/null || true)"
  if [ -z "$current" ]; then
    ate create egress-policy "$actor" -a "$ATESPACE" -f "$EKS_DIR/egress-policy.json" >/dev/null
    echo "    egress policy created for $actor"
  elif [ "$(jq -S -c .rules <<<"$current")" = "$(jq -S -c .rules "$EKS_DIR/egress-policy.json")" ]; then
    echo "    egress policy for $actor is current"
  else
    # update needs the stored uid and version, which `get` printed.
    jq --slurpfile want "$EKS_DIR/egress-policy.json" '.rules = $want[0].rules' <<<"$current" \
      | ate update egress-policy "$actor" -a "$ATESPACE" -f - >/dev/null
    echo "    egress policy updated for $actor"
  fi
}
ensure_egress_policy "$ACTOR_NAME"

# --- [8b] Optional cron status pings (run on the always-on gateway agent) ---
if [ -n "$WHATSAPP_PEER" ]; then
  echo "    Creating cron status pings to $WHATSAPP_PEER ..."
  GW_POD=$(k -n "$NAMESPACE" get pod -l app=openclaw-gateway -o jsonpath='{.items[0].metadata.name}')
  k -n "$NAMESPACE" exec "$GW_POD" -c gateway -- node /app/openclaw.mjs cron add \
    --name status-30m --every 30m --agent main \
    --model llmgw/claude --light-context \
    --channel whatsapp --to "$WHATSAPP_PEER" \
    --message "Reply with a one-line system status." --announce --expect-final 2>/dev/null \
    || echo "    status-30m may already exist, continuing..."
fi

# --- [9/9] Instructions ---
CTX_FLAG=""
[ -n "$KUBE_CONTEXT" ] && CTX_FLAG=" --context $KUBE_CONTEXT"
echo ""
echo "[9/9] Done. Everything is ClusterIP; reach it with port-forwards."
echo ""
echo "  Gateway Control UI:"
echo "    kubectl$CTX_FLAG -n $NAMESPACE port-forward svc/openclaw-gateway 18789:18789"
echo "    open http://localhost:18789  (gateway token: kubectl -n $NAMESPACE get secret openclaw-secrets -o jsonpath='{.data.gateway-token}' | base64 -d)"
if [ "$DEPLOY_DASHBOARD" = "true" ]; then
  echo "  Dashboard:"
  echo "    kubectl$CTX_FLAG -n $NAMESPACE port-forward svc/openclaw-dashboard 8090:8090"
  echo "    open http://localhost:8090"
fi
echo "  The demo actor, straight through atenet-router:"
echo "    kubectl ate$CTX_FLAG proxy actor $ACTOR_NAME -a $ATESPACE 8000:80"
echo "    curl -s http://127.0.0.1:8000/v1/chat/completions -H \"Authorization: Bearer \$TOKEN\" \\"
echo "      -H 'Content-Type: application/json' -d '{\"model\":\"openclaw/default\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello.\"}]}'"
echo "  End-to-end checks (actor, gateway, gateway-to-actor path): demo/eks/verify-demo.sh"
if [ -n "$WHATSAPP_PEER" ]; then
  echo "  WhatsApp: kubectl$CTX_FLAG -n $NAMESPACE exec -it deploy/openclaw-gateway -- node /app/openclaw.mjs channels login --channel whatsapp"
else
  echo "  WhatsApp is not configured (WHATSAPP_PEER unset). Re-run with WHATSAPP_PEER=+1... to bind it."
fi
echo "  Watch the lifecycle:"
echo "    watch kubectl ate$CTX_FLAG get actors -a $ATESPACE"
echo ""
echo "  Cleanup:"
echo "    kubectl ate delete actor $ACTOR_NAME -a $ATESPACE"
echo "    kubectl ate delete actor-template $TEMPLATE -a $ATESPACE"
echo "    kubectl delete namespace $NAMESPACE"
echo "    kubectl delete clusterrole,clusterrolebinding openclaw-gateway-eks openclaw-dashboard"
