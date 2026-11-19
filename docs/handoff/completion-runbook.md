# Smoke-landing: completion runbook

**For:** the co-worker finishing setup and proving the smoke-test pipeline end to end.
**From:** the smoke-landing owner (GitHub account `TestingRino`).
**Repo:** https://github.com/TestingRino/smoke-landing (private). Work from the branch **`devsecops-pipeline`** until step 3 merges it.
**Diagram:** `docs/architecture.html` in the repo (the owner can share the published version from claude.ai).

---

## What "done" means

Any web app in a `TestingRino` repo can be pushed and then:
1. **Scanned automatically**: secrets, code, dependencies, container image. Every critical/high finding blocks and is filed as a GitHub issue.
2. **Run in staging** on Google Cloud Run with a public URL. Its API keys come from Google Secret Manager at runtime, never from the image.
3. **Released** by a person as a signed, immutable image that the corporate GitLab team can verify and pull into the boundary.

Every finding is also tracked in DefectDojo.

The **Definition of done** checklist at the end is what you hand back.

## How the pieces fit (30-second version)

```
App repo push ─▶ smoke-landing poller (every 30 min) ─▶ gate on VM ─▶ staging (Cloud Run) ─▶ release (human) ─▶ smoke-release registry ─▶ boundary GitLab pulls + verifies
                                                         │ blocked → GitHub issues + DefectDojo
```

| Thing | Where | Name |
|---|---|---|
| Control repo | GitHub | `TestingRino/smoke-landing` |
| Google Cloud project | console.cloud.google.com | `testingrino-smoke` (region `us-central1`) |
| DevSecOps VM (runner, scanners, DefectDojo) | Compute Engine | `smoke-devsecops`, zone `us-central1-a` |
| GitHub runner | on the VM | `devsecops-gate-1`, label `devsecops-gate` |
| Staging images / release images | Artifact Registry | `smoke-apps` / `smoke-release` |
| Secrets | Secret Manager | `smoke-<app>-<KEY>`, shared: `smoke-shared-<KEY>` |
| Signing key | Cloud KMS | keyring `smoke-landing`, key `artifact-signing`; public key in `keys/smoke-landing-signing.pub` |
| Findings tracker | DefectDojo on the VM | http://localhost:8088 through an IAP tunnel |
| Pipeline credentials on the VM | file | `/etc/smoke-landing/runner.env` (never commit, never paste in chat) |

## Ground rules

- Run **one command at a time** and compare against the "Expect" line before moving on.
- **Never use Cloud Shell's Web Preview** to open DefectDojo or any app UI: it corrupts requests. Use the IAP tunnel from your own machine.
- **Don't paste tokens, keys or passwords** into chats, issues or commits. They go into the password manager and `runner.env` only.
- GitHub's federation rules are **case-sensitive**: always write `TestingRino`, never `testingrino`. The *project ID* `testingrino-smoke` is lowercase, and that's correct.
- On the VM, `/home/smoke` isn't readable by your login user. Use `sudo …` with full paths.
- Lines marked **[Owner]** need the `TestingRino` GitHub account or project-owner rights. Ask the owner.

---

## 0. Get access (≈15 min)

- [ ] **[Owner]** Add you as a collaborator with **Write** on `TestingRino/smoke-landing` (Settings → Collaborators).
- [ ] **[Owner]** Give you Google Cloud access. In Cloud Shell, the owner runs:
  ```bash
  gcloud projects add-iam-policy-binding testingrino-smoke --member user:YOUR_EMAIL --role roles/owner --condition=None
  ```
  *(Owner role is the simple option for setup; reduce it after "Definition of done".)*
- [ ] Install on your machine: **Google Cloud SDK** (Windows: run the installer, then use "Google Cloud SDK Shell"), and run `gcloud auth login` once.
- [ ] Open **Cloud Shell** (console.cloud.google.com, terminal icon top right) and get the repo. If GitHub asks for a password, use `gh auth login` first:
  ```bash
  git clone --branch devsecops-pipeline https://github.com/TestingRino/smoke-landing.git ~/smoke-landing && cd ~/smoke-landing
  ```
- [ ] Get access to the team **password manager** entry for smoke-landing (DefectDojo `.env`, admin password).

## 1. Bring the infrastructure to the current design (≈1 h)

The README section **"Setting up the DevSecOps VM from scratch"** has steps **A–J** with exact commands and expected output. Some may already be done. **Check first:**

| Check | Command (Cloud Shell unless noted) | If it fails |
|---|---|---|
| VM running | `gcloud compute instances describe smoke-devsecops --zone us-central1-a --project testingrino-smoke --format='value(status)'` → `RUNNING` | README step B |
| Signing key + release registry exist | `gcloud artifacts repositories list --project testingrino-smoke --location us-central1 --format='value(name)'` → shows `smoke-apps` and `smoke-release` | re-run `./gcp/bootstrap.sh testingrino-smoke us-central1 TestingRino smoke-landing` |
| IAP rule for DefectDojo | `gcloud compute firewall-rules list --project testingrino-smoke --format='table(name,sourceRanges.list(),allowed[].map().firewall_rule().list())'` → `allow-iap-defectdojo` 35.235.240.0/20 tcp:8088, **nothing else open on 8088** | README step C |
| Runner online | GitHub → smoke-landing → Settings → Actions → Runners → `devsecops-gate-1` **Idle** | README step F |
| Token works for all repos | *(on the VM)* see §5.1 | README step D/G |
| DefectDojo healthy | *(on the VM)* `sudo /opt/defectdojo/status.sh` → `web UP`, `firewall active`, a `last-backup` | README steps H–I |

Then:
- [ ] Complete any of README steps **A–J** that failed a check above.
- [ ] Confirm the GitHub token in `runner.env` has **Contents: read, Metadata: read, Commit statuses: read & write, Issues: read & write**, *All repositories*. **[Owner]** creates or edits it (it belongs to `TestingRino`). Note its **expiry date** in the team calendar.
- [ ] `sudo /opt/defectdojo/verify-isolation.sh` on the VM: every line `PASS`. **Don't grant anyone DefectDojo access until this passes.**

## 2. Retire Infisical on the VM (≈5 min)

Infisical was the first secrets store and has been replaced by Secret Manager. It holds no app secrets. On the VM:
- [ ] ```bash
  sudo docker compose -f /home/smoke/infisical/docker-compose.yml down -v
  ```
  Expect the `infisical-*` containers and volumes removed. If it says the file doesn't exist, it's already gone.
- [ ] ```bash
  sudo rm -rf /home/smoke/infisical
  ```
- [ ] **[Owner]** Delete the Infisical `.env` entry from the password manager.

## 3. Merge `devsecops-pipeline` into `main` (≈30 min)

**Why:** Google Cloud only trusts workflows running from **`main`**, so nothing on the branch can sign or deploy until it's merged. Today `main` can scan but **can't deploy** (it still expects Infisical), so merging carries little risk.

- [ ] On GitHub: **Pull requests → New → base `main` ← compare `devsecops-pipeline`**, titled "Gate → staging → release → boundary pipeline".
- [ ] Review checklist (tick in the PR):
  - [ ] `policy/gate.env`: thresholds are what the team agreed. See **Decision D1** below before merging.
  - [ ] `smoke.config.env` has no secrets in it (IDs and names only).
  - [ ] No file contains a token, password or private key: `git grep -nE '(ghp_|github_pat_|BEGIN .*PRIVATE KEY|DD_SECRET_KEY=.+)' devsecops-pipeline` → nothing.
  - [ ] `shellcheck -x -S warning scripts/*.sh bin/smokectl vm/*.sh gcp/*.sh boundary/*.sh` and `actionlint` are clean (both are installed in Cloud Shell via `pip install shellcheck-py actionlint-py`).
- [ ] **[Owner]** approves; merge with **"Create a merge commit"**. Keep `devsecops-pipeline` for future DevSecOps work.
- [ ] On the VM, keep the local checkout on `main`, used for `vm/` scripts:
  ```bash
  cd ~/smoke-landing && git fetch origin && git checkout main && git pull
  ```

## 4. End-to-end test with a throwaway app (≈1.5 h)

Use a tiny, known app so failures point at the pipeline, not the app.

### 4.1 Create the test app

- [ ] **[Owner]** Create a **private** repo `TestingRino/smoke-hello` (collaborators can't create repos under a personal account) and add you with Write access.
- [ ] Add these four files to the repo root and commit to `main`:

`server.js`
```js
const http = require("http");
const port = process.env.PORT || 8080;
http.createServer((req, res) => {
  if (req.url === "/healthz") { res.writeHead(200); return res.end("ok"); }
  // Proves the secret arrived at runtime without ever printing it.
  const has = process.env.GREETING ? "secret present" : "no secret";
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(`smoke-hello: ${has}\n`);
}).listen(port, () => console.log(`listening on ${port}`));
```

`package.json`
```json
{ "name": "smoke-hello", "version": "1.0.0", "private": true,
  "scripts": { "start": "node server.js" }, "dependencies": {} }
```

`Dockerfile` (the `npm install` puts dependencies into the image, which is what the gate scans for CVEs; npm itself is then
removed, because the npm bundled in `node:*` images carries HIGH CVEs of its own and the app never needs it at runtime)
```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ./
RUN npm install --omit=dev --no-audit --no-fund \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn* /usr/local/bin/yarn /usr/local/bin/yarnpkg
USER node
EXPOSE 8080
CMD ["node", "server.js"]
```

`.smoke.yml`
```yaml
port: 8080
health_path: /healthz
max_instances: 1
```

### 4.2 Pass path: gate → staging

- [ ] Start it in GitHub → smoke-landing → **Actions → smoke-deploy → Run workflow**, repo `smoke-hello`. (Or in Cloud Shell: `bin/smokectl deploy smoke-hello`.)
- [ ] Expect: job **DevSecOps gate** ✅ with the gate table all `ok`, then **Staging (Cloud Run)** ✅ with "Smoke check GET /healthz → HTTP 200" and a ZAP line, then **Report status to app repo** ✅.
- [ ] The `smoke-hello` commit shows the status **"Staging live: https://smoke-smoke-hello-….run.app; ready for release"**.
- [ ] Open that URL. Expect `smoke-hello: no secret`.
- [ ] DefectDojo (tunnel open, http://localhost:8088): product **smoke-hello** with tests `gitleaks`, `semgrep`, `trivy-fs`, `trivy-image`, `zap-staging`.

> **If the gate blocks on base-image CVEs**, check where they are first. In Node images they're usually in the bundled npm
> (`brace-expansion`, `picomatch`, `pacote`, `sigstore`, `ip-address`…): removing npm, as above, clears them. Anything left in the
> OS packages (e.g. `libssl`) is **Decision D1**, not a pipeline bug: record which CVEs blocked it and stop for the decision.

### 4.3 Secrets path

- [ ] In Cloud Shell:
  ```bash
  bin/smokectl secret set smoke-hello GREETING
  ```
  Type any test value twice (hidden). Expect `Saved smoke-smoke-hello-GREETING`.
- [ ] `bin/smokectl deploy smoke-hello`, wait for green, reload the URL. Expect **`smoke-hello: secret present`**.
- [ ] Prove the value isn't in Cloud Run's config. This should show a `secretKeyRef` and **no value**:
  ```bash
  gcloud run services describe smoke-smoke-hello --region us-central1 --project testingrino-smoke --format='yaml(spec.template.spec.containers[0].env)'
  ```
- [ ] `bin/smokectl secret list smoke-hello` shows the name only.

### 4.4 Block path: findings, issues, auto-close

- [ ] In `smoke-hello`, add a file `config.js` containing a **fake** GitHub token (random, not real):
  `module.exports = { token: "ghp_Zq3vN8kP2rT6wY1uB4mX7cL9dF0hJ5sA8gE2" };`
  and change `package.json` dependencies to `{ "lodash": "4.17.15" }` (known HIGH CVEs). Commit.
  *(If GitHub push protection refuses the fake token, choose "It's used in tests" to allow it.)*
- [ ] `bin/smokectl deploy smoke-hello`. Expect the gate **⛔ BLOCKED** (secrets ≥1, vuln_high ≥1), **no staging deploy**, and commit status **"Blocked at gate: N blocking findings (see issues)"**.
- [ ] `smoke-hello` → Issues: one issue per blocking finding, labelled `smoke-gate`, `severity:*`.
- [ ] Run the same deploy again: **no duplicate issues** are created.
- [ ] Revert that commit (delete `config.js`, remove lodash), deploy again. Expect the lodash issues **closed automatically** with a "No longer detected" comment; the secret still blocks (next step).
- [ ] The fake token stays in git **history**, and gitleaks scans history, so the run after the revert **still blocks** on that one secret. That's expected. Copy its fingerprint from the secret's issue (the line `gitleaks fingerprint: …`) into `policy/exceptions/smoke-hello/gitleaksignore` in smoke-landing, with a comment saying it's a fake test token, through a PR to `main`. Once merged, deploy again: expect pass and the issues closed. This also exercises the exception process.

### 4.5 Release path

- [ ] Take the passing commit SHA from 4.4 and run:
  ```bash
  bin/smokectl release smoke-hello <sha> "E2E test of release path"
  ```
- [ ] Expect the **smoke-release** run (Verify & promote) ✅; its summary prints a **boundary reference** `us-central1-docker.pkg.dev/testingrino-smoke/smoke-release/smoke-hello@sha256:…`. Commit status `smoke-landing/release` ✅.
- [ ] **Negative test:** release the **blocked** SHA from 4.4. Expect the run to **fail** with "Release refused: no SIGNED staging image … (did the gate pass for this commit?)": a blocked commit is never pushed or signed.
- [ ] Verify the signature yourself in Cloud Shell. The README section "Release and the boundary" has the three commands (install cosign, configure docker, `cosign verify`). Expect "The following checks were performed" and the same `sha256:` digest.

### 4.6 Boundary dry run (with the GitLab team, ≈1 h)

- [ ] **[Owner]** Create the read-only pull key for the boundary. The exact command is printed at the end of `gcp/bootstrap.sh`. Hand it to the GitLab team **through the password manager**; it becomes a **masked, protected** GitLab CI variable. Set a 90-day rotation reminder.
- [ ] Give the GitLab team the `boundary/` folder, `keys/smoke-landing-signing.pub` and `boundary/README.md`.
- [ ] With them, run `boundary/verify-and-import.sh` against the reference from 4.5. Expect it to pass.
- [ ] **Tamper tests:** each one must **fail**:
  - an unsigned image, e.g. `docker.io/library/nginx@sha256:…`
  - the staging image of the blocked SHA
  - a release reference with the `@sha256` changed by one character
- [ ] Confirm podman on their VM refuses an unsigned image (`boundary/podman/policy.json`).
- [ ] Record their GitLab tier (Free/Premium) and who the **approvers** are.

### 4.7 Clean up the test

- [ ] `bin/smokectl teardown smoke-hello`. Expect the service gone from `bin/smokectl status`. Secrets and the released image stay, by design.
- [ ] **[Owner]** Archive `smoke-hello` or keep it as the standing canary app. Recommended: keep it, and re-run 4.2 after every pipeline change.

## 5. Onboard all TestingRino repos (≈1–2 h + waiting)

### 5.1 Inventory and access check (on the VM)

- [ ] List every repo and confirm the token can read each one. Every line should say `OK`:
  ```bash
  sudo -u smoke bash -c 'source /etc/smoke-landing/runner.env && export GH_TOKEN="$GH_APPS_TOKEN" && for r in $(gh repo list TestingRino --no-archived --limit 300 --json name --jq ".[].name"); do if gh api "repos/TestingRino/$r/commits?per_page=1" --silent 2>/dev/null; then echo "OK    $r"; else echo "FAIL  $r"; fi; done'
  ```
  `FAIL` on an **empty** repo is fine. `FAIL` on a real repo means the token isn't set to "All repositories".

### 5.2 Sort the repos

Fill this table (a sheet is fine):

| Repo | Web app? (serves HTTP) | Dockerfile? | Port / health path | Needs secrets (names only) | Owner of the app |
|---|---|---|---|---|---|

- [ ] Repos that **aren't web apps** (libraries, scripts, docs, infrastructure) go in `policy/exclude.txt` via PR, one name per line.
- [ ] For each web app, add a `.smoke.yml` (copy `examples/.smoke.yml`) to **the app repo** via PR: set `port`, `health_path`, and, for Python without a Dockerfile, `entrypoint` (e.g. `gunicorn -b :$PORT app:app`).
- [ ] For each secret an app needs: `bin/smokectl secret set <repo> KEY`. Keys shared by many apps (e.g. one test-tier `OPENAI_API_KEY`): `bin/smokectl secret set --shared KEY`, and list the key under `shared_secrets:` in that app's `.smoke.yml`. **Use test-tier keys with spend limits only**: staging URLs are public.

### 5.3 Turn it on

- [ ] PR to `main`: in `smoke.config.env` set `ALL_REPOS="true"`. **[Owner]** merges.
- [ ] The poller (Actions → smoke-poll, every 30 min, max 5 repos per run) starts dispatching. Watch the first two cycles in Actions. There's one runner, and each run takes about 10–15 min, so a large backlog takes hours. That's expected.
- [ ] For each repo, the latest commit gets a ✅ or ❌ status. Blocked repos get issues. Send each app's owner a note: *"smoke-landing filed issues in your repo; fix or request an exception."*
- [ ] Repos that fail at **staging** (not the gate) almost always need `.smoke.yml` fixes (wrong port or health path). Fix those, then `bin/smokectl deploy <repo>`.

## 6. Team access (≈15 min per person)

- [ ] DefectDojo login: on the VM, `sudo /opt/defectdojo/add-user.sh <email>` prints a one-time password. Send it privately.
- [ ] DefectDojo tunnel: `bin/smokectl grant-dojo <email>` (port 8088 only, no SSH).
- [ ] People who add API keys: `bin/smokectl grant-secrets <email>` (can add and rotate, **can't read**).
- [ ] People who promote releases need **Write** on `smoke-landing` (**[Owner]**). Once there are at least 2, set `RELEASE_REQUIRE_DIFFERENT_APPROVER="true"` in `smoke.config.env` via PR.

## 7. Operations to hand back

- [ ] Calendar reminders: **GitHub token expiry** (all deploys stop when it expires), **boundary pull-key rotation** (90 days), **monthly scanner version review** (image tags in `smoke.config.env`).
- [ ] Check the nightly DefectDojo backup once: `gcloud storage ls gs://testingrino-smoke-dojo-backups/defectdojo/` shows a folder for last night. Run one test restore with `--scratch` (README "DefectDojo").
- [ ] Billing alert on project `testingrino-smoke` (Billing → Budgets & alerts), e.g. $150/month at 50/90/100%. The expected baseline is about $100/month for the VM plus a few dollars for everything else.
- [ ] The janitor (Actions → smoke-teardown, daily) removes staging apps idle for 14 days. Confirm after the first run that only stale apps were removed.

---

## Decisions to get from the owner (flag them, don't decide alone)

| ID | Question | Why it matters | Suggested default |
|---|---|---|---|
| **D1** | Should **HIGH CVEs with no fix available** block? (`VULN_COUNT_UNFIXED` in `policy/gate.env`, currently `true`) | Most base images carry a few unfixed HIGHs, so `true` may block nearly every app until each gets a dated exception | Keep `true` for the boundary's sake, but standardise on slim bases (`*-alpine`, distroless) and allow 30–90-day exceptions |
| D2 | Who are the **release approvers** outside, and the **boundary approvers** inside? | Two-person control is the core safeguard | At least 2 people outside, and different people inside |
| D3 | Replace the personal GitHub token with a **GitHub App** (free) | The token expires and is tied to one person | Yes, after "done" |
| D4 | Add a **second runner** if the backlog is slow | One runner works through runs one at a time | Only if the queue regularly exceeds a few hours |
| D5 | Reduce your temporary **Owner** role | Least privilege | After handing back |

## Known limits (expected, not bugs)

- **GitHub Free plan:** no branch protection or required reviewers on private repos, so the "PR review" of `policy/` and workflows is a team habit, not enforced. The binding control is the boundary's own approval.
- **Inline `gitleaks:allow` comments** in app code still suppress findings. Reviewers should watch for them.
- **Staging URLs are public:** test data and test-tier keys only.
- **DefectDojo open source has no read-only role:** everyone you add can triage, but not delete or configure.

## Definition of done (hand this back)

- [ ] §1: every check passes; `verify-isolation.sh` all PASS.
- [ ] §2: Infisical removed.
- [ ] §3: `devsecops-pipeline` merged to `main`; PR link: ______
- [ ] §4: E2E evidence (Actions run links): pass ____ · secrets ____ · block ____ · auto-close ____ · release ____ · release-of-blocked fails ____ · boundary verify ____ · tamper tests fail ____
- [ ] §5: `ALL_REPOS="true"` live; inventory table attached; N repos green, M blocked with issues, K excluded.
- [ ] §6: team members granted (list).
- [ ] §7: reminders set; backup listed; restore tested; budget alert on.
- [ ] Decisions D1–D5 answered by the owner (or explicitly deferred).
