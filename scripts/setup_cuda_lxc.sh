#!/usr/bin/env bash
set -euo pipefail

# End-to-end setup for Speaches CUDA deployment inside an Ubuntu/Debian LXC.
# What it does:
# 1) installs Docker Engine + Compose plugin
# 2) installs NVIDIA Container Toolkit and wires Docker runtime
# 3) clones/updates the Speaches repo
# 4) writes .env for production
# 5) starts Speaches with compose.cuda.yaml
#
# Usage (inside LXC as root):
#   bash scripts/setup_cuda_lxc.sh
#
# Optional env overrides:
#   REPO_URL=https://github.com/drascom/speachesTR-api.git
#   INSTALL_DIR=/opt/speachesTR-api
#   API_KEY=your-secret
#   APP_PORT=8000
#   PRELOAD_MODEL=Systran/faster-whisper-medium

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

REPO_URL="${REPO_URL:-https://github.com/drascom/speachesTR-api.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/speachesTR-api}"
APP_PORT="${APP_PORT:-8000}"
PRELOAD_MODEL="${PRELOAD_MODEL:-Systran/faster-whisper-medium}"
API_KEY="${API_KEY:-}"

log() { echo "[setup] $*"; }
warn() { echo "[warn] $*" >&2; }

if [[ -z "${API_KEY}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    API_KEY="$(openssl rand -hex 32)"
  else
    API_KEY="$(date +%s)-change-me"
    warn "openssl not found, generated weak API key placeholder."
  fi
fi

export DEBIAN_FRONTEND=noninteractive

log "Installing base packages"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release git jq

log "Installing Docker Engine + Compose plugin"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

ARCH="$(dpkg --print-architecture)"
CODENAME="$(
  . /etc/os-release
  echo "${VERSION_CODENAME}"
)"
DIST_ID="$(
  . /etc/os-release
  echo "${ID}"
)"

if [[ "${DIST_ID}" == "debian" ]]; then
  DOCKER_REPO_BASE="https://download.docker.com/linux/debian"
  DOCKER_GPG_URL="https://download.docker.com/linux/debian/gpg"
elif [[ "${DIST_ID}" == "ubuntu" ]]; then
  DOCKER_REPO_BASE="https://download.docker.com/linux/ubuntu"
  DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
else
  warn "Unsupported distro ID '${DIST_ID}'. Defaulting to Debian Docker repo."
  DOCKER_REPO_BASE="https://download.docker.com/linux/debian"
  DOCKER_GPG_URL="https://download.docker.com/linux/debian/gpg"
fi

curl -fsSL "${DOCKER_GPG_URL}" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_REPO_BASE} ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl restart docker

log "Installing NVIDIA Container Toolkit"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y --no-install-recommends nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

if command -v nvidia-smi >/dev/null 2>&1; then
  log "Host GPU visibility check (inside LXC)"
  nvidia-smi || warn "nvidia-smi exists but failed. Check LXC GPU passthrough."
else
  warn "nvidia-smi not found in LXC. GPU passthrough may be missing."
fi

log "Container runtime GPU check"
if ! docker run --rm --gpus all nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04 nvidia-smi; then
  warn "GPU test container failed. Deployment may still start but CUDA will not be usable."
fi

log "Cloning/updating repository"
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  git -C "${INSTALL_DIR}" fetch --all --prune
  git -C "${INSTALL_DIR}" checkout main || true
  git -C "${INSTALL_DIR}" pull --ff-only origin main || true
else
  git clone "${REPO_URL}" "${INSTALL_DIR}"
fi

cd "${INSTALL_DIR}"

if ! git rev-parse --verify main >/dev/null 2>&1; then
  warn "main branch not found locally; staying on current branch."
else
  git checkout main
fi

log "Writing production .env"
cat > .env <<EOF
API_KEY=${API_KEY}
ENABLE_UI=false
LOG_LEVEL=info
STT_MODEL_TTL=300
TTS_MODEL_TTL=0
VAD_MODEL_TTL=-1
WHISPER__INFERENCE_DEVICE=cuda
PRELOAD_MODELS=["${PRELOAD_MODEL}"]
UVICORN_PORT=${APP_PORT}
EOF

log "Starting Speaches with CUDA compose profile"
docker compose -f compose.cuda.yaml up -d --build

log "Waiting for health endpoint"
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${APP_PORT}/health" >/dev/null 2>&1; then
    log "Service is healthy at http://127.0.0.1:${APP_PORT}/health"
    break
  fi
  sleep 2
done

log "Installed models:"
curl -fsS "http://127.0.0.1:${APP_PORT}/v1/models" \
  -H "Authorization: Bearer ${API_KEY}" | jq . || true

cat <<EOF

Done.
API_KEY: ${API_KEY}
Install dir: ${INSTALL_DIR}
Health: http://<your-host-or-domain>/health

If GPU is not used, verify:
1) Proxmox host driver + nvidia-smi
2) LXC config has /dev/nvidia* passthrough
3) docker run --gpus all ... nvidia-smi works inside LXC
EOF
