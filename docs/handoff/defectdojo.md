# Handoff: DefectDojo for smoke-landing

**To:** the DevSecOps Claude session
**Repo:** `TestingRino/smoke-landing` (private), branch **`devsecops-pipeline`**. All DevSecOps changes, including this one, go on that branch. Do not commit to `main`.
**Owner:** TestingRino (GitHub owner name is case-sensitive in Google's federation rules: always `TestingRino`)

---

## 1. What smoke-landing is

The development team writes code with Claude **outside** the corporate boundary and pushes it to GitHub repos under `TestingRino`. smoke-landing is the control plane that decides what may enter the boundary:

```
GitHub repo ──▶ DevSecOps gate (self-hosted runner on VM)          ──▶ staging (Cloud Run, public URL)  ──▶ release registry ──▶ BOUNDARY
               gitleaks · semgrep · trivy fs · build · trivy image     secrets injected at runtime from       (signed, human-        on-prem VM + GitLab
               syft SBOM · policy: ALL critical/high block              Google Secret Manager; smoke check     promoted digests)     pulls, verifies signature
               files GitHub issues · cosign-signs + attests             + OWASP ZAP baseline; staging attest.                         + attestations, manual approval
```

**Your piece:** DefectDojo is the **findings tracker and dashboard** the team uses to see, triage and follow up every finding across all repos over time.

DefectDojo is **not** the gate. The pass/block verdict is computed by `scripts/evaluate.sh` from `policy/gate.env` and must not depend on DefectDojo being up, reachable or correct.

## 2. Current environment (facts)

| Item | Value |
|---|---|
| GCP project | `testingrino-smoke` (number `934359946111`), region `us-central1` |
| VM | `smoke-devsecops`, zone `us-central1-a`, e2-standard-4 (4 vCPU / 16 GB), 100 GB disk, Ubuntu 24.04, **no GCP service account attached** (`--no-service-account --no-scopes`), external IP, default VPC |
| Runner | GitHub Actions self-hosted runner `devsecops-gate-1`, label `devsecops-gate`, runs as user `smoke` (in `docker` group), installed by `vm/bootstrap.sh` |
| VM credentials | `/etc/smoke-landing/runner.env` (0640 `root:smoke`), sourced by `scripts/lib.sh`. Today it holds `GH_APPS_TOKEN` only |
| Ports in use on VM | **8080 is being freed**: Infisical is being retired (`sudo docker compose -f /home/smoke/infisical/docker-compose.yml down -v`). Confirm 8080 is free before using it |
| Docker | Docker CE + compose plugin; build containers (docker build / BuildKit / `pack`) and scanner containers run on this same VM |
| Operator | Works from **Windows**, uses the Google Cloud SDK Shell. Cloud Shell is also used |
| Secrets store | Google Secret Manager (Infisical is being removed) |
| GCP login from Actions | Workload Identity Federation, condition `assertion.repository == 'TestingRino/smoke-landing' && assertion.ref == 'refs/heads/main'`. **Workflows started from `devsecops-pipeline` cannot authenticate to GCP.** Steps that only talk to DefectDojo on the VM don't need GCP auth |

### Lessons already learned (don't repeat them)
- **Cloud Shell Web Preview breaks web apps** (it corrupted Infisical's requests: "Unsupported Media Type"). Never use it to reach DefectDojo.
- `/home/smoke` is not readable by the operator's login user. Use `sudo docker compose -f /home/smoke/<dir>/docker-compose.yml ...` instead of `cd`.
- `hostname` on GCE returns a long FQDN. Don't build names from it.
- From Cloud Shell, an `ssh -L` tunnel prints a harmless `bind [::1]` IPv6 warning.

## 3. Interfaces you consume

Each gate run writes reports to `$WORK/reports/` (`WORK=$RUNNER_TEMP/smoke`) in the **gate** job of `.github/workflows/deploy.yml`. They're also uploaded as the run artifact `gate-reports`.

| File | Producer | DefectDojo scan type |
|---|---|---|
| `gitleaks.json` | gitleaks `git` mode, full history, `--redact` | `Gitleaks Scan` |
| `semgrep.json` | semgrep `--json` | `Semgrep JSON Report` |
| `trivy-fs.json` | trivy fs (vuln, misconfig, secret) | `Trivy Scan` (test title "trivy-fs") |
| `trivy-image.json` | trivy image (vuln, secret) on the built image | `Trivy Scan` (test title "trivy-image") |
| `sbom.spdx.json` | syft | not for DefectDojo (future: Dependency-Track) |
| `findings.json` | `scripts/normalize.sh` + `evaluate.sh`: normalized list `{fp, kind, severity, rule, title, location, detail, blocking, check}` | optional: `Generic Findings Import` if useful |
| `summary.json` | `evaluate.sh`: `{repo, commit, verdict, checks[], run, evaluatedAt, policyHash}` | metadata for the engagement/test |

The **deploy (staging)** job writes `$WORK/zap/zap.json` (+ `zap.html`) from `zap-baseline.py` in `scripts/dast.sh`. **DefectDojo's ZAP parser expects the XML report**, so add `-x zap.xml` to the `zap-baseline.py` call.

Environment available in both jobs: `REPO`, `SHA`, `OWNER`, `GITHUB_RUN_ID`, `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`. `REPO_PRIVATE` is available in the gate job.

Note: on `devsecops-pipeline`, `normalize.sh`, `evaluate.sh`, `report.sh` and `file-issues.sh` are being reworked right now (normalized findings, GitHub issue filing). Read them on the branch before wiring in.

## 4. Requirements

**R1. Deploy DefectDojo on the VM**
- Use the official DefectDojo docker compose at a **pinned release tag** (no `latest`). Put files under `vm/defectdojo/` with a `setup.sh` that is idempotent and safe to re-run.
- Run under `/home/smoke/defectdojo` (or `/opt`), owned by `smoke`. Use named volumes for Postgres and media.
- Generate strong random secrets on first run (`DD_SECRET_KEY`, `DD_CREDENTIAL_AES_256_KEY`, DB password) into a `.env` with mode 0600. Tell the operator to store it in a password manager. Never commit it.
- Set memory limits so DefectDojo can't starve builds. Budget about 4 GB total.
- The admin password is printed by the initializer. Retrieve it once, tell the operator to change it, and don't log it into Actions output.

**R2. Ingest results after every run (non-blocking)**
- Add `scripts/defectdojo-import.sh` that calls `POST /api/v2/reimport-scan/` once per report, with:
  - `auto_create_context=true`, `product_type_name=smoke-landing`, `product_name=<repo>`, `engagement_name=smoke-gate`, `engagement` type CI/CD
  - `test_title` per tool (`gitleaks`, `semgrep`, `trivy-fs`, `trivy-image`, `zap-staging`)
  - `version=<sha12>`, `commit_hash=<sha>`, `branch_tag=<ref>`, `build_id=<run id>`, `source_code_management_uri=https://github.com/TestingRino/<repo>`
  - `close_old_findings=true`, `deduplication_on_engagement=true`, `minimum_severity=Info`
- Wire it into `deploy.yml`:
  - in the **gate** job, after "Evaluate policy", with `if: always() && env.WORK != ''`, so **blocked** runs are recorded too
  - in the **deploy** job after DAST, for ZAP, also `if: always()`
- **Failure must never change the verdict:** warn (`::warning::`) and exit 0 if DefectDojo is down or slow. Use a curl timeout of about 30 seconds.
- Write a run-summary line with a link to the product in DefectDojo.

**R3. DefectDojo must not become a bypass**
- Risk acceptances and false-positive marks in DefectDojo do **not** change the gate. Exceptions remain files in `policy/exceptions/<repo>/` reviewed via PR.
- Optional: a read-only report that lists DefectDojo risk acceptances without a matching exception file. Don't auto-sync.
- Keep DefectDojo's own **GitHub/Jira integration off**. `scripts/file-issues.sh` already files and closes deduplicated GitHub issues for blocking findings, and running both creates duplicates.

**R4. Team access without SSH (no subscriptions)**
- Use **Google IAP TCP forwarding scoped to the DefectDojo port only**:
  - a firewall rule allowing `35.235.240.0/20` to `tcp:<dd-port>` on `smoke-devsecops` (network tag)
  - grant per user `roles/iap.tunnelResourceAccessor` with an IAM condition limiting `destination.port` to the DefectDojo port. No `compute.instanceAdmin`, no OS Login or SSH roles.
  - teammate command: `gcloud compute start-iap-tunnel smoke-devsecops <port> --local-host-port=localhost:<port> --zone us-central1-a --project testingrino-smoke`, then open `http://localhost:<port>`
  - add `smokectl grant-dojo <email>` and `smokectl revoke-dojo <email>`
- IAP reaches the VM's **internal NIC**, so DefectDojo can't bind to `127.0.0.1` only. **Build and scanner containers run untrusted app code on this VM and must not reach DefectDojo:**
  - add host firewall rules (`DOCKER-USER` and `INPUT`) that drop traffic from `docker0`, other build bridges and BuildKit to the DefectDojo port, persisted across reboots (systemd unit after `docker.service`)
  - the DefectDojo compose network must not be attachable by builds
  - **verify with a test:** `docker run --rm curlimages/curl -m5 http://<vm-internal-ip>:<port>` must fail; IAP access must work
- No public exposure: no `0.0.0.0/0` firewall rule for this port, and no external load balancer.

**R5. Backups to Cloud Storage**
- Nightly `pg_dump` (custom format) plus a tar of the media volume, uploaded to a dedicated bucket, e.g. `gs://testingrino-smoke-dojo-backups`:
  - uniform access, public access prevention on, object versioning plus a 30-day retention policy
  - lifecycle: delete after 90 days
- The VM has **no** service account today. Propose the minimal option and **ask the operator before changing it**: either attach a dedicated SA with only `roles/storage.objectCreator` on that one bucket (scopes limited to `devstorage.read_write`), or an alternative.
- Provide `vm/defectdojo/restore.sh` and test a restore.

**R6. Credentials**
- Create a dedicated non-admin DefectDojo user `smoke-pipeline` with only the import permissions it needs, and put its API v2 token in `runner.env` as `DEFECTDOJO_URL=http://127.0.0.1:<port>` and `DEFECTDOJO_TOKEN=...`. Update `vm/runner.env.example`.
- Mask the token in Actions logs (`::add-mask::`). Never echo it.

**R7. Operations**
- `vm/defectdojo/upgrade.sh` (pinned tag bump with backup first). Add a health check line to `smokectl` (e.g. `smokectl dojo-status`).
- Update `README.md`: what DefectDojo is for, team access steps for Windows users, backups and restore.

## 5. Conventions

- Bash scripts use `scripts/lib.sh` helpers (`log`, `warn`, `die`, `require`, `summary`, `out`, `export_env`, `mask`) and must pass `shellcheck -x -S warning`. Workflows must pass `actionlint` (`.github/actionlint.yaml` declares the `devsecops-gate` label).
- Pin every image and tool version. Configuration goes in `smoke.config.env` (non-secret, committed); credentials go only in `/etc/smoke-landing/runner.env`.
- Never print secret values. Scanners run with redaction.
- The operator gives commands one at a time. Put each command the operator runs in its own code block, and explain what output to expect.
- Keep commits small, on `devsecops-pipeline`.

## 6. Acceptance criteria

1. `vm/defectdojo/setup.sh` brings DefectDojo up on a fresh VM, and a second run changes nothing.
2. A gate run that **blocks** and a run that **passes** both appear in DefectDojo under product `<repo>` / engagement `smoke-gate`, with one test per tool; findings fixed in a later commit get closed.
3. With DefectDojo stopped, a gate run still passes or blocks exactly as before, with only a warning.
4. From a **build container** on the VM, the DefectDojo port is unreachable (test output included in the PR or notes).
5. A teammate with only the `grant-dojo` permission can open DefectDojo via IAP from Windows, and **cannot** SSH to the VM.
6. A backup object appears in the bucket nightly, and `restore.sh` restores it into a scratch instance.
7. No new paid subscriptions. Estimated monthly cost is stated (bucket storage only).
8. README updated; `shellcheck` and `actionlint` are clean.

## 7. Open questions for the operator

1. Which port for DefectDojo (default 8080 once Infisical is gone)?
2. Is it OK to attach a minimal backup-only service account to the VM (R5)?
3. Who needs DefectDojo access initially (emails), and with which DefectDojo roles (Reader vs Writer)?
4. Should medium (semgrep WARNING) findings be imported? (Recommended: yes, tracked but non-blocking.)
