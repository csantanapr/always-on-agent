// Copyright 2026 Google LLC
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
/**
 * kubectl-ate–backed implementation of the AteApiClient interface.
 *
 * Used when the gateway cannot present a podcert mTLS client cert to ateapi
 * (a plain Deployment on a pre-1.36 cluster has no PodCertificate). kubectl-ate
 * port-forwards to ateapi and handles auth-mode detection itself, the same
 * mechanism the dashboard already uses successfully in this cluster. Requires
 * the kubectl-ate binary in the pod + RBAC for pods/portforward.
 *
 * With `tokenFile` set, kubectl-ate presents that bearer token instead of
 * minting one for the shared ate-client ServiceAccount, so ateapi sees the
 * gateway's own principal and its access policy decides what it may do. That
 * is how the EKS manifests run it, with a projected ServiceAccount token.
 */
import { execFile } from "node:child_process";
import type { ActorRef, AteApiClient, EgressPolicyManifest } from "./ateapi-client.js";

/** stderr of a failed kubectl-ate run, or the error itself. */
function errText(err: unknown): string {
  return String((err as { stderr?: string })?.stderr || (err as Error)?.message || err);
}

const alreadyExists = (err: unknown) => /already ?exists/i.test(errText(err));

export function createKubectlAteClient(
  cfg: { binPath?: string; endpoint?: string; tokenFile?: string } = {},
): AteApiClient {
  const bin = cfg.binPath || process.env.KUBECTL_ATE || "kubectl-ate";
  // Direct gRPC target for ateapi. Without it kubectl-ate tries to auto-detect by
  // reading the ate-api-server Deployment in the pod's namespace (wrong namespace
  // for a gateway outside ate-system), so we always pass --endpoint.
  const endpoint = cfg.endpoint || process.env.ATE_ENDPOINT || "";
  const tokenFile = cfg.tokenFile || "";
  const globalArgs = [
    ...(endpoint ? ["--endpoint", endpoint] : []),
    ...(tokenFile ? ["--token-file", tokenFile] : []),
  ];

  // execFile rather than its promisified form, so a manifest can go in on stdin.
  const run = (args: string[], input?: string): Promise<void> =>
    new Promise((resolve, reject) => {
      const child = execFile(bin, [...args, ...globalArgs], { timeout: 60_000 }, (err, _stdout, stderr) => {
        if (err) reject(Object.assign(err, { stderr: String(stderr ?? "") }));
        else resolve();
      });
      child.stdin?.end(input ?? "");
    });

  return {
    async createActor(ref: ActorRef, _templateNamespace: string, templateName: string) {
      try {
        await run([
          "create", "actor", ref.name,
          "-a", ref.atespace,
          // release-0.1 spells it --template-ref; main and v1.0 renamed it to
          // --template (substrate#1536). Both resolve a bare name inside the
          // actor's atespace.
          "--template-ref", templateName,
        ]);
      } catch (err) {
        // release-0.1-era cobra prints `unknown flag: --template-ref`; v1.0
        // prints `unknown flag "--template-ref"`.
        if (/unknown flag\W+--template-ref/i.test(errText(err))) {
          try {
            await run([
              "create", "actor", ref.name,
              "-a", ref.atespace,
              "--template", templateName,
            ]);
            return;
          } catch (err2) {
            if (alreadyExists(err2)) return;
            throw err2;
          }
        }
        if (alreadyExists(err)) return; // idempotent
        throw err;
      }
    },
    async suspendActor(ref: ActorRef) {
      await run(["suspend", "actor", ref.name, "-a", ref.atespace]);
    },
    async deleteActor(ref: ActorRef) {
      await run(["delete", "actor", ref.name, "-a", ref.atespace]);
    },
    // An existing policy is left as it is, even if it differs from this one:
    // replacing it needs the stored uid and version
    // (`kubectl ate update egress-policy`), and a policy someone edited by hand
    // should not be overwritten on the next message.
    async createEgressPolicy(ref: ActorRef, policy: EgressPolicyManifest) {
      try {
        await run(["create", "egress-policy", ref.name, "-a", ref.atespace, "-f", "-"], JSON.stringify(policy));
      } catch (err) {
        if (alreadyExists(err)) return;
        throw err;
      }
    },
  };
}
