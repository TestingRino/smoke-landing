# smoke-landing

Landing zone for smoke-testing apps from **github.com/TestingRino** before they are handed to the corporate side.
Every app goes through the same steps: **pulled from GitHub → DevSecOps gate on a VM → human review → deployed to a public URL with
secrets injected from a central store → live smoke check + DAST**. App repos need **no changes**. Opting one in takes
one command.

```
 TestingRino/<any-repo>                    DevSecOps VM (self-hosted runner "devsecops-gate")             Google Cloud (dedicated project)
 ─────────────────────                     ──────────────────────────────────────────────────            ────────────────────────────────
 push to default branch ──poll 30 min──▶  1 GATE   gitleaks (full history) · semgrep · trivy fs
   (topic: smoke-deploy)                           build image (Dockerfile or buildpacks)
 or `smokectl deploy`                              trivy image · syft SBOM · policy/gate.env
                                                   └─ push image by digest ─────────────────────▶ Artifact Registry
                                          2 REVIEW  GitHub environment "smoke-review"
                                                    (required reviewer reads the gate report)
                                          3 DEPLOY  Infisical (127.0.0.1, on VM) ──sync──────────▶ Secret Manager  smoke-<app>-<KEY>
                                                    gcloud run deploy  @digest ──────────────────▶ Cloud Run  smoke-<app>  (public URL)
                                          4 VERIFY  HTTP smoke check · OWASP ZAP baseline ───────▶ https://smoke-<app>-….run.app
 commit status "smoke-landing/gate" ◀──── 5 REPORT  success + live URL / failure + reason
```

## Why it's built this way

| Requirement | How |
|---|---|
| **Secrets managed outside the apps** | **Infisical** (self-hosted on the VM) is the single source of truth: one folder per repo, plus an optional `/_shared` folder that apps import. At deploy time the values are copied into GCP Secret Manager. Each app gets **its own runtime service account** that can read only its own secrets. Values never appear in git, GitHub, CLI args, logs or Cloud Run config. |
| **DevSecOps gate on a VM** | All build and scan jobs run on your VM through a self-hosted runner. Thresholds are in `policy/gate.env`. A scanner that crashes **blocks** the deploy. Exceptions live only in `policy/exceptions/<repo>/`, so an app can't waive its own findings: app-side ignore files are deleted before scanning and `nosemgrep` is disabled. |
| **Review before deploy** | GitHub Environment `smoke-review` with required reviewers. The reviewer sees the gate report in the run summary and then approves or rejects. |
| **Public test access** | Cloud Run with `--allow-unauthenticated`: an HTTPS URL per app, scale-to-zero (≈$0 while idle), ≤ `MAX_INSTANCES_CAP` instances. |
| **What was scanned is what runs** | The image is built once, scanned, pushed and deployed **by digest**. |
| **All repos under the account** | The poller covers every repo with topic `smoke-deploy`, or every repo if `ALL_REPOS="true"`. |
| **No long-lived cloud keys** | GitHub OIDC → Workload Identity Federation, limited to `TestingRino/smoke-landing` on `main` only. |
| **Cleanup** | A daily janitor tears down apps not redeployed within `TTL_DAYS` (default 14). |

## One-time setup (~1 hour)

**0. Create this repo** as **private** `TestingRino/smoke-landing` and push this code to it.
Never attach a self-hosted runner to a public repo.

**1. GCP**: create a dedicated project (e.g. `testingrino-smoke`) with billing enabled, then:
```bash
./gcp/bootstrap.sh testingrino-smoke us-central1 TestingRino smoke-landing
```
Copy the values it prints into `smoke.config.env`.

**2. VM**: Ubuntu 22.04/24.04, x86_64, ≥4 vCPU / 8 GB RAM / 80 GB disk. No inbound ports needed except SSH.
Get a runner token from *repo → Settings → Actions → Runners → New self-hosted runner*, then:
```bash
git clone https://github.com/TestingRino/smoke-landing && cd smoke-landing
sudo RUNNER_TOKEN=<token> CONTROL_REPO=TestingRino/smoke-landing ./vm/bootstrap.sh
sudo -u smoke ./vm/infisical/setup.sh         # back up vm/infisical/.env right away
```

**3. Infisical**: open the UI over a tunnel: `ssh -L 8080:localhost:8080 <vm>` → http://localhost:8080
1. Create the admin account, then a project (e.g. `smoke-apps`) with an environment whose **slug is `smoke`**.
2. *Access Control → Identities*: create a machine identity with **Universal Auth** and add it to the project with the **Viewer** (read-only) role.
3. Copy the project ID into `smoke.config.env` (`INFISICAL_PROJECT_ID`).

**4. Runner credentials**: edit `/etc/smoke-landing/runner.env` on the VM:
- `GH_APPS_TOKEN`: a fine-grained PAT. Resource owner `TestingRino`, *All repositories*, permissions **Contents: read, Metadata: read, Commit statuses: read & write**.
- `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET`: from step 3.

**5. GitHub review gate**: in *smoke-landing → Settings → Environments*, create `smoke-review`.
Add yourself (and any reviewers) as **Required reviewers** and restrict deployment branches to `main`.
> On a **private** repo owned by a free personal account, required reviewers aren't available. They need GitHub Pro/Team.
> Without them, deploys go out straight after the automated gate.

**6.** Commit the filled-in `smoke.config.env` and push. Done.

## Daily use

```bash
export PATH="$PWD/bin:$PATH"
smokectl enable my-app          # opt in: deploys every new default-branch commit (≤30 min)
smokectl secrets my-app         # shows the Infisical folder for its API keys and credentials
smokectl deploy my-app          # deploy now (or: smokectl deploy my-app feature-branch)
smokectl runs my-app            # pipeline history
smokectl status                 # live apps + public URLs
smokectl teardown my-app
```

**Adding API keys and credentials:** in Infisical, project `smoke-apps` → env `smoke` → folder `/<repo>`
(dots in the repo name become `-`). Add `KEY = value` pairs. They reach the app as environment variables on the
next deploy. For a key many apps share (e.g. `OPENAI_API_KEY`), put it once in `/_shared` and add a *secret import*
of `/_shared` into each app's folder. If an app's folder defines the same key, its value wins over the shared one.
Keys deleted in Infisical are removed from GCP on the next deploy.

**Per-app settings** (optional): copy `examples/.smoke.yml` to the root of the app repo and set port, health path,
memory, buildpack entrypoint, non-secret env vars and ZAP on/off. With no Dockerfile, Google buildpacks auto-detect
Node and Python. Python apps usually need `entrypoint:` (e.g. `gunicorn -b :$PORT app:app`).

**Where results show up**
- The app repo commit gets a `smoke-landing/gate` status: ✅ with a link to the live URL, or ❌ with the reason.
- The run summary shows the gate report table, findings (secrets always redacted), the smoke check and ZAP alerts.
- Run artifacts: `gate-reports` (all raw JSON + **SPDX SBOM**, useful for corporate intake) and `dast-report`.

## Tuning the gate

Edit `policy/gate.env`, and protect it with a branch-protection rule plus CODEOWNERS. Defaults **block** on:
any secret (git history, source tree or image), semgrep ERROR, fixable CRITICAL CVE, or CRITICAL misconfig.
HIGH CVEs, semgrep warnings and HIGH misconfigs are reported but don't block. Set `ZAP_BLOCK_ON_HIGH=true` to
revoke public access automatically when ZAP finds High-risk alerts.

For a justified exception, add `policy/exceptions/<repo>/{gitleaksignore,trivyignore,semgrep-exclude-rules.txt}`.
See `policy/exceptions/README.md`.

## Security notes and known limits

- **The build runs app code on the VM.** Dockerfile `RUN` steps, npm/pip install scripts and buildpacks all execute.
  Isolation is Docker only, and the runner user is in the `docker` group, which is root-equivalent. Infisical is
  bound to `127.0.0.1`, so build containers can't reach it. Keep the VM single-purpose.
  For stronger isolation: run Infisical on a second VM, use rootless Docker or gVisor, or use ephemeral runners.
- The PAT can read every repo under the account. For an org, swap it for a GitHub App with the same three permissions.
- Apps are **publicly reachable**. Use test data and test-tier API keys, and set spend caps with providers (OpenAI etc.).
- gitleaks still honours inline `gitleaks:allow` comments. Reviewers should look for them.
- If your org policy blocks `allUsers` (domain-restricted sharing), override it for this project only.
- Pinned scanner versions in `smoke.config.env` need deliberate, periodic bumps.

## Layout

```
.github/workflows/deploy.yml     gate → review → deploy → verify → status
.github/workflows/poll.yml       every 30 min: find new commits on opted-in repos
.github/workflows/teardown.yml   manual teardown + daily TTL janitor
scripts/                         pipeline steps (bash; lib.sh = shared helpers)
policy/gate.env                  thresholds          policy/exceptions/   per-repo waivers
smoke.config.env                 non-secret config   bin/smokectl         operator CLI
vm/                              VM bootstrap, runner.env template, Infisical compose
gcp/bootstrap.sh                 project, Artifact Registry, deployer SA, Workload Identity Federation
```
