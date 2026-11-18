# Boundary kit: importing smoke-landing releases

For the corporate GitLab team. You own this kit, so adapt it to your environment. It lets you take an app that
was built and tested **outside** your boundary and run it **inside**, only after you have checked it yourselves.

## Trust model

```
outside (smoke-landing, GCP)                                   inside (your GitLab + deploy VM)
gate ─▶ staging ─▶ release (human, recorded) ─▶ smoke-release ─▶ verify ─▶ rescan ─▶ approve ─▶ import ─▶ deploy
         every step signs an attestation with one KMS key        pinned key   your     your     by       podman refuses
         bound to the image DIGEST                                            Trivy    people   digest   unsigned images
```

- **What you trust:** one public key, `smoke-landing-signing.pub`, pinned in this repo. Its private key lives in
  Google Cloud KMS and can't be exported. Only smoke-landing's pipeline identity may sign with it.
- **What you don't trust:** tags, registry contents, or anyone's word. Everything is checked by digest against that key.
- **What you add:** your own vulnerability re-scan, and the binding approval by your people.
- **Secrets never cross:** staging secrets are injected at runtime by Cloud Run and are not in the image.
  Inside, the app gets its secrets from **your** secrets store at runtime.

## What `verify-and-import.sh` checks (fails closed at every step)

| # | Check | Fails when |
|---|---|---|
| 1 | Reference is pinned `…@sha256:…` | a tag or anything else is given |
| 2 | `cosign verify` with the pinned key | unsigned, signed by another key, or a re-pointed tag |
| 3 | **release** attestation on this digest | the image was never promoted, or the release is for a different GitHub repo than you expected |
| 3 | **gate** attestation for the same commit + digest | verdict isn't `pass`, or any blocking check count > 0 |
| 3 | **staging** attestation for the same commit + digest | missing (never ran in staging) or verdict isn't `pass` |
| 4 | your Trivy re-scan | any CRITICAL/HIGH (your exceptions: `BOUNDARY_TRIVYIGNORE`) |
| 5 | `cosign copy` into your registry, then re-verify there | digest changed or signature missing after copy |

Each attestation is a signed in-toto statement whose subject is the image digest, so it can't be moved to a different image.

## One-time setup

1. **Copy this folder** into a GitLab project. Put the pinned key next to the script:
   copy `keys/smoke-landing-signing.pub` from the smoke-landing repo to `boundary/smoke-landing-signing.pub`.
   Compare its fingerprint with the smoke-landing operator out of band (phone or in person):
   ```bash
   sha256sum boundary/smoke-landing-signing.pub
   ```
2. **Tools image:** build an internal image with `cosign` 2.4.x, `trivy`, `jq` and `bash`, and set `TOOLS_IMAGE`.
   For air-gapped use, mirror the Trivy DB and set `TRIVY_OFFLINE=true` and `TRIVY_CACHE_DIR`.
3. **Pull credential:** the smoke-landing operator creates a key for the `boundary-puller` service account.
   It can only *read* the `smoke-release` registry, nothing else. Store it as the **File** variable
   `BOUNDARY_PULL_KEY` (protected, masked where possible). **Rotate every 90 days**: the operator creates a new key,
   you swap the variable, the operator deletes the old key.
   *Preferred if your GitLab can reach `sts.googleapis.com`:* Workload Identity Federation from GitLab's OIDC
   ID token, with no stored key. The operator adds a provider for your GitLab issuer that can impersonate
   `boundary-puller`. Replace the `cosign login` line with a token exchange.
4. **Variables:** `APPROVERS` (GitLab usernames), `INTERNAL_REGISTRY`, and optionally `GITHUB_TO_GITLAB_USERS`
   (so a developer can't approve their own code). Mark them protected. Protect the branch the pipeline runs on.
5. **Deploy VM (podman):**
   ```bash
   sudo install -D -m 0644 boundary/smoke-landing-signing.pub /etc/containers/keys/smoke-landing-signing.pub
   ```
   ```bash
   sudo install -m 0644 boundary/podman/policy.json /etc/containers/policy.json
   ```
   ```bash
   sudo install -m 0644 boundary/podman/registries.d/internal.yaml /etc/containers/registries.d/smoke-imports.yaml
   ```
   Edit the registry name in `smoke-imports.yaml` to your `INTERNAL_REGISTRY`. Then allow each app once:
   ```bash
   sudo INTERNAL_REGISTRY=registry.corp.example/apps/smoke-imports boundary/podman/add-app.sh <app-slug>
   ```
   The policy **rejects everything by default**. Only `<INTERNAL_REGISTRY>/<app>` images signed by the pinned key
   *for that app* can be pulled. Use **podman**, not Docker: Docker has no equivalent signature enforcement.

## Approving an import

1. The smoke-landing operator sends you the **boundary reference** from the release run, e.g.
   `us-central1-docker.pkg.dev/testingrino-smoke/smoke-release/demo@sha256:3e0d…`, and the GitHub repo `TestingRino/demo`.
2. Someone runs the pipeline with `RELEASE_REF` and `EXPECTED_REPO`. `verify` and `rescan` run automatically.
3. Read `verify.json` (commit, author, who released it and why, gate policy, staging date) and the re-scan output.
4. **A different person** from `APPROVERS` clicks **Run** on `approve`. The job refuses: anyone not in
   `APPROVERS`, the person who started the pipeline, the commit's author (when mapped), and the person who
   released it in smoke-landing (when mapped).
5. `import` copies the image by digest into your registry and re-verifies it. `deploy` pulls it with podman.

**GitLab Premium/Ultimate:** use a protected environment with required approvals on `import` instead of the `approve`
job's script checks. Keep `APPROVERS` as the approver list there.

## Verify a release by hand

```bash
cosign verify --key smoke-landing-signing.pub --insecure-ignore-tlog=true <ref@sha256:...>
```
```bash
cosign verify-attestation --key smoke-landing-signing.pub --insecure-ignore-tlog=true --type https://github.com/TestingRino/smoke-landing/attestations/release/v1 <ref@sha256:...> | jq -r '.payload | @base64d | fromjson | .predicate'
```
Use the same command with `…/gate/v1` and `…/staging/v1`. The SBOM is type `spdxjson` and provenance is type `slsaprovenance1`.

## Tested (in a lab with local registries and a test key)

- Passes for a real release; the import re-verifies in the internal registry.
- Fails for: an unsigned image, a re-pointed (tampered) tag, attestations signed with another key, a missing release
  attestation, a release for another GitHub repo, and a gate verdict of `block`.
- Re-scan passes a clean image and fails an old image with known CRITICAL/HIGH CVEs.
- podman (4.9) pulls the signed import, and refuses an unsigned image (in an unknown repo, or slipped into an allowed
  app's repo) and images from any other registry.

Notes: `--insecure-ignore-tlog` is intentional. smoke-landing doesn't publish to the public transparency log,
so repository names stay private; trust comes from the pinned key. podman's `remapIdentity` (one rule for all
apps) rejected valid signatures with podman 4.9, so `add-app.sh` writes one `exactRepository` rule per app.
