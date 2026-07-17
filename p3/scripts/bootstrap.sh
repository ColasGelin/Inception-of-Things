#!/usr/bin/env bash
set -euxo pipefail

# --- Docker ---
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker vagrant

# --- kubectl ---
if ! command -v kubectl &> /dev/null; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

# --- k3d ---
if ! command -v k3d &> /dev/null; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "Docker, kubectl, and k3d installed."
docker --version
kubectl version --client
k3d version