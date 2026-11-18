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

## Operator steps for this version (in order)

You run these one at a time. Each block is a single command, with what to expect after it.

**1. In Cloud Shell, get this branch:**
```bash
cd ~/smoke-landing && git fetch origin devsecops-pipeline && git checkout devsecops-pipeline && git pull
```

**2. Add the signing key, release registry and roles** (safe to re-run):
```bash
./gcp/bootstrap.sh testingrino-smoke us-central1 TestingRino smoke-landing
```
It ends with `SIGNING PUBLIC KEY` and a `-----BEGIN PUBLIC KEY-----` block. **Paste that block back to Claude** (it's
public). It gets committed as `keys/smoke-landing-signing.pub`, which the boundary pins.

**3. Update the GitHub token:** GitHub → Settings → Developer settings → Fine-grained tokens → your smoke token → add
**Issues: Read and write** (keep Contents read, Metadata read, Commit statuses read/write). Nothing to change on the VM.

**4. On the VM, retire Infisical** (it held no app secrets):
```bash
sudo docker compose -f /home/smoke/infisical/docker-compose.yml down -v
```
```bash
sudo rm -rf /home/smoke/infisical
```
```bash
sudo ss -ltnp | grep -E ':8080|:8088' || echo "8080 and 8088 are free"
```
Expect: `8080 and 8088 are free`.

**5. On the VM, update the code and install cosign** (runner re-registration isn't needed):
```bash
cd ~/smoke-landing && git fetch origin devsecops-pipeline && git checkout devsecops-pipeline && git pull
```
```bash
sudo ./vm/bootstrap.sh
```
Expect it to end with `VM bootstrap complete`.

**6. On the VM, install DefectDojo** (~10 minutes the first time):
```bash
sudo vm/defectdojo/setup.sh
```
Expect 9 lines starting with `PASS` and then `All isolation checks passed.`. **Then store `/opt/defectdojo/.env` in your
password manager:**
```bash
sudo cat /opt/defectdojo/.env
```

**7. In Cloud Shell, open DefectDojo to IAP only:**
```bash
./gcp/defectdojo.sh firewall
```
Expect a rule `allow-iap-defectdojo` (35.235.240.0/20, tcp:8088). The final table must not show `tcp:8088` or `all`.
```bash
./gcp/defectdojo.sh role
```
Expect `ok`.

**8. Backups:**
```bash
./gcp/defectdojo.sh bucket
```
Expect the bucket settings: uniform access, `public_access_prevention: enforced`, 30-day retention, delete at 90 days.
```bash
./gcp/defectdojo.sh backup-sa
```
This **stops the VM for about 2 minutes** (it asks first). Then, on the VM:
```bash
sudo /opt/defectdojo/backup.sh
```
Expect `uploaded to gs://testingrino-smoke-dojo-backups/defectdojo/<timestamp>/`.

**9. Give the team access** (in Cloud Shell, one per person):
```bash
bin/smokectl grant-dojo ltruax@stephensonstellar.org
```
```bash
bin/smokectl grant-dojo smacewan@stephensonstellar.org
```
And their DefectDojo logins (on the VM; each prints a one-time password to give them privately):
```bash
sudo /opt/defectdojo/add-user.sh ltruax@stephensonstellar.org
```
```bash
sudo /opt/defectdojo/add-user.sh smacewan@stephensonstellar.org
```

**10. Add staging secrets** (Git Bash, WSL or Cloud Shell; the value is typed hidden):
```bash
bin/smokectl secret set <repo> OPENAI_API_KEY
```

**11. Merge `devsecops-pipeline` → `main` when you're ready.** Until then, workflows started from the branch **can't**
log in to GCP, because the Workload Identity condition only allows `refs/heads/main`. To test from the branch first,
ask for a temporary second provider limited to `refs/heads/devsecops-pipeline` and remove it afterwards.

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
