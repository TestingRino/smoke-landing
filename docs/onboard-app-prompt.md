# Onboard this repo to smoke-landing

> Paste everything below into a Claude session opened on the app repo you want to onboard.

---

Get this repository ready for **smoke-landing**, our DevSecOps pipeline for apps under `github.com/TestingRino`. Work on a new branch and open a pull request in **this** repo. Don't merge it, and don't change anything in the `smoke-landing` repo.

## How smoke-landing treats this repo

When the operator runs `smokectl deploy <repo>`, or a new commit lands on the default branch of an opted-in repo, smoke-landing does this:

1. **Gate (blocks on any finding below):**
   - **gitleaks** scans the **entire git history** for secrets. Any secret blocks, including one that was later deleted.
   - **semgrep** (`p/default` + `p/owasp-top-ten`) runs with `nosemgrep` comments ignored. Findings with severity ERROR block; WARNING is reported only.
   - **trivy** scans the source tree (dependencies, Dockerfile/IaC misconfiguration, secrets), then the **built image**. Every **CRITICAL or HIGH** vulnerability in the image blocks, **whether or not a fix exists**. HIGH/CRITICAL Dockerfile misconfigurations block too.
   - App-side suppression files (`.gitleaksignore`, `.semgrepignore`, `.trivyignore`) are **deleted before scanning**. Exceptions live only in the smoke-landing repo, are reviewed, and expire.
   - Each blocking finding becomes a GitHub issue in this repo, labelled `smoke-gate`, and closes automatically when fixed.
2. **Build:** from `Dockerfile` (or `.smoke.yml: dockerfile:`). If there's none, Google Cloud buildpacks auto-detect Node/Python.
3. **Staging:** Cloud Run with a **public** HTTPS URL. It scales to zero, so the first request after idling takes a few seconds.
   - The container gets `PORT` (default 8080) and must listen on `0.0.0.0:$PORT`.
   - **Secrets** come from Google Secret Manager as **environment variables at runtime**. They are never in the repo or image, or in `.smoke.yml`.
   - A **smoke check** sends `GET <health_path>` and expects a 2xx/3xx response.
   - Then **OWASP ZAP** runs a passive scan. High-risk alerts revoke public access.

## What to do

### 0. Ground rules
- Never commit a secret, `.env` file or credential, not even a placeholder that looks real.
- Don't add `.gitleaksignore`, `.semgrepignore`, `.trivyignore` or `nosemgrep` comments; they're ignored anyway.
- Don't rewrite git history (no force-push).
- If something can't be fixed in this repo, report it instead of working around the gate.

### 1. Decide whether it's a web app
Find out whether this repo serves HTTP: a server, an API, a static site, or a web UI.
- **No** (library, CLI, scripts, infrastructure, docs): **stop here** and report "not a web app". The operator will add it to `policy/exclude.txt`.
- **Yes:** continue.

### 2. Container image
Add or adjust the `Dockerfile` so it does all of the following:
- [ ] Uses a **pinned** base image tag, e.g. `node:22-alpine` or `python:3.12-alpine`, never `latest`. Prefer **alpine**-based images: Debian-based ones often carry unfixed HIGH CVEs in OS packages, which block.
- [ ] Installs **production dependencies only**, from a lockfile when one exists (`npm ci --omit=dev`, `pip install --no-cache-dir -r requirements.txt`).
- [ ] **Removes package managers the app doesn't need at runtime.** The npm bundled in `node:*` images carries HIGH CVEs of its own (see the Node template).
- [ ] Runs as a **non-root** user (`USER node`, or a created user).
- [ ] Listens on `0.0.0.0:${PORT:-8080}`.
- [ ] Has a `.dockerignore` that excludes at least `.git`, `.env*`, `node_modules`, `__pycache__`, tests and local data.

Templates (adapt them, don't paste blindly):

**Node**
```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN (npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund) \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn* /usr/local/bin/yarn /usr/local/bin/yarnpkg
COPY . .
USER node
ENV PORT=8080
EXPOSE 8080
CMD ["node", "server.js"]
```
If the app has a build step (TypeScript, Vite, Next.js), use a two-stage build: build in a first stage with dev dependencies, then copy only the output and production dependencies into the final stage, and remove npm there.

**Python (Flask/Django/FastAPI)**
```dockerfile
FROM python:3.12-alpine
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN adduser -D app
USER app
ENV PORT=8080
EXPOSE 8080
# Flask/Django: gunicorn -b 0.0.0.0:$PORT app:app      FastAPI: uvicorn main:app --host 0.0.0.0 --port $PORT
CMD ["sh", "-c", "gunicorn -b 0.0.0.0:${PORT} app:app"]
```
Add `gunicorn` or `uvicorn` to `requirements.txt` if it isn't there already.

**Static site** (built HTML/JS)
```dockerfile
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY dist/ /usr/share/nginx/html/
EXPOSE 8080
```
This image listens on 8080 as a non-root user. Build `dist/` in an earlier stage if needed.

### 3. Health endpoint
- [ ] Expose a cheap `GET` route that returns 200 **without authentication and without touching the database or external APIs**, e.g. `/healthz` returning `ok`. If adding a route isn't appropriate, use a public page that always loads, such as `/`.
- [ ] Put its path in `.smoke.yml` as `health_path`.

### 4. Configuration and secrets
- [ ] List **every environment variable** the code reads (search for `process.env`, `os.environ`, `os.getenv`, `getenv`, `Settings`, `.env` loaders, and config files).
- [ ] Sort them into two groups:
  - **Non-secret** settings (log level, feature flags, public URLs): put them in `.smoke.yml` under `env:`.
  - **Secrets** (API keys, tokens, database URLs with passwords, signing keys): **don't** put them anywhere in the repo. Report only their **names**. Names must be valid env var names (letters, digits, `_`), and `PORT` and `K_*` are reserved.
  - Keys shared across many apps (e.g. one test-tier `OPENAI_API_KEY`): list them under `shared_secrets:` in `.smoke.yml` and report them separately.
- [ ] Make the app **start without optional secrets** where possible (log a warning, not a crash), so the smoke check passes before every key is added.
- [ ] If the app needs a database or other service, report what it needs. Staging gets nothing beyond what's listed in `.smoke.yml` and the secrets.

### 5. `.smoke.yml` (repo root)
Write it with only the fields that differ from the defaults:
```yaml
port: 8080              # default 8080
health_path: /healthz   # default "/"
memory: 512Mi           # default 512Mi; raise only if needed (e.g. 1Gi)
cpu: 1
max_instances: 1        # capped at 3
# dockerfile: Dockerfile   # if not at the root / not named Dockerfile
# context: .
# entrypoint: "gunicorn -b :$PORT app:app"   # ONLY when there's no Dockerfile (buildpacks)
zap: true               # set false only for non-HTML APIs where the ZAP scan is meaningless
shared_secrets: []      # e.g. [OPENAI_API_KEY]
env:                    # NON-secret settings only
  LOG_LEVEL: info
```

### 6. Pre-check what the gate will find (if Docker is available)
Use the same scanner versions as the gate:
```bash
docker run --rm -v "$PWD:/src:ro" zricethezav/gitleaks:v8.30.1 git /src --redact --no-banner
```
```bash
docker run --rm -e HOME=/tmp -v "$PWD:/src:ro" semgrep/semgrep:1.182.1 semgrep scan --config p/default --config p/owasp-top-ten --disable-nosem --metrics off --severity ERROR /src
```
```bash
docker build -t onboard-check . && docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.76.1 image --severity CRITICAL,HIGH --scanners vuln,secret onboard-check
```
```bash
docker run --rm -v "$PWD:/src:ro" aquasec/trivy:0.76.1 config --severity CRITICAL,HIGH /src
```
Then fix what you can:
- **Vulnerable dependencies:** upgrade to the fixed versions trivy reports, and keep lockfiles in sync.
- **OS package CVEs:** try a newer base tag or an alpine variant.
- **semgrep ERROR findings:** fix the code. Don't suppress them.
- **Secrets found in history:** you **cannot** fix these in this PR. Report each one (rule, file, commit) so the owner can **rotate the credential first**; afterwards, the operator adds an exception in smoke-landing.
- **HIGH/CRITICAL with no fix available:** report each one (CVE, package, why it's not reachable, if you can tell). The operator decides whether a time-boxed exception is justified.

### 7. Verify locally (if Docker is available)
```bash
docker build -t onboard-check .
```
```bash
docker run --rm -d --name onboard-check -e PORT=8080 -p 8080:8080 onboard-check && sleep 3 && curl -fsS http://localhost:8080<health_path> ; docker logs onboard-check | tail -20 ; docker rm -f onboard-check
```
```bash
docker run --rm --entrypoint id onboard-check
```
Expect the health check to return 2xx, and `id` to show a non-root uid (not `uid=0`).

### 8. Pull request and report
Open a PR in this repo titled **"Prepare for smoke-landing"** describing the changes. Then reply with this report, filled in:

```markdown
## smoke-landing onboarding: <owner/repo>
- Web app: yes/no (what it is)
- Stack / base image: …
- port: … · health_path: …
- PR: <link>

### Secrets the app needs (names only)
| Name | Purpose | Required to start? |
|---|---|---|

### Shared secrets (shared_secrets in .smoke.yml)
- …

### Pre-check results
- gitleaks (history): none / list (rule, file, commit). **Rotate these before deploying.**
- semgrep ERROR: none / fixed / remaining
- trivy image CRITICAL/HIGH: none / fixed / remaining (CVE, package, fix available?)
- trivy config HIGH/CRITICAL: none / fixed / remaining
- Not run (no Docker): …

### Needs a decision
- (unfixable CVEs, external services, anything you couldn't do)

### Operator commands (Cloud Shell, in ~/smoke-landing), after the PR is merged
bin/smokectl secret set <repo> <NAME>         # one line per secret
bin/smokectl secret set --shared <NAME>       # only if not already set
bin/smokectl deploy <repo>
bin/smokectl enable <repo>                    # optional: auto-deploy new commits
```
