# OpenClaw on Agent Substrate

Run OpenClaw personal-AI-assistant instances on GKE with [Agent Substrate](https://github.com/agent-substrate/substrate),
minimizing compute cost. OpenClaw agents are idle >95% of the time but must appear
online 24/7 for channels like WhatsApp. We resolve that by **splitting presence
from cognition**: an always-on gateway holds the channel connections, while the
expensive agent runs as a suspendable Substrate actor. The gateway suspends it
once the conversation goes idle, and the next message auto-resumes it on demand.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design and tradeoffs (with diagrams),
and [Measured latency](docs/ARCHITECTURE.md#measured-latency) for what activation
actually costs and which bracket each number belongs to.

## Demo

[![OpenClaw on Agent Substrate: always-on agents, suspended when idle](docs/always-on-agents-demo-poster.jpg)](https://www.youtube.com/watch?v=D5a9tyPkaPY)

Two minutes, with narration. A WhatsApp message wakes an agent that is not
running, it answers from restored conversation state, checkpoints itself once the
conversation goes quiet, and then ten agents cycle through five machines while the
control plane is queried alongside.

Watch on [YouTube](https://www.youtube.com/watch?v=D5a9tyPkaPY), or download
[`docs/always-on-agents-demo.mp4`](docs/always-on-agents-demo.mp4) (3.7 MB, 1440p).

## How it integrates

### A drop-in plugin: zero edits to existing OpenClaw files
Everything lives in `extensions/substrate/`. Copy it into OpenClaw's `extensions/`
and enable it in `openclaw.json`. Config is declared in the plugin manifest
(`openclaw.plugin.json` → `configSchema`) and startup wiring runs through
OpenClaw's plugin service + hook API, so **no core OpenClaw file is modified**:
no changes to config types, Zod schema, `server.impl.ts`, channels, agents, or
skills.

```bash
cp -r extensions/substrate <openclaw>/extensions/substrate
# or bundle into the image:  docker build --build-arg OPENCLAW_EXTENSIONS=substrate ...
```

Then set `plugins.entries.substrate` in config (see `extensions/substrate/README.md`).

The same logic can be wired straight into an OpenClaw build instead, as a
`src/substrate/` module plus about 30 lines of config and startup plumbing. That
was the original shape here and the plugin supersedes it, so it is not in this
repo.

## Repo layout

| Path | What |
|------|------|
| `extensions/substrate/` | The drop-in OpenClaw plugin (manifest, ACP backend, actor provisioner, idle suspender) |
| `manifests/` | Substrate + gateway K8s resources (WorkerPool, ActorTemplate, gateway, ingress) |
| `manifests/eks/` | The same for EKS on Substrate v1.0.0-rc.3, plus the actor egress policy |
| `build/` | Image build: gateway/actor Dockerfiles, Cloud Build configs, actor image inputs (`build/actor/`) |
| `demo/` | WhatsApp demo config + deploy script + live dashboard |
| `demo/eks/` | EKS deploy and verify scripts |
| [`docs/`](docs/ARCHITECTURE.md) | Architecture doc + diagrams |

## Quick start (demo)

1. Install Substrate on a GKE cluster from a Substrate checkout with
   `hack/install-ate.sh --deploy-ate-system`. Create the cluster with the
   PodCertificate beta APIs enabled, and set up the snapshot bucket and its IAM
   first; see [`demo/README.md`](demo/README.md) Step 1. (The packaged installer
   at [`ai-on-gke/substrate-gke`](https://github.com/ai-on-gke/substrate-gke) does
   all of that for you, but its pre-built image track is not usable yet.)
2. `export PROJECT_ID=… GCS_BUCKET=… GEMINI_API_KEY=…`
3. `cd demo && ./deploy-demo.sh` builds the images, pins them by digest, deploys
   the WorkerPool, ActorTemplate, and gateway, then prints next steps (link
   WhatsApp, send a message). See [`demo/README.md`](demo/README.md) for the full
   walkthrough.

## Running on EKS (Substrate v1.0.0-rc.3)

The same demo runs on Amazon EKS against Agent Substrate `v1.0.0-rc.3`, with the
model on Amazon Bedrock behind an in-cluster LLM gateway instead of Gemini.
`demo/eks/deploy-demo.sh` builds the images with plain `docker build`, pushes
them to private ECR, and deploys everything from `manifests/eks/`. Nothing is
exposed outside the cluster: both Services are ClusterIP, there is no Ingress,
and you reach the gateway, the dashboard and the actors with port-forwards.

What is different on that path:

- **No credentials in actors.** The actor sends model calls to
  `http://llm-gateway.llm-gateway.svc.cluster.local` with a placeholder bearer
  token. Each actor's egress policy allows only that host, and Substrate's
  egress gateway replaces the `Authorization` header with an actor JWT
  (audience `llm-gateway`) on the way out. An actor with no egress policy has no
  network at all, so the gateway plugin creates one for every conversation actor
  right after the actor itself (`egressPolicy` in the plugin config).
- **The gateway's own identity.** The plugin's `kubectl-ate` presents the
  gateway's projected ServiceAccount token (`ateTokenFile`), and an atespace
  access policy makes that ServiceAccount an editor of `openclaw-demo` only.
- **Router mTLS.** v1.0 serves `atenet-router` over mTLS on port 443. The
  gateway presents a pod certificate from the podidentity signer, and its SPIFFE
  ID has to be in the router's `--ingress-allowed-spiffe-ids`.
- **WhatsApp is optional.** Without `WHATSAPP_PEER` the script deploys
  everything except the WhatsApp channel and binding, and
  `demo/eks/verify-demo.sh` checks the actor, the gateway and the
  gateway-to-actor path without it.

Prerequisites, commands and the full list of differences are in
[`demo/README.md`](demo/README.md#running-on-eks).

## For a harness company adopting this

- **Copy `extensions/substrate/`** into your OpenClaw tree (or bundle via
  `OPENCLAW_EXTENSIONS`). No other OpenClaw code changes.
- **Config only, per deployment**: set `plugins.entries.substrate` on the gateway
  (atespace, golden template, actor token, idle timeout) and ACP bindings in
  `openclaw.json`. The actor image runs stock OpenClaw with no plugin.
- **On the Substrate side** (targets current OSS `agent-substrate/substrate`,
  CRD group `ate.dev`): apply the `WorkerPool` + `ActorTemplate` manifests
  (`ate.dev/v1alpha1`), point the gVisor `SandboxConfig` at a runsc build that
  survives a heavy multi-process Node.js actor, and apply the control-plane
  changes below. Actors use the **atespace** model
  (`kubectl ate create atespace <a>; kubectl ate create actor <n> -a <a> --template-ref <name>`,
  `--template` on Substrate main) and are reached through the atenet router, addressed
  by Host `<actor>.<atespace>.actors.resources.substrate.ate.dev` on release-0.1 and by
  the `ate-target-actor: <atespace>/<actor>` header on main. The gateway sends both.

### Substrate configuration this needs

It runs on stock Substrate. Earlier revisions of this file listed six
control-plane patches as prerequisites, and that list is obsolete. The cluster
behind [Measured latency](docs/ARCHITECTURE.md#measured-latency) runs `v0.1.0`
images for `atecontroller`, `atelet`, `ateom-gvisor` and `atenet` with no source
changes, the `gvisor-default` `SandboxConfig` exactly as the installer ships it,
and the default 20s golden warmup. No pinned runsc.

Two of the retired claims were wrong rather than merely stale, and
[`substrate-patches/README.md`](substrate-patches/README.md) records them so they
do not get repeated: a GKE-Sandbox `runsc` build is **not** required, and the
`ATE_*` environment knobs it described never existed upstream.

What is left is operator tuning. Both of these are `atenet-router` flags whose
defaults are low for an LLM harness:

| Flag | Default | Why it matters here |
|---|---|---|
| `--route-timeout` | 10s | Bounds one request from the ingress listener to the actor's response. The gateway relays an entire LLM completion over that request, so a turn longer than the default is cut off. |
| `--parked-request-budget` | 5s | Bounds how long a request waits for its actor to resume. Resume is 3.4s P50 here, so the default leaves little headroom on a cold node or a larger snapshot. |

Because the plugin integrates *below* the framework via OpenClaw's own ACP
protocol and plugin API, community-maintained channels/agents/skills, including
future ones, work unmodified.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Substrate control-plane gaps go
upstream as issues rather than as patches carried here; the running list is in
[`substrate-patches/README.md`](substrate-patches/README.md).

Who maintains this and under what rules is in
[`MAINTAINERS.md`](MAINTAINERS.md). This repository follows the project
[Governance](https://github.com/agent-substrate/substrate/blob/main/GOVERNANCE.md)
and the conventions in
[`docs/integration-repos.md`](https://github.com/agent-substrate/substrate/blob/main/docs/integration-repos.md),
rather than defining its own.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).

## Trademarks

[OpenClaw](https://github.com/openclaw/openclaw) is an independent open-source
project (MIT-licensed). This repository provides an integration that runs
OpenClaw on Agent Substrate; it is **not affiliated with, sponsored by, or
endorsed by** the OpenClaw project. "OpenClaw" and any related names or logos are
the property of their respective owners and are used here only descriptively to
identify the software being integrated.
