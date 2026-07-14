#!/bin/bash
set -e

# 1. Docker
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER
  echo "NOTE: you may need to log out/in for docker group to apply"
fi

# 2. kubectl
if ! command -v kubectl &> /dev/null; then
  echo "Installing kubectl..."
  KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
fi

# 3. k3d
if ! command -v k3d &> /dev/null; then
  echo "Installing k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "Docker version: $(docker --version)"
echo "kubectl version: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
echo "k3d version: $(k3d version)"