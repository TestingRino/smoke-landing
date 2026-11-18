# Handoff: finish the gate → staging → release → boundary pipeline

**To:** the DevSecOps Claude session (you also own `docs/handoff/defectdojo.md`)
**Repo:** `TestingRino/smoke-landing` (private), branch **`devsecops-pipeline`**. Never commit to `main` directly; `main` is the live pipeline.
**Start from:** commit `d78e94d` ("WIP(devsecops): …"). You now own every file in this repo on that branch.

Read `docs/handoff/defectdojo.md` §2 first for the environment facts (GCP project, VM, runner, the operator works from Windows, Cloud Shell Web Preview breaks apps, `TestingRino` casing, etc.). They aren't repeated here.

---

## 1. Decisions already made with the operator (don't revisit)

| Topic | Decision |
|---|---|
| Flow | GitHub (outside boundary) → **gate** on the VM → **staging** on Cloud Run (`testingrino-smoke`) → **release** (human-approved promotion) → **boundary** pulls |
| Blocking | **All CRITICAL and HIGH block** (vulns, SAST ERROR, misconfig, any secret), fixed or unfixed. Unfixed ones need a **time-boxed exception** (`policy/exceptions/<repo>/trivyignore` with `exp:YYYY-MM-DD`) |
| Bugs | smoke-landing **files GitHub issues** in the app repo for blocking findings: deduplicated, auto-closed when fixed |
| Staging | Cloud Run, public URL, **deploys automatically when the gate passes** (no approval gate before staging) |
| Secrets | **Google Secret Manager is the single source of truth.** Staging keys are injected at runtime by Cloud Run and are **never** in the image or the signed artifact. Infisical is retired |
| Artifact | The unit of promotion is the **image digest**. It's signed with **cosign + a Cloud KMS key**, **no public transparency log** (`--tlog-upload=false`) |
| Approval | **Release** is a human-triggered workflow that records who approved. The **final, binding approval is inside the boundary** (GitLab), by someone other than the author |
| Boundary | On-prem **VM + GitLab** (tier unknown: assume **Free**). It **pulls** from a read-only release registry, **verifies** signature and attestations, **re-scans**, gets **manual approval**, **copies by digest** into its internal registry, and deploys **only signed images** |
| Tracker | DefectDojo on the VM (separate handoff) |
| Cost | **No new subscriptions** (pay-per-use GCP is fine: KMS ≈ $0.06/key version/month, Secret Manager ≈ $0.06/secret/month) |
| GitHub plan | Free personal account: **no required reviewers, no branch protection on private repos**. Don't design anything that depends on them |

## 2. What's done in `d78e94d` (wired into nothing yet, and never run)

| File | State |
|---|---|
| `policy/gate.env` | New knobs: `MAX_VULN_CRITICAL=0`, `MAX_VULN_HIGH=0`, `VULN_COUNT_UNFIXED=true`, `MAX_MISCONFIG_HIGH=0`, `FILE_ISSUES`, `MAX_NEW_ISSUES_PER_RUN`, `ZAP_BLOCK_ON_HIGH=true` |
| `scripts/normalize.sh` | Merges gitleaks/semgrep/trivy-fs/trivy-image into `reports/findings.json` `[{fp, kind, severity, rule, title, location, detail, fixed?}]`. `fp` = sha256(key)[0:16]. A missing report is a hard failure |
| `scripts/evaluate.sh` | Applies the policy over `findings.json`, adds `blocking` and `check` to each finding, writes `summary.json` `{repo, commit, verdict, checks[], run, evaluatedAt, policyHash}`, exports `VERDICT`, exits 1 on block |
| `scripts/report.sh` | Job summary from `summary.json` and `findings.json` |
| `scripts/file-issues.sh` | GitHub issues per blocking finding (marker `<!-- smoke-gate:fp=… -->`, labels `smoke-gate`, `severity:*`, `kind:*`), closes issues whose fp disappeared, cap per run. **Public repos:** secret details withheld (one generic issue). Needs PAT **Issues: read & write** |
| `scripts/resolve.sh` | Also exports `REPO_PRIVATE` |
| `scripts/sync-secrets.sh` | Secret Manager naming: `smoke-<app-slug>-<KEY>` (label `smoke-app=<slug>`) and `smoke-shared-<KEY>` (label `smoke-shared=true`, opt-in via `.smoke.yml` `shared_secrets: [KEY]`). Grants the per-app runtime SA `secretAccessor` per secret and writes the Cloud Run `--set-secrets` spec. **Never reads values** |
| `scripts/teardown.sh` | No longer deletes secrets (they're the source of truth now) |
| `scripts/lib.sh` | `COSIGN_FLAGS`, `PUBKEY_FILE=keys/smoke-landing-signing.pub`, `verify_key`, `attest`, `read_attestation` helpers. Infisical removed |
| `scripts/sign-attest.sh` | Signs `image_remote@DIGEST` and attests SBOM (`spdxjson`), provenance (`slsaprovenance1`, SLSA v1 shape) and gate result (`$ATTEST_GATE_TYPE` = `summary.json` + image, digest and scanner versions) |
| `scripts/attest-staging.sh` | `$ATTEST_STAGING_TYPE` predicate `{environment, url, commit, digest, smokeCheck, dast{high,medium}, verdict, run, deployedAt}` |
| `smoke.config.env` | `KMS_KEY=gcpkms://projects/testingrino-smoke/locations/global/keyRings/smoke-landing/cryptoKeys/artifact-signing/cryptoKeyVersions/1`, `RELEASE_REPO=smoke-release`, `ATTEST_{GATE,STAGING,RELEASE}_TYPE` (URIs under `https://github.com/TestingRino/smoke-landing/attestations/…/v1`), `COSIGN_IMAGE`; Infisical vars removed |
| `vm/bootstrap.sh` | Installs `cosign` v2.4.1; Infisical references removed |
| `vm/runner.env.example` | Only `GH_APPS_TOKEN` (PAT now also needs **Issues: read & write**) |
| `examples/.smoke.yml` | `shared_secrets:` example |

**Unit-test these before relying on them.** Feed synthetic reports (pass case, block case, missing report, public-repo secret) through `normalize.sh` → `evaluate.sh` → `report.sh` with `SMOKE_RUNNER_ENV=/nonexistent` and a temp `WORK`/`RUNNER_TEMP`. `file-issues.sh` can be tested against a scratch repo. Known things to double-check:
- `evaluate.sh` passes `$unfixed` through `--argjson` into the selectors.
- `normalize.sh` key uniqueness: the semgrep key uses `.extra.lines`, which some semgrep versions redact. If so, fall back to the line number.
- `sync-secrets.sh` uses `gcloud secrets list --filter=labels.smoke-app=<slug>`, and the prefix-strip logic for apps whose slug is a prefix of another (`api` vs `api-v2`). The label filter should prevent cross-matching; verify it.

## 3. Remaining work

### 3.1 `.github/workflows/deploy.yml`

**Gate job:**
1. After "Evaluate policy", add **"File GitHub issues"** (`scripts/file-issues.sh`) with `if: always() && env.WORK != '' && hashFiles(...)`, or have the script check for `findings.json` itself (it does). It must run on **pass and block**.
2. Push only on pass (the current behavior); then add **"Sign & attest"** (`scripts/sign-attest.sh`) with `DIGEST: ${{ steps.push.outputs.digest }}`. It needs GCP auth, which already happens before push.
3. Upload `gate-reports` (it now includes `findings.json` and `summary.json`).

**Deploy job → rename to "Staging":**
1. **Remove** `environment: smoke-review`. Required reviewers don't exist on this plan, and staging is automatic. Use `environment: { name: staging, url: … }` with no protection rules, for the URL display only.
2. Replace the "Sync secrets (Infisical -> Secret Manager)" step name and behavior: `scripts/sync-secrets.sh` (new).
3. After DAST: **"Attest staging"** (`scripts/attest-staging.sh`), only on success. Needs `WORK=$RUNNER_TEMP/smoke` (already set) and `APP_URL` (exported by `deploy.sh`).
4. `dast.sh`: with `ZAP_BLOCK_ON_HIGH=true`, high alerts already revoke public access and fail the job, so there's no staging attestation and no release. Also add `-x zap.xml` for DefectDojo.

**Finalize:** commit status texts. Success: `"Staging live: <url>; ready for release"`; block: `"Blocked at gate: N blocking findings (see issues)"`.

### 3.2 New `.github/workflows/release.yml` (human promotion)

- `workflow_dispatch` inputs: `repo`, `commit` (full or short SHA), `justification` (required free text).
- `runs-on: [self-hosted, devsecops-gate]`, `permissions: {contents: read, id-token: write}`, concurrency per repo.
- Steps:
  1. **Resolve:** staging image `image_remote(repo):<sha12>` → digest (`gcloud artifacts docker images describe … --format='value(image_summary.digest)'`).
  2. **Verify (fail closed):**
     - `cosign verify --key keys/smoke-landing-signing.pub --insecure-ignore-tlog=true <staging>@<digest>`
     - gate attestation: `verdict=="pass"` and `commit` matches
     - staging attestation: `verdict=="pass"`, `digest` matches, and `deployedAt` within N days (configurable, default 14)
     - use `read_attestation` from `lib.sh`, which picks the **last** attestation of each type: confirm that ordering is reliable, or select by `run`/timestamp
  3. **Promote:** `cosign copy <staging>@<digest> ${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${RELEASE_REPO}/<slug>:<sha12>`. This copies the signature and attestations too. Confirm the digest is unchanged afterwards.
  4. **Release attestation** on the release ref (`$ATTEST_RELEASE_TYPE`): `{approvedBy: github.actor, approvedAt, justification, commit, digest, sourceRepo, gateRun, stagingRun, releaseRun}`.
  5. Commit status `smoke-landing/release` = success on the app commit; job summary with the **exact reference for the boundary**: `us-central1-docker.pkg.dev/testingrino-smoke/smoke-release/<slug>@sha256:…`
  6. Upload a `release-manifest.json` artifact containing the same data.
- Add `smokectl release <repo> <sha> "<justification>"`.
- Separation of duties: record `github.actor` and the commit author. Warn in the summary, or fail if configured, when they're the same person. The binding check is at the boundary.

### 3.3 `gcp/bootstrap.sh` additions (idempotent; the operator runs it in **Cloud Shell**)

- Enable `cloudkms.googleapis.com`.
- KMS keyring `smoke-landing` (global) and key `artifact-signing`: purpose `asymmetric-signing`, algorithm `ec-sign-p256-sha256`, protection `software`. Grant **`roles/cloudkms.signerVerifier` on that key only** to `smoke-deployer`.
- Export the public key: `gcloud kms keys versions get-public-key 1 --key artifact-signing --keyring smoke-landing --location global --output-file smoke-landing-signing.pub`. The operator pastes it back, and you commit it as **`keys/smoke-landing-signing.pub`**. It's public; the boundary pins this file.
- Artifact Registry repo **`smoke-release`** (docker, us-central1), with **no cleanup policy**: releases are kept. `smoke-deployer` gets `repoAdmin` on it.
- SA **`boundary-puller`** with **only** `roles/artifactregistry.reader` on `smoke-release`. Key creation is a manual step for the operator (`gcloud iam service-accounts keys create …`). The JSON key goes **into GitLab as a masked, protected CI variable** and is never committed. Document key rotation (90 days). If the operator's org policy blocks SA keys, document the alternative: Workload Identity Federation from GitLab's OIDC, which is preferred if their GitLab can reach Google's token service.
- Custom role **`smokeSecretWriter`** (project level) for teammates who add API keys but **can't read** them:
  - permissions: `secretmanager.secrets.create`, `get`, `list`, `update`, `delete`; `secretmanager.versions.add`, `list`, `get`, `enable`, `disable`, `destroy`
  - **not** `versions.access` or `setIamPolicy`
- Grant `smoke-deployer` the `deployer` permissions it already has. Remember it needs `secretmanager.admin` for `add-iam-policy-binding` on secrets (it has it).
- **Reuse the `bind()` retry helper** for every IAM binding: new resources propagate slowly, and the operator hit this twice.

### 3.4 `bin/smokectl` (runs on the operator's Windows machine, in Git Bash or WSL; keep it plain bash)

- `secret set <repo> KEY`: read the value with `read -rs` (never as an argument), create `smoke-<slug>-KEY` with labels `managed-by=smoke-landing,smoke-app=<slug>` if missing, add a version from stdin.
- `secret set --shared KEY` (label `smoke-shared=true`), `secret list <repo>` (names and update times, **never values**), `secret rm <repo> KEY`.
- `grant-secrets <email>` / `revoke-secrets <email>`: the `smokeSecretWriter` role.
- `release <repo> <sha> "<why>"`, `releases [repo]` (list of the release registry plus the boundary reference).
- Remove the old Infisical `secrets` command.
- Note: `smokectl` sources `smoke.config.env`. Sourcing `scripts/lib.sh` for `slug` is fine, but it must not require `runner.env`.

### 3.5 Boundary kit: `boundary/` (handed to the corporate GitLab team; they own and adapt it)

- `boundary/README.md`: trust model, what's verified, setup, rotating the pull key, how the approval works.
- `boundary/verify-and-import.sh <release-ref@digest> <expected-github-repo>`. **Fails closed** at every step:
  1. `cosign verify --key smoke-landing-signing.pub --insecure-ignore-tlog=true`
  2. verify gate, staging and release attestations: types, `digest == subject`, gate `verdict==pass` with every blocking check count 0, staging `verdict==pass`, release present, `sourceRepo` matches the expected repo
  3. **re-scan** with the boundary's own Trivy (offline DB mirror if air-gapped), fail on CRITICAL/HIGH
  4. `cosign copy` to the internal GitLab registry by digest, which also brings the signatures
  5. print the internal ref
- `boundary/.gitlab-ci.yml` template. Stages: `verify` → `rescan` → `approve` (`when: manual`) → `import` → `deploy`:
  - **GitLab Free has no protected-environment approvals.** Enforce in the `approve` job script: `$GITLAB_USER_LOGIN` must be in an `APPROVERS` list (CI variable) **and** differ from the pipeline creator (saved as an artifact by the first job) **and** differ from the commit author in the release attestation if that can be mapped.
  - Run only on protected branches. Store the pull key as a masked + protected variable.
  - If their GitLab is Premium or Ultimate, document switching to protected environments with required approvals.
- `boundary/podman/policy.json` + `boundary/podman/registries.d/internal.yaml`: on the deploy VM, **podman refuses unsigned images** from the internal registry (`sigstoreSigned` with `keyPath` pointing at the pinned public key, `use-sigstore-attachments: true`). The deploy job uses `podman pull <internal>@sha256:…` and `podman run`. Document that Docker has no equivalent, so they should use podman.
- Secrets inside the boundary come from **their** secrets store and are injected at runtime. **Nothing from Secret Manager crosses the boundary.**

### 3.6 Operator steps to document (with exact commands, one per code block)

1. Re-run `gcp/bootstrap.sh` in Cloud Shell after `git pull`; paste back the public key.
2. Update the PAT to add **Issues: read & write**.
3. **Retire Infisical** on the VM: `sudo docker compose -f /home/smoke/infisical/docker-compose.yml down -v`, then `sudo rm -rf /home/smoke/infisical`. Confirm nothing in it is needed (it held no app secrets).
4. Re-run `vm/bootstrap.sh` (installs cosign); runner re-registration isn't needed.
5. Add staging secrets: `smokectl secret set <repo> KEY`.
6. **Merge `devsecops-pipeline` → `main`** (the operator decides when). Until then, workflows from the branch **can't** authenticate to GCP, because the WIF condition only allows `refs/heads/main`. To test from the branch, propose a **second, temporary provider or condition** for `refs/heads/devsecops-pipeline` with a short life, and ask the operator first.

### 3.7 README

Rewrite the lifecycle and setup sections: the gate → staging → release → boundary flow, Secret Manager usage, `smokectl` commands, the boundary handoff and how to verify a release by hand. Remove every Infisical reference. Link both handoff docs.

## 4. Acceptance criteria

1. A blocked run files deduplicated issues; a later clean run closes them. On a public repo, secret details aren't disclosed.
2. A passing run produces a signed staging image with SBOM, provenance and gate attestations, and Cloud Run staging runs with secrets from Secret Manager that are **not present in the image** (verify with `trivy image` plus `docker history`).
3. A release fails closed if any attestation is missing or failing, or if the digest doesn't match. On success, it copies to `smoke-release` with signatures, adds the release attestation, and prints the boundary reference.
4. `boundary/verify-and-import.sh` passes for a real release and **fails** for: an unsigned image, a tampered (re-tagged) image, a missing release attestation, and a gate verdict of block.
5. Podman refuses an unsigned image from the internal registry.
6. `shellcheck -x -S warning` and `actionlint` are clean; no secret values appear in any log.

## 5. Conventions

Same as `docs/handoff/defectdojo.md` §5. The operator runs one command at a time from Windows; give each command its own code block and say what output to expect.
