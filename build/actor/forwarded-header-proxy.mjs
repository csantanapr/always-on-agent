// Copyright 2026 The Agent Substrate Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Front door for the OpenClaw actor on Agent Substrate v1.
//
// Requests reach the actor from atenet-router, whose Envoy adds forwarded
// headers (X-Forwarded-Proto and similar) but no client address OpenClaw can
// attribute, and wakeup probes reach it with no forwarded headers at all, from
// the same link-local address. OpenClaw's proxy attribution rejects one or the
// other whatever gateway.trustedProxies says. So this proxy listens on the
// actor port, drops the forwarded headers, and passes each request to
// OpenClaw on loopback, where it is a plain local request. OpenClaw still
// enforces its bearer token on every gateway route.
//
// It starts OpenClaw as its child and exits with it.

import http from "node:http";
import { spawn } from "node:child_process";

const LISTEN_PORT = Number(process.env.ACTOR_PORT || 80);
const UPSTREAM_PORT = Number(process.env.OPENCLAW_PORT || 18789);
const DROP = new Set(["forwarded", "x-real-ip", "via"]);

const child = spawn(
  "node",
  ["/app/openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "loopback", "--port", String(UPSTREAM_PORT)],
  { stdio: "inherit" },
);
child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => child.kill(sig));

const server = http.createServer((req, res) => {
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    const name = k.toLowerCase();
    if (DROP.has(name) || name.startsWith("x-forwarded-")) continue;
    headers[k] = v;
  }
  headers.host = `127.0.0.1:${UPSTREAM_PORT}`;
  const up = http.request(
    { host: "127.0.0.1", port: UPSTREAM_PORT, method: req.method, path: req.url, headers },
    (upRes) => {
      res.writeHead(upRes.statusCode ?? 502, upRes.headers);
      upRes.pipe(res);
    },
  );
  up.on("error", () => {
    // OpenClaw not listening yet: a probe retries, so answer 503 and move on.
    if (!res.headersSent) res.writeHead(503, { "content-type": "text/plain" });
    res.end("openclaw not ready\n");
  });
  req.pipe(up);
});
// Streams (SSE completions) can run for minutes.
server.requestTimeout = 0;
server.headersTimeout = 60_000;
server.listen(LISTEN_PORT, "0.0.0.0");
