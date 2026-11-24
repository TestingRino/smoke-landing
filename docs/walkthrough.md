# Smoke-Landing: presenter walkthrough

A click-by-click script for demonstrating the smoke-test and landing system: what it's for, how a commit moves through it, and how a new app is onboarded. About **45 minutes**, or **20** if you skip Parts 6, 8 and 10.

**How to read this:** **Click** = what you do. **Shows** = what the audience sees. **Say** = the talking point. Names in `code` are the real names in our setup; the example app is **Scribe** (`TestingRino/Scribe`).

---

## Before you present (15 minutes earlier)

Open these browser tabs, in this order:

| # | Tab | Address |
|---|---|---|
| 1 | Architecture diagram | the published *Smoke-Landing Pipeline Map* (claude.ai), or `docs/architecture.html` in the repo |
| 2 | Control repo | https://github.com/TestingRino/smoke-landing |
| 3 | Example app repo | https://github.com/TestingRino/Scribe |
| 4 | Google Cloud console | https://console.cloud.google.com/run?project=testingrino-smoke |
| 5 | DefectDojo | http://localhost:8088 (needs the tunnel below) |
| 6 | Cloud Shell | the terminal icon at the top right of the console, then `cd ~/smoke-landing && git pull` |

Then:
- [ ] **Start the DefectDojo tunnel** on your own machine. In "Google Cloud SDK Shell", run this and leave the window open:
  ```bash
  gcloud compute start-iap-tunnel smoke-devsecops 8088 --local-host-port=localhost:8088 --zone us-central1-a --project testingrino-smoke
  ```
  Log in at http://localhost:8088. **Never use Cloud Shell's "Web Preview"** for this; it breaks the page.
- [ ] **Have one green run and one blocked run** in the Actions history to show (Part 3 can then be live *or* pre-recorded). A full run takes about 10–15 minutes, so start one now if you want a fresh result: Actions → smoke-deploy → Run workflow → `Scribe`.
- [ ] **Check the runner is online:** smoke-landing → Settings → Actions → Runners → `devsecops-gate-1` shows **Idle**.
- [ ] Wake the staging app so it answers instantly: open its URL once (Part 5 shows where). Cloud Run scales to zero when idle.

> **Don't show on screen:** `/etc/smoke-landing/runner.env`, `/opt/defectdojo/.env`, the password manager, or any secret value. Nothing in this script needs them.

---

## Part 1: Why this exists (3 min)

**Click:** Tab 1 (architecture diagram).
**Shows:** GitHub on the left, the Google Cloud project in the middle, the corporate boundary on the right.

**Say:**
- "We build apps quickly with Claude **outside** the corporate boundary, in GitHub repos under `TestingRino`. Before any of that code is allowed **inside**, it has to prove two things: that it's **safe** (no leaked secrets, no critical or high vulnerabilities) and that it **works** (it runs live with real keys and answers requests)."
- "Smoke-landing is the checkpoint that proves both, automatically, for every repo, and produces a **signed, tamper-evident package** that the corporate side can verify for itself."
- Point at the accent-colored arrow: "This is the **only** way in. The boundary **pulls** from one registry that holds only signed images a person approved. Nothing outside can push into the boundary."
- "There are **two human approvals**: one here to release, and one inside the boundary by someone who didn't write the code."

## Part 2: The control room, the smoke-landing repo (4 min)

**Click:** Tab 2 → **Code** tab.
**Shows:** the folders.
**Say:** "One private repo runs the whole system. Nothing has to be installed in the app repos."

| Folder or file | One-line explanation |
|---|---|
| `.github/workflows/` | the four automations: **deploy**, **poll**, **release**, **teardown** |
| `policy/gate.env` | the security bar: *every critical and high finding blocks* |
| `policy/exceptions/` | reviewed, time-boxed waivers, **kept here, not in the app repos** |
| `smoke.config.env` | non-secret settings (project, registries, which repos are enrolled) |
| `boundary/` | the kit we hand the corporate GitLab team |
| `docs/` | diagram, runbooks, the onboarding guide |

**Click:** `policy` → `gate.env`.
**Say:** "Plain text, reviewed like code. Secrets in git history, high-severity code issues, critical or high vulnerabilities in the built image, high-risk Dockerfile misconfigurations: any of these stops the deploy."

**Click:** `policy` → `exceptions` → `Scribe` → `gitleaksignore`.
**Shows:** commented lines such as *"test fixtures… none of these is a live credential"* and *"merge only after the SAM.gov key has been rotated"*.
**Say:** "When a finding is a false positive, the exception goes **here**, with a reason, through a pull request. The app team can't waive its own findings: the gate deletes any ignore files in the app repo before scanning."

**Click:** **Actions** tab.
**Shows:** four workflows in the left list: `smoke-deploy`, `smoke-poll`, `smoke-release`, `smoke-teardown`.
**Say:** "`smoke-poll` runs every 30 minutes and picks up new commits on enrolled repos. `smoke-deploy` is the gate plus staging. `smoke-release` is the human promotion. `smoke-teardown` cleans up staging apps idle for 14 days."

**Click:** **Settings** → **Actions** → **Runners**.
**Shows:** `devsecops-gate-1`, **Idle**, label `devsecops-gate`.
**Say:** "The actual work runs on our own VM in Google Cloud, `smoke-devsecops`, not on GitHub's servers. Scanners, builds and the findings tracker all live there."

## Part 3: Run the gate (8 min, live or from history)

**Click:** **Actions** → **smoke-deploy** (left list) → **Run workflow** (button on the right).
**Shows:** a form: *Use workflow from: main*, **repo**, **ref**.
**Click:** type `Scribe` in **repo**, leave **ref** empty (= its default branch) → green **Run workflow**.
**Say:** "Anyone with access can trigger this by hand. Normally nobody does, because the poller does it on every new commit."

**Click:** the new run at the top of the list.
**Shows:** three boxes: **DevSecOps gate** → **Staging (Cloud Run)** → **Report status to app repo**.
**Say:** "Three stages. If the gate blocks, staging never happens."

**Click:** **DevSecOps gate** (open a finished run if this one is still going).
**Shows:** steps: resolve and clone, source scans, build image, image scan + SBOM, evaluate policy, file GitHub issues, record findings in DefectDojo, push image, sign & attest.
**Say, step by step:**
- "**Source scans:** gitleaks searches the **entire git history** for secrets, semgrep looks for insecure code, trivy checks dependencies and the Dockerfile."
- "**Build image:** the image is built **once**. The exact bytes we scan are the bytes we run and later release."
- "**Image scan + SBOM:** a full vulnerability scan of the built image, plus a parts list (SBOM) the corporate side can keep."
- "**Sign & attest:** the image is signed with a key held in Google Cloud KMS. Nobody, including us, can copy that key. The scan results are attached to the image as signed statements."

**Click:** **Summary** (top left of the run).
**Shows:** the gate table (Check · Count · Limit · Result) and, on a blocked run, collapsible findings lists.
**Say:** "Here's the verdict. Green means zero blocking findings. Medium findings are listed but don't block; they go to the tracker."

**Click:** scroll to **Artifacts** at the bottom of the Summary.
**Shows:** `gate-reports` (raw scanner output, findings list, SBOM), and `dast-report` once staging has run.
**Say:** "Every run keeps its evidence for 30 days."

**Show a blocked run (from history):** open a red `smoke-deploy` run → **Summary**.
**Say:** "Blocked runs stop here. Nothing reaches staging, and the developers get told exactly what to fix: that's next."

## Part 4: What the developer sees (4 min)

**Click:** Tab 3 (Scribe) → **commits** (the clock icon with the commit count, above the file list).
**Shows:** a ✓ or ✗ next to each commit.
**Click:** the ✓/✗ on the latest commit.
**Shows:** check **smoke-landing/gate**, with text like *"Staging live: https://…run.app; ready for release"* or *"Blocked at gate: N blocking findings (see issues)"*.
**Say:** "Developers never need to visit smoke-landing. The result shows up on their own commit."

**Click:** **Issues** tab → **Labels** → `smoke-gate`, or filter `label:smoke-gate`.
**Shows:** issues titled like `[smoke-gate] HIGH CVE-… in <package>`, with severity labels.
**Click:** one issue.
**Shows:** severity, location, first-seen commit, a link to the gate run, and how to request an exception.
**Say:**
- "One issue per blocking finding, **never duplicated**. When a later commit fixes it, the gate **closes the issue itself** with a comment. Show a closed one if you have it: filter `is:closed label:smoke-gate`."
- "For public repos, secret findings are filed **without details**, so we don't advertise a leaked key."

## Part 5: Staging in Google Cloud (6 min)

**Click:** Tab 4 → **Cloud Run** → **Services**.
**Shows:** services named `smoke-<app>` (Scribe → `smoke-scribe`), each with a region and URL.
**Click:** `smoke-scribe` → the **URL** at the top.
**Shows:** the live app in a new tab.
**Say:** "Every app that passes the gate gets a public test URL automatically. That's the 'smoke test': it really runs, and we've hit its health check and passively scanned it with OWASP ZAP."

**Click:** back in the service → **Revisions** → newest revision → in the right panel, **Containers** → **Variables & Secrets** (or the **YAML** tab).
**Shows:** API keys listed as **secret references** (`smoke-scribe-<KEY>:latest`), **no values**.
**Say:** "Keys are injected **when the app starts**, from Secret Manager. They're never in the code, never in the image, never in the package that crosses into the boundary. The boundary uses **its own** production keys."

**Click:** ☰ menu → **Security** → **Secret Manager**.
**Shows:** secrets named `smoke-<app>-<KEY>`, plus `smoke-shared-<KEY>` for keys many apps share.
**Say:** "Teammates can be allowed to **add or rotate** keys without being able to **read** them. Each app's runtime identity can only read its own keys."
*(Don't click into a secret's versions.)*

**Click:** ☰ → **Artifact Registry** → **Repositories**.
**Shows:** `smoke-apps` (staging) and `smoke-release` (released).
**Click:** `smoke-apps` → `scribe`.
**Shows:** image digests, tagged with the commit (12 characters), plus `sha256-….sig` / `.att` entries.
**Say:** "Those extra entries are the signature and the signed statements: the scan result, the build record, the SBOM and the staging result, all bound to this exact image."

**Click (optional):** ☰ → **Security** → **Key Management** → `smoke-landing` → `artifact-signing`.
**Say:** "The signing key. The private half never leaves Google's key service. The public half is in our repo at `keys/smoke-landing-signing.pub`, and the boundary pins it."

## Part 6: The findings tracker, DefectDojo (4 min)

**Click:** Tab 5 (http://localhost:8088).
**Shows:** the DefectDojo dashboard.
**Say:** "This runs on our VM and is reachable only through a Google IAP tunnel to this one port: no SSH and no public address. People get access with one command (`smokectl grant-dojo <email>`)."

**Click:** **Products** (left menu) → product type `smoke-landing` → **Scribe**.
**Shows:** engagement `smoke-gate`, with one test per tool: `gitleaks`, `semgrep`, `trivy-fs`, `trivy-image`, `zap-staging`.
**Click:** a test → its findings.
**Say:**
- "Every run re-imports here, so this is the **history**: what's new, what got fixed, triage notes. Medium findings that don't block are tracked here."
- "**DefectDojo is not the gate.** Marking something 'accepted' here doesn't unblock anything; only a reviewed exception file in smoke-landing does. If DefectDojo is down, the gate still works."

## Part 7: Release, the first human approval (5 min)

**Click:** Tab 2 → **Actions** → **smoke-release** → **Run workflow**.
**Shows:** inputs **repo**, **commit**, **justification**.
**Click:** `Scribe`, the commit SHA from a **green** run (copy it from Scribe's commit list), and a justification such as "Q4 pilot for records team" → **Run workflow**. *(Do this only if you mean to release; otherwise show a previous release run.)*
**Say:** "A person decides what goes to the corporate side, and why. That's recorded in a signed release statement along with who approved it."

**Click:** the run → **Verify & promote** → **Summary**.
**Shows:** verification steps, then the **boundary reference**:
`us-central1-docker.pkg.dev/testingrino-smoke/smoke-release/scribe@sha256:…`
**Say:**
- "The release **fails closed**. It refuses unless this exact image is signed by our key, has a passing gate result for that commit, and passed staging recently. Trying to release a blocked commit fails."
- "It copies the image, **with its signatures**, to `smoke-release`: the only place the boundary can read."
- "That `@sha256:` reference is what we hand to the boundary team. It names exactly one image and can't be swapped."

**Click:** Tab 3 → Scribe commit ✓ → a second check, **smoke-landing/release**, now appears.

## Part 8: Inside the boundary (3 min, described)

**Click:** Tab 2 → `boundary/` → `README.md`, or the GitLab pipeline if the boundary team is demoing.
**Shows (GitLab pipeline):** stages **verify → rescan → approve (▶ manual) → import → deploy**.
**Say:**
- "**Verify:** the boundary checks the signature against the public key they pinned, plus all the signed statements: gate passed, staging passed, a release was approved, and the source repo is the one expected. Any mismatch stops it."
- "**Rescan:** they rescan with **their own** tools. They don't take our word for it."
- "**Approve:** a corporate approver presses ▶, and it can't be the person who started the pipeline. That's the **second** human approval, and the binding one."
- "**Import → deploy:** copied by digest into their internal registry, and run with podman, which **refuses any unsigned image**."

## Part 9: Onboarding a new app (8 min)

**Say first:** "Onboarding is five steps, and the first one is mostly done by Claude."

**Step 1: Prepare the app repo (Claude does the work)**
**Click:** Tab 2 → `docs/onboard-app-prompt.md` → **Copy raw file** (the copy icon above the file).
**Click:** open a Claude Code session **on the app repo** → paste → send.
**Shows (result):** a pull request in the app repo titled **"Prepare for smoke-landing"**, plus a report.
**Say:** "Claude checks whether it's even a web app (if not, we exclude it). Then it adds a hardened, non-root Dockerfile, a health endpoint, and a small `.smoke.yml` settings file. It pre-runs the same scanners the gate uses, and it lists the **names** of the secrets the app needs, never their values."

**Step 2: Review and merge that PR** in the app repo, as for any change.
*(If it's not a web app: PR to smoke-landing adding the repo name to `policy/exclude.txt`.)*

**Step 3: Add the app's keys**
**Click:** Tab 6 (Cloud Shell), one command per key from the report:
```bash
bin/smokectl secret set Scribe OPENAI_API_KEY
```
**Shows:** a hidden prompt (type the value twice), then *"Saved smoke-scribe-OPENAI_API_KEY"*.
**Say:** "Test-tier keys with spend limits only: staging URLs are public. A key many apps share goes in once with `--shared`, and apps opt in through `.smoke.yml`."
*(Console alternative: Secret Manager → **+ Create secret**, name `smoke-<app>-<KEY>`, label `smoke-app` = `<app>`. The command is quicker and gets the naming right.)*

**Step 4: First run**
**Click:** Actions → **smoke-deploy** → **Run workflow** → repo name → **Run workflow**. Same as Part 3.
**Then, depending on the result:**
- **Green:** the app is live in staging. Share the URL with testers.
- **Blocked:** the app team fixes the issues filed in their repo. A false positive or an unfixable CVE becomes a **PR to `policy/exceptions/<App>/`** with a reason and an expiry date, as for Scribe in Part 2.
- **Staging failed (gate was green):** almost always the port or health path in `.smoke.yml`.

**Step 5: Turn on automatic deploys**
**Click:** Tab 3 (the app repo) → home page → the ⚙ gear next to **About** (right side) → **Topics** → type `smoke-deploy` → **Save changes**.
**Say:** "From now on, every new commit on the default branch is gated and staged within 30 minutes, with no further clicks." *(Same thing from Cloud Shell: `bin/smokectl enable Scribe`.)*

**Close the loop:** "When the team is happy with staging, they ask for a **release**, as in Part 7, and hand the boundary reference to the corporate team."

## Part 10: Day-to-day (2 min)

In Cloud Shell (`~/smoke-landing`):
```bash
bin/smokectl status
```
Lists every live staging app, its commit and URL. Other commands to mention:

| Command | What it does |
|---|---|
| `bin/smokectl runs Scribe` | recent pipeline runs for one app |
| `bin/smokectl releases Scribe` | what's been released, with boundary references |
| `bin/smokectl secret list Scribe` | key **names** and dates, never values |
| `bin/smokectl grant-secrets <email>` | allow someone to add/rotate keys without reading them |
| `bin/smokectl grant-dojo <email>` | DefectDojo access (port 8088 only, no SSH) |
| `bin/smokectl teardown Scribe` | remove the staging app (keys and releases are kept) |

**Say:** "Idle staging apps are removed automatically after 14 days. DefectDojo is backed up nightly to a locked Cloud Storage bucket."

---

## Likely questions (crib sheet)

| Question | Answer |
|---|---|
| *Why not let the boundary pull straight from a GitHub branch?* | A branch can move after review, and someone with write access, or a stolen token, can change what it points to. We hand over an **image digest**: exact bytes, signed, with the scan results attached. |
| *What stops someone skipping the gate?* | The boundary checks the **signature and signed statements** itself, and podman refuses unsigned images. A package that didn't go through the gate can't be signed with our key: only the pipeline can use it. |
| *Where are the API keys?* | Google Secret Manager, injected into staging at runtime. Never in code, images or the package that crosses. The boundary uses its own keys. |
| *What if a vulnerability has no fix yet?* | It still blocks. The team can request a **time-boxed exception** (with an expiry date) via a PR to smoke-landing, reviewed like code. |
| *Can app teams waive their own findings?* | No. Ignore files in app repos are deleted before scanning, and inline `nosemgrep` comments are ignored. Exceptions live only in smoke-landing. (Known gap: inline `gitleaks:allow` comments still work, so reviewers watch for them.) |
| *Who can release?* | People with write access to smoke-landing. The approver and reason are recorded in the signed release. The binding approval is the boundary's, by someone other than the author. |
| *Is staging safe to share?* | URLs are public by design, for testers. Use test data and test-tier keys. If ZAP finds a high-risk issue, public access is revoked automatically. |
| *What does it cost?* | About $100/month for the VM. Everything else (Cloud Run scaled to zero, registries, Secret Manager, KMS, backups) is a few dollars. No subscriptions. |
| *What if DefectDojo or GitHub issues break?* | The gate's verdict doesn't depend on either. You'd see a warning in the run, and the block/pass decision is unchanged. |
| *Can repos from other GitHub accounts join?* | Not yet. Today it's every repo under `TestingRino`. Multi-account support is planned via a GitHub App. |

## Reference

| Thing | Where |
|---|---|
| Control repo | https://github.com/TestingRino/smoke-landing |
| Google Cloud project | `testingrino-smoke` (region `us-central1`) |
| VM / runner | `smoke-devsecops` (zone `us-central1-a`) / `devsecops-gate-1` |
| Staging service name | `smoke-<app>` (lowercase, e.g. `smoke-scribe`) |
| Secret names | `smoke-<app>-<KEY>` · shared: `smoke-shared-<KEY>` |
| Registries | `smoke-apps` (staging) · `smoke-release` (boundary reads this) |
| DefectDojo | http://localhost:8088 through the IAP tunnel |
| Onboarding guide for app repos | `docs/onboard-app-prompt.md` |
| Setup and operations | `README.md` · `docs/handoff/completion-runbook.md` |
