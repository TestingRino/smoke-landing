#!/usr/bin/env bash
# Bootstrap the DevSecOps VM (Ubuntu 22.04/24.04, x86_64). Run as root:
#   sudo RUNNER_TOKEN=<token> CONTROL_REPO=testingrino/smoke-landing ./vm/bootstrap.sh
# RUNNER_TOKEN: control repo -> Settings -> Actions -> Runners -> New self-hosted runner (valid 1h).
# Without RUNNER_TOKEN, tools are installed and runner registration is skipped.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
CONTROL_REPO="${CONTROL_REPO:-testingrino/smoke-landing}"
RUNNER_USER=smoke
YQ_VERSION=v4.44.6
PACK_VERSION=v0.36.4

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq ca-certificates curl gnupg jq git unzip apt-transport-https unattended-upgrades

install -m 0755 -d /etc/apt/keyrings
# Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
# GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
# Google Cloud CLI
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor --yes -o /etc/apt/keyrings/cloud.google.gpg
echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list
apt-get update -q
apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh google-cloud-cli

curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
curl -fsSL "https://github.com/buildpacks/pack/releases/download/${PACK_VERSION}/pack-${PACK_VERSION}-linux.tgz" | tar -xz -C /usr/local/bin pack

cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "3" }, "live-restore": true }
EOF
systemctl restart docker

# Dedicated runner user. NOTE: docker group == root on this VM. Keep the VM single-purpose.
id "$RUNNER_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RUNNER_USER"
usermod -aG docker "$RUNNER_USER"

# VM-local credentials file (never committed, never in GitHub)
install -d -m 0750 -o root -g "$RUNNER_USER" /etc/smoke-landing
if [[ ! -f /etc/smoke-landing/runner.env ]]; then
  install -m 0640 -o root -g "$RUNNER_USER" "$(dirname "$0")/runner.env.example" /etc/smoke-landing/runner.env
  echo ">> edit /etc/smoke-landing/runner.env"
fi

# Daily docker cleanup (scanner images are re-pulled on demand)
cat > /etc/cron.daily/smoke-landing <<'EOF'
#!/bin/sh
docker system prune -af --filter "until=72h" >/dev/null 2>&1
EOF
chmod +x /etc/cron.daily/smoke-landing

# GitHub Actions runner
if [[ -n "${RUNNER_TOKEN:-}" ]]; then
  ver="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"
  dir="/home/$RUNNER_USER/actions-runner"
  sudo -u "$RUNNER_USER" mkdir -p "$dir"
  curl -fsSL "https://github.com/actions/runner/releases/download/v${ver}/actions-runner-linux-x64-${ver}.tar.gz" | sudo -u "$RUNNER_USER" tar -xz -C "$dir"
  sudo -u "$RUNNER_USER" "$dir/config.sh" --unattended --url "https://github.com/$CONTROL_REPO" --token "$RUNNER_TOKEN" \
    --name "devsecops-$(hostname)" --labels devsecops-gate --replace
  (cd "$dir" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start)
fi

# Pre-pull pinned scanner images
set -a; source "$(dirname "$0")/../smoke.config.env"; set +a
for img in "$GITLEAKS_IMAGE" "$SEMGREP_IMAGE" "$TRIVY_IMAGE" "$SYFT_IMAGE" "$ZAP_IMAGE" "$BUILDPACK_BUILDER"; do docker pull -q "$img"; done
echo "VM bootstrap complete. Next: vm/infisical/setup.sh"
