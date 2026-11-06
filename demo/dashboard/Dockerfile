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

# kubectl-ate is built here, pinned to the same Substrate commit the rest of the
# demo pins. It used to be copied out of the gateway image at pod start, which
# looked like the safe choice but shipped whatever that image happened to carry.
# What it carried was a July build whose auth-mode detection predates the
# server's move to --authentication-config: it looked for an --auth-mode=jwt
# argument, did not find one, concluded the server wanted no credentials, and
# sent none. The dashboard then showed no actors at all while the pod stayed
# green and the API returned a clean empty list.
#
# The build context is demo/dashboard. Two sources, picked by KUBECTL_ATE_PREBUILT:
#   false (default)  clone SUBSTRATE_REF and `go build` it here. The GKE path
#                    (build/cloudbuild-dashboard.yaml) passes the release-0.1
#                    head its control plane runs; the default is v1.0.0.
#   true             copy build/bin/kubectl-ate from the build context, i.e.
#                    demo/dashboard/build/bin/kubectl-ate, for a build host that
#                    cannot reach the Go module proxy. demo/eks/deploy-demo.sh
#                    stages it there.
FROM golang:1.27-bookworm AS ate
ARG SUBSTRATE_REF=v1.0.0
ARG KUBECTL_ATE_PREBUILT=false
# Every path segment is a bracket glob, so the source matches nothing when
# build/bin (or the binary in it) is absent, and package.json keeps the COPY
# valid either way, on BuildKit and on the classic builder alike.
COPY package.json buil[d]/bi[n]/kubectl-at[e] /prebuilt/
RUN set -eu; mkdir -p /out; \
    if [ "$KUBECTL_ATE_PREBUILT" = "true" ]; then \
      [ -f /prebuilt/kubectl-ate ] || { echo "KUBECTL_ATE_PREBUILT=true but build/bin/kubectl-ate is not in the build context" >&2; exit 1; }; \
      install -m 0755 /prebuilt/kubectl-ate /out/kubectl-ate; \
    else \
      git clone --filter=blob:none https://github.com/agent-substrate/substrate.git /src; \
      git -C /src checkout --detach "${SUBSTRATE_REF}"; \
      cd /src && CGO_ENABLED=0 go build -o /out/kubectl-ate ./cmd/kubectl-ate; \
    fi; \
    /out/kubectl-ate --version

FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl && \
    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/ && \
    rm -rf /var/lib/apt/lists/*

COPY --from=ate /out/kubectl-ate /usr/local/bin/kubectl-ate

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY dashboard.js ./

EXPOSE 8090
CMD ["node", "dashboard.js"]
