#!/usr/bin/env bash
set -euxo pipefail

CLUSTER_NAME="p3-cluster"

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

# --- k3d cluster (playground service is LoadBalancer:8888, published on the host) ---
if ! k3d cluster list "${CLUSTER_NAME}" &> /dev/null; then
  k3d cluster create "${CLUSTER_NAME}" -p "8888:8888@loadbalancer" --wait
fi

# share the kubeconfig with the vagrant user so `vagrant ssh` can run kubectl without sudo
mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# --- ArgoCD ---
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD deployments to become available..."
kubectl -n argocd wait --for=condition=available --timeout=300s deployment --all

# --- app namespace + ArgoCD Application ---
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f /vagrant/confs/application.yaml

echo "ArgoCD is up. Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo