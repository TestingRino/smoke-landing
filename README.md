# smoke-landing

The control plane that decides what code written **outside** the corporate boundary (in `github.com/TestingRino`)
may enter it. Every app follows the same path. App repos need **no changes**, and opting one in takes one command.

```
 TestingRino/<repo>        DevSecOps VM (runner "devsecops-gate")           Google Cloud (testingrino-smoke)                BOUNDARY (GitLab + VM)
 ──────────────────        ─────────────────────────────────────            ────────────────────────────────                ──────────────────────
 push ──poll 30 min──▶ 1 GATE    gitleaks · semgrep · trivy fs                                                              
 or smokectl deploy              build · trivy image · syft SBOM
                                 policy: ALL critical/high block
                                 GitHub issues per blocking finding ◀─▶ app repo (deduplicated, auto-closed)
                                 DefectDojo (tracker, not the gate)
                                 cosign sign + attest (Cloud KMS key) ─▶ smoke-apps registry  @digest
                       2 STAGING (automatic on pass)                      Cloud Run smoke-<app> (public URL)
                                 secrets from Secret Manager at runtime    never in the image
                                 smoke check · ZAP baseline · attest
                       3 RELEASE (a human runs it: smokectl release)
                                 verify sig + gate + staging (fail closed) ─▶ smoke-release registry ──pull (read-only)──▶ verify · re-scan
                                 release attestation: who, why                                                           approve (2nd person)
                                                                                                                         import by digest
                                                                                                                         podman: signed only
```

Handoff notes: [`docs/handoff/defectdojo.md`](docs/handoff/defectdojo.md) · [`docs/handoff/pipeline-release.md`](docs/handoff/pipeline-release.md) ·
boundary team: [`boundary/README.md`](boundary/README.md)

## How each requirement is met

| Requirement | How |
|---|---|
| **Gate on a VM** | All builds and scans run on the VM's self-hosted runner. `policy/gate.env`: **every CRITICAL/HIGH blocks** (vulns fixed or not, SAST ERROR, misconfig, any secret). A scanner that crashes blocks. Exceptions live only in `policy/exceptions/<repo>/`, reviewed by PR, and are time-boxed (`exp:`). App-side ignore files are deleted and `nosemgrep` is off. |
| **Developers see what to fix** | One GitHub issue per blocking finding in the app repo, deduplicated by fingerprint and closed automatically when fixed. Secrets in **public** repos get one generic issue with no details. |
| **Findings tracked over time** | DefectDojo on the VM: every run's findings per app, with history and triage. It never influences the gate. |
| **Secrets outside the apps** | Google Secret Manager is the single source of truth (`smoke-<app>-<KEY>`, `smoke-shared-<KEY>`). Cloud Run injects them at runtime. Each app has its own runtime identity that can read only its own secrets. The pipeline never reads values. |
| **What was scanned is what runs** | The image is built once and then pushed, signed, attested, deployed and released **by digest**. |
| **Provenance for the boundary** | cosign signatures + attestations (SBOM, SLSA provenance, gate result, staging result, release) with a **Cloud KMS** key. No public transparency log, so repo names stay private. |
| **Human approval** | `release` records who approved and why, in a signed attestation. The **binding** approval is inside the boundary, by someone other than the author. GitHub Free has no required reviewers, so nothing here depends on them. |
| **No long-lived cloud keys** | GitHub OIDC → Workload Identity Federation, limited to `TestingRino/smoke-landing` on `main`. |
| **No new subscriptions** | Pay-per-use only: KMS ≈ $0.06/month, Secret Manager ≈ $0.06/secret/month, DefectDojo backups < $1/month, IAP free. |

## Setting up the DevSecOps VM from scratch

Already done once per project: `./gcp/bootstrap.sh testingrino-smoke us-central1 TestingRino smoke-landing` in
Cloud Shell (Workload Identity, registries, KMS signing key, roles). Re-running it is safe.

You run the steps below one at a time. Each block is a single command; the text after it says what to expect.
Steps A-C run in **Cloud Shell**, D-I **on the VM** (over SSH), J back in Cloud Shell.

**A. Cloud Shell: get the branch**
```bash
cd ~/smoke-landing && git fetch origin devsecops-pipeline && git checkout devsecops-pipeline && git pull
```

**B. Cloud Shell: check the VM exists**
```bash
gcloud compute instances describe smoke-devsecops --zone us-central1-a --project testingrino-smoke --format='value(status,machineType.basename(),disks[0].diskSizeGb)'
```
Expect `RUNNING  e2-standard-4  100`. If it says the VM was not found, create it (Ubuntu 24.04, no service account yet):
```bash
gcloud compute instances create smoke-devsecops --zone us-central1-a --project testingrino-smoke --machine-type e2-standard-4 --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud --boot-disk-size 100GB --boot-disk-type pd-balanced --no-service-account --no-scopes
```

**C. Cloud Shell: IAP firewall rule, tunnel role, backup bucket, backup service account.**
Done first, while nothing runs on the VM yet, because `backup-sa` stops and restarts it.
```bash
./gcp/defectdojo.sh firewall
```
Expect a rule `allow-iap-defectdojo` (35.235.240.0/20 → tcp:8088). The final table must not show `tcp:8088` or `all`.
```bash
./gcp/defectdojo.sh role
```
```bash
./gcp/defectdojo.sh bucket
```
Expect uniform access, `public_access_prevention: enforced`, 30-day retention, delete at 90 days.
```bash
./gcp/defectdojo.sh backup-sa
```
Answer `y` when it asks to stop the VM. Expect it to stop, attach `smoke-dojo-backup`, and start again.

**D. Get a GitHub token** (once, in the browser): GitHub → Settings → Developer settings → Fine-grained tokens →
Generate. Resource owner `TestingRino`, **All repositories**, permissions **Contents: read, Metadata: read,
Commit statuses: read & write, Issues: read & write**. Keep it open; you'll paste it twice.

**E. VM: connect, then clone this repo** (the password prompt wants the token from D, not your GitHub password):
```bash
gcloud compute ssh smoke-devsecops --zone us-central1-a --project testingrino-smoke
```
```bash
git clone --branch devsecops-pipeline https://github.com/TestingRino/smoke-landing.git ~/smoke-landing && cd ~/smoke-landing
```
Expect `Cloning into …` and no errors. The username is `TestingRino`; the password is the token.

**F. VM: install Docker, gcloud, cosign and the GitHub runner.** First get a runner registration token
(valid 1 hour): GitHub → TestingRino/smoke-landing → Settings → Actions → Runners → **New self-hosted runner**,
copy the value after `--token` in the "Configure" box. Then:
```bash
sudo RUNNER_TOKEN=<paste-runner-token> CONTROL_REPO=TestingRino/smoke-landing ./vm/bootstrap.sh
```
Takes 5-10 minutes. Expect `Registering runner 'devsecops-gate-1'`, then `VM bootstrap complete`.
On GitHub, the runner shows as **Idle** with the label `devsecops-gate`.

**G. VM: put the GitHub token from D into the runner's credentials file:**
```bash
sudo nano /etc/smoke-landing/runner.env
```
Paste the token after `GH_APPS_TOKEN=`, save (Ctrl+O, Enter) and exit (Ctrl+X). Leave the DefectDojo lines empty:
the next step fills them in.

**H. VM: install DefectDojo** (~10 minutes):
```bash
sudo vm/defectdojo/setup.sh
```
Expect `runner.env: DEFECTDOJO_TOKEN updated`, then 9 lines starting with `PASS` (the metadata-server check is
included because the VM now has a service account) and `All isolation checks passed.` If any line says `FAIL`, stop:
don't give anyone access until it passes. Then store the secrets file in your password manager:
```bash
sudo cat /opt/defectdojo/.env
```

**I. VM: test a backup, add logins, final check:**
```bash
sudo /opt/defectdojo/backup.sh
```
Expect `uploaded to gs://testingrino-smoke-dojo-backups/defectdojo/<timestamp>/`.
```bash
sudo /opt/defectdojo/add-user.sh ltruax@stephensonstellar.org
```
```bash
sudo /opt/defectdojo/add-user.sh smacewan@stephensonstellar.org
```
Each prints a one-time password to give that person privately.
```bash
sudo /opt/defectdojo/status.sh
```
Expect `web UP`, all services `running`, `firewall active`, a `last-backup` timestamp.

**J. Cloud Shell: tunnel access for the team:**
```bash
bin/smokectl grant-dojo ltruax@stephensonstellar.org
```
```bash
bin/smokectl grant-dojo smacewan@stephensonstellar.org
```
Then open the tunnel yourself (`bin/smokectl dojo-tunnel`), browse http://localhost:8088, log in as `admin` with
`DD_ADMIN_PASSWORD` from `/opt/defectdojo/.env`, and change that password (user menu → Change password).

**Afterwards:** add staging secrets (`bin/smokectl secret set <repo> KEY`), and merge `devsecops-pipeline` → `main`
when you're ready. Until the merge, workflows started from the branch **can't** log in to GCP, because the
Workload Identity condition only allows `refs/heads/main`. To test from the branch first, ask for a temporary second
provider limited to `refs/heads/devsecops-pipeline` and remove it afterwards.

## Daily use (`bin/smokectl`)

```bash
smokectl enable my-app                       # opt in: every new default-branch commit is gated + staged
smokectl deploy my-app [ref]                 # run now
smokectl runs my-app                         # history
smokectl status                              # live staging apps + URLs
smokectl secret set my-app STRIPE_KEY        # add/rotate (hidden input). --shared KEY for shared ones
smokectl secret list my-app                  # names only, never values
smokectl release my-app <sha> "why"          # promote a commit that passed staging
smokectl releases [my-app]                   # what's released + the exact boundary reference
smokectl grant-secrets <email>               # can add/rotate secrets, can't read them
smokectl grant-dojo <email>                  # DefectDojo access via IAP (port 8088 only, no SSH)
smokectl teardown my-app
```

**Per-app settings** (optional `.smoke.yml` in the app repo, see `examples/.smoke.yml`): port, health path, memory,
buildpack entrypoint, non-secret env vars, `shared_secrets: [KEY]`, `zap: false`.

**Where results show up**
- The app commit gets the status `smoke-landing/gate`: "Staging live: <url>; ready for release" or
  "Blocked at gate: N blocking findings (see issues)". After a release it also gets `smoke-landing/release`.
- **GitHub issues** (label `smoke-gate`) in the app repo for each blocking finding.
- The run summary has the gate table, findings (secrets redacted), smoke check, ZAP and DefectDojo link.
- Artifacts: `gate-reports` (raw JSON, `findings.json`, `summary.json`, SPDX SBOM), `dast-report`, `release-manifest`.

## Release and the boundary

`smokectl release <repo> <sha> "<justification>"` runs `release.yml`. It fails closed unless this exact digest:
- is signed by the KMS key;
- has a gate attestation for that commit with verdict pass;
- has passed staging within `RELEASE_MAX_STAGING_AGE_DAYS` (14).

It then copies the image with all signatures to `smoke-release` and adds a release attestation recording who,
why and the commit author. The run summary prints the **boundary reference**, e.g.
`us-central1-docker.pkg.dev/testingrino-smoke/smoke-release/my-app@sha256:…`. Send that, plus `TestingRino/my-app`,
to the boundary team. They verify, re-scan, approve (a second person) and import with `boundary/`.

Verify a release yourself in Cloud Shell. Install cosign once (the same version as the VM):
```bash
curl -sSfL -o ~/cosign https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-linux-amd64 && chmod +x ~/cosign
```
```bash
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
```
```bash
~/cosign verify --key keys/smoke-landing-signing.pub --insecure-ignore-tlog=true <boundary-reference>
```
Expect `The following checks were performed…` and a JSON line containing the same `sha256:` digest.

## DefectDojo (findings tracker)

**What it's for:** seeing and following up every finding across all repos over time: what's new, what got fixed,
and triage notes. **It is not the gate.** Marking something *false positive* or *risk accepted* there does **not**
unblock anything; that still needs an exception file via PR. `scripts/defectdojo-acceptances.sh` lists DefectDojo
triage that has no matching exception file. If DefectDojo is down, gate runs only show a warning.

Each repo is a product under product type `smoke-landing`, with engagement `smoke-gate` and one test per tool:
`gitleaks`, `semgrep`, `trivy-fs`, `trivy-image`, `zap-staging`. Each run re-imports into those tests, so fixed findings close.

**Team access from Windows** (after `smokectl grant-dojo you@…` and a login from `add-user.sh`):
1. Install the Google Cloud SDK and open **Google Cloud SDK Shell**. Run `gcloud auth login` once.
2. Each time:
   ```bash
   gcloud compute start-iap-tunnel smoke-devsecops 8088 --local-host-port=localhost:8088 --zone us-central1-a --project testingrino-smoke
   ```
3. Leave it open and browse **http://localhost:8088**. Don't use Cloud Shell Web Preview: it breaks web apps.

IAP access is limited to port 8088 by an IAM condition. It allows no SSH and no VM admin. DefectDojo 3.x open source has no
read-only role (that moved to the paid Pro plugin): authorized users can view and triage, but can't delete or configure.

**Operations** (on the VM): `sudo /opt/defectdojo/status.sh` (or `smokectl dojo-status`) ·
`sudo /opt/defectdojo/verify-isolation.sh` · upgrade: bump `DEFECTDOJO_VERSION` via PR, `git pull`, then
`sudo vm/defectdojo/upgrade.sh` (backs up first).

**Backups:** nightly at 02:37 UTC (`dojo-backup.timer`): `pg_dump` + media into `/var/backups/defectdojo/<ts>/`
(last 7 kept), uploaded to `gs://testingrino-smoke-dojo-backups/defectdojo/<ts>/`. The VM can only *create* objects
there, never read, overwrite or delete them. The bucket keeps everything 30 days (retention policy) and deletes after 90.

**Restore:** test any backup in a throwaway instance (the live one is untouched), then remove it:
```bash
sudo /opt/defectdojo/restore.sh --scratch /var/backups/defectdojo/<timestamp>
```
```bash
sudo /opt/defectdojo/restore.sh --cleanup
```
For an older backup from the bucket, copy it down in Cloud Shell and then onto the VM:
```bash
gcloud storage cp -r gs://testingrino-smoke-dojo-backups/defectdojo/<timestamp> .
```
```bash
gcloud compute scp --recurse <timestamp> smoke-devsecops:~ --zone us-central1-a
```
Replace live data only deliberately: `sudo /opt/defectdojo/restore.sh --in-place <dir>` (asks for confirmation, backs up first).

## Tuning the gate

Edit `policy/gate.env` via PR. Defaults: **every CRITICAL and HIGH blocks** (vulns fixed or not, SAST ERROR,
misconfig HIGH+, any secret). Semgrep WARNING (medium) is reported, filed in DefectDojo, and doesn't block.
High-risk ZAP alerts revoke public access and stop the release. An unfixed CVE needs a time-boxed exception in
`policy/exceptions/<repo>/trivyignore`, e.g. `CVE-2024-12345 exp:2027-01-31   # no upstream fix; not reachable`.
See `policy/exceptions/README.md`.

## Security notes and known limits

- **Builds run app code on the VM.** Isolation is Docker only, and the runner user is in the `docker` group (root-equivalent).
  `dojo-firewall.service` stops containers from reaching DefectDojo and the metadata server (the VM's service-account
  token). `verify-isolation.sh` proves it, including `docker build` steps. Keep the VM single-purpose.
- The PAT can read every repo under the account. For an org, swap it for a GitHub App with the same permissions.
- Staging apps are **public**: use test data and test-tier API keys with spend caps.
- gitleaks still honours inline `gitleaks:allow` comments. Reviewers should look for them.
- Pinned scanner and DefectDojo versions need deliberate, periodic bumps.

## Layout

```
.github/workflows/deploy.yml     gate -> staging -> status        release.yml  human promotion -> smoke-release
.github/workflows/poll.yml       every 30 min: new commits         teardown.yml manual teardown + TTL janitor
scripts/                         pipeline steps (lib.sh = shared helpers); defectdojo-*.sh = tracker import/report
policy/gate.env                  thresholds                        policy/exceptions/  per-repo, time-boxed waivers
smoke.config.env                 non-secret config                 bin/smokectl        operator CLI
keys/                            signing PUBLIC key (pinned by the boundary)
gcp/bootstrap.sh                 project, registries, WIF, KMS key, roles    gcp/defectdojo.sh  IAP rule, backup bucket/SA
vm/bootstrap.sh                  VM tools + runner                  vm/defectdojo/      DefectDojo install/ops
boundary/                        kit for the corporate GitLab team (verify, re-scan, approve, import, podman policy)
```
