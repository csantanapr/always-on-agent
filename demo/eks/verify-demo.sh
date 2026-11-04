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
# Check the EKS demo end to end after demo/eks/deploy-demo.sh, without WhatsApp.
#
#   1. Control plane: the demo actor and its egress policy exist.
#   2. Actor: one chat turn through `kubectl ate proxy actor`, which resumes the
#      actor, and whose model call goes out through the egress gateway with an
#      actor JWT in place of the placeholder key.
#   3. Gateway: /healthz and /readyz over `kubectl port-forward`.
#   4. Gateway to actor: the plugin's own fetchActor, run inside the gateway pod,
#      over atenet-router's mTLS listener with the gateway's pod certificate.
#      This is the path a WhatsApp turn takes.
#   5. Provisioning (PROBE_PROVISION=true, the default): the plugin creates a
#      throwaway actor oc-verify with its egress policy as the gateway's own
#      ServiceAccount, wakes it, then deletes it.
#
# It creates and deletes the oc-verify actor and nothing else. All traffic is
# local port-forwards; nothing is exposed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
KUBECTL_ATE_BIN="${KUBECTL_ATE_BIN:-$REPO_DIR/build/bin/kubectl-ate}"
PROBE_PROVISION="${PROBE_PROVISION:-true}"
PROXY_PORT="${PROXY_PORT:-18000}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
NAMESPACE="openclaw"
ATESPACE="openclaw-demo"
ACTOR_NAME="oc-agent"
PROMPT="${PROMPT:-Reply with one short sentence that includes the word pong.}"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

KCTX=()
if [ -n "$KUBE_CONTEXT" ]; then KCTX=(--context "$KUBE_CONTEXT"); fi
k() { kubectl ${KCTX[@]+"${KCTX[@]}"} "$@"; }
[ -x "$KUBECTL_ATE_BIN" ] || KUBECTL_ATE_BIN="$(command -v kubectl-ate || true)"
[ -n "$KUBECTL_ATE_BIN" ] || die "kubectl-ate not found; set KUBECTL_ATE_BIN"
ate() { "$KUBECTL_ATE_BIN" ${KCTX[@]+"${KCTX[@]}"} "$@"; }

PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

TOKEN="$(k -n "$NAMESPACE" get secret openclaw-secrets -o jsonpath='{.data.gateway-token}' | base64 -d)"
[ -n "$TOKEN" ] || die "no gateway token in secret $NAMESPACE/openclaw-secrets"
BODY="$(jq -cn --arg p "$PROMPT" '{model:"openclaw/default",stream:false,messages:[{role:"user",content:$p}]}')"

# --- 1. Control plane ---
ate get actor "$ACTOR_NAME" -a "$ATESPACE" 2>/dev/null || die "actor $ATESPACE/$ACTOR_NAME not found"
policy="$(ate get egress-policy "$ACTOR_NAME" -a "$ATESPACE" -o json 2>/dev/null || true)"
[ -n "$policy" ] || die "actor $ACTOR_NAME has no egress policy, so it has no network"
jq -c '.rules' <<<"$policy"
pass "actor $ACTOR_NAME and its egress policy exist"

# --- 2. Actor through kubectl ate proxy ---
ate proxy actor "$ACTOR_NAME" -a "$ATESPACE" "${PROXY_PORT}:80" >/dev/null 2>&1 &
PIDS+=("$!")
# The first request resumes the actor; give the restore time.
for _ in $(seq 1 60); do
  curl -sf -m 10 "http://127.0.0.1:${PROXY_PORT}/readyz" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf -m 10 "http://127.0.0.1:${PROXY_PORT}/readyz" >/dev/null || die "actor /readyz did not answer through the proxy"
pass "actor answers /readyz through atenet-router"
reply="$(curl -s -m 180 -w '\n%{http_code}' "http://127.0.0.1:${PROXY_PORT}/v1/chat/completions" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY")"
code="$(tail -n1 <<<"$reply")"; reply="$(sed '$d' <<<"$reply")"
[ "$code" = "200" ] || die "actor chat turn returned HTTP $code: $reply"
content="$(jq -r '.choices[0].message.content // empty' <<<"$reply")"
[ -n "$content" ] || die "actor chat turn returned no content: $reply"
echo "    actor said: $content"
pass "actor completed a model turn through the LLM gateway"
# Suspend to S3 and wake it again through the same proxy: the demo's core claim.
ate suspend actor "$ACTOR_NAME" -a "$ATESPACE" --mode=sync >/dev/null || die "suspend of $ACTOR_NAME failed"
state="$(ate get actor "$ACTOR_NAME" -a "$ATESPACE" -o json | jq -r '.status.state')"
[ "$state" = "ACTOR_STATE_SUSPENDED" ] || die "$ACTOR_NAME is $state after suspend"
pass "actor suspended (snapshot in object storage)"
curl -sf -m 120 "http://127.0.0.1:${PROXY_PORT}/readyz" >/dev/null || die "actor did not resume on the next request"
pass "actor resumed on demand from its snapshot"
kill "${PIDS[-1]}" 2>/dev/null || true

# --- 3. Gateway over port-forward ---
k -n "$NAMESPACE" port-forward svc/openclaw-gateway "${GATEWAY_PORT}:18789" >/dev/null 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 15); do
  curl -sf -m 5 "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -m 5 "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null || die "gateway /healthz failed"
curl -sf -m 5 "http://127.0.0.1:${GATEWAY_PORT}/readyz" >/dev/null || die "gateway /readyz failed"
pass "gateway /healthz and /readyz over port-forward"
kill "${PIDS[-1]}" 2>/dev/null || true

# --- 4. Gateway to actor, the plugin's own client ---
gw_node() { k -n "$NAMESPACE" exec deploy/openclaw-gateway -c gateway -- node --input-type=module -e "$1"; }
gw_node "
const { fetchActor } = await import('/app/extensions/substrate/dist/actor-router.js');
const ref = { name: '$ACTOR_NAME', atespace: '$ATESPACE' };
const r = await fetchActor(ref, '/v1/chat/completions', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + process.env.OPENCLAW_GATEWAY_TOKEN },
  body: JSON.stringify($BODY),
});
const text = await r.text();
if (r.status !== 200) { console.error('HTTP', r.status, text); process.exit(1); }
console.log('    actor said (via gateway):', JSON.parse(text).choices[0].message.content);
" || die "gateway could not reach the actor through atenet-router (check --ingress-allowed-spiffe-ids)"
pass "gateway reached the actor over router mTLS with its pod certificate"

# --- 5. Provisioning as the gateway's ServiceAccount ---
if [ "$PROBE_PROVISION" = "true" ]; then
  gw_node "
const { readFileSync } = await import('node:fs');
const { createKubectlAteClient } = await import('/app/extensions/substrate/dist/kubectl-ate-client.js');
const { createActorProvisioner } = await import('/app/extensions/substrate/dist/actor-provisioner.js');
const { fetchActor } = await import('/app/extensions/substrate/dist/actor-router.js');
const sub = JSON.parse(readFileSync(process.env.OPENCLAW_CONFIG_DIR + '/openclaw.json', 'utf8')).plugins.entries.substrate.config;
const client = createKubectlAteClient({ binPath: sub.kubectlAtePath, endpoint: sub.ateapiAddress, tokenFile: sub.ateTokenFile });
const prov = createActorProvisioner({ atespace: sub.atespace, ateapi: client, egressPolicy: sub.egressPolicy, logger: { info: (m) => console.log('    ' + m) } });
await prov.ensure('oc-verify', sub.template);
const r = await fetchActor({ name: 'oc-verify', atespace: sub.atespace }, '/readyz');
console.log('    oc-verify /readyz:', r.status);
if (r.status !== 200) process.exit(1);
" || die "the gateway could not provision and wake oc-verify (check the atespace access policy)"
  ate get egress-policy oc-verify -a "$ATESPACE" -o json | jq -c '.rules' >/dev/null \
    || die "oc-verify has no egress policy"
  pass "gateway created oc-verify with its egress policy as its own ServiceAccount and woke it"
  ate suspend actor oc-verify -a "$ATESPACE" >/dev/null 2>&1 || true
  ate delete actor oc-verify -a "$ATESPACE" >/dev/null 2>&1 || echo "    (delete oc-verify by hand: kubectl ate delete actor oc-verify -a $ATESPACE)"
fi

# Leave the demo actor parked, the way the gateway would after its idle timeout.
ate suspend actor "$ACTOR_NAME" -a "$ATESPACE" >/dev/null 2>&1 || true

echo ""
echo "All checks passed."
