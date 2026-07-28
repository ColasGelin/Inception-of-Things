#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="p3-cluster"
GITLAB_CHART_VERSION="9.9.2"

# ---------------------------------------------------------------------------
# Helper: print a timestamped phase marker so you can see where time goes
# ---------------------------------------------------------------------------
phase() {
  echo ""
  echo "============================================================"
  echo ">>> $* (elapsed: ${SECONDS}s)"
  echo "============================================================"
}

# ---------------------------------------------------------------------------
# 1. Wait for network
# ---------------------------------------------------------------------------
phase "Waiting for network"
until curl -fsSL -o /dev/null https://charts.gitlab.io/; do
  echo "Network not ready yet, retrying in 5s..."
  sleep 5
done

# ---------------------------------------------------------------------------
# 2. Swapfile  (must come before anything memory-hungry)
# ---------------------------------------------------------------------------
phase "Setting up swap"
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -h

# ---------------------------------------------------------------------------
# 3. Tooling
# ---------------------------------------------------------------------------
phase "Installing tooling"

# --- Docker ---
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker vagrant

# --- kubectl ---
if ! command -v kubectl &> /dev/null; then
  curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

# --- k3d ---
if ! command -v k3d &> /dev/null; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

# --- helm ---
if ! command -v helm &> /dev/null; then
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
  rm -f /tmp/get_helm.sh
fi

docker --version
kubectl version --client
k3d version
helm version --short

# ---------------------------------------------------------------------------
# 4. Helm repositories (do this once, up front)
# ---------------------------------------------------------------------------
phase "Adding Helm repositories"
for i in {1..5}; do
  helm repo add gitlab https://charts.gitlab.io/ && break
  echo "helm repo add gitlab failed, retrying in 5s... ($i/5)"
  sleep 5
done
helm repo add argo https://argoproj.github.io/argo-helm || true
helm repo update

# ---------------------------------------------------------------------------
# 5. k3d cluster
#    port 80  -> traefik ingress (gitlab.local / argocd.local)
#    port 8888 -> the playground LoadBalancer service
# ---------------------------------------------------------------------------
phase "Creating k3d cluster"
if ! k3d cluster list | grep -q "${CLUSTER_NAME}"; then
  k3d cluster create "${CLUSTER_NAME}" \
    -p "80:80@loadbalancer" \
    -p "8888:8888@loadbalancer" \
    --k3s-arg "--disable=metrics-server@server:0" \
    --wait
fi

# share the kubeconfig with the vagrant user so `vagrant ssh` can run kubectl
mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# ---------------------------------------------------------------------------
# 6. Namespaces (all of them up front)
# ---------------------------------------------------------------------------
phase "Creating namespaces"
for ns in gitlab argocd dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# 7. GitLab FIRST — it is by far the heaviest workload.
#    --wait blocks until every pod is actually ready, so ArgoCD is not
#    installed onto a cluster that is still thrashing.
# ---------------------------------------------------------------------------
phase "Installing GitLab (this is the slow one — expect 10-20 min)"
if ! helm status gitlab -n gitlab &> /dev/null; then
  helm upgrade --install gitlab gitlab/gitlab \
    --namespace gitlab \
    --version "${GITLAB_CHART_VERSION}" \
    --values /vagrant/confs/gitlab-values.yaml \
    --wait \
    --timeout 1200s
fi

phase "GitLab ready"
kubectl get pods -n gitlab

# ---------------------------------------------------------------------------
# 8. ArgoCD SECOND — via Helm so it gets resource requests and we can
#    switch off dex / notifications / applicationset.
# ---------------------------------------------------------------------------
phase "Installing ArgoCD"
if ! helm status argocd -n argocd &> /dev/null; then
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --values /vagrant/confs/argocd-values.yaml \
    --wait \
    --timeout 600s
fi

# --- ArgoCD CLI (optional, handy for debugging) ---
if ! command -v argocd &> /dev/null; then
  curl -sSfL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  install -m 555 /tmp/argocd /usr/local/bin/argocd
  rm -f /tmp/argocd
fi

# ---------------------------------------------------------------------------
# 9. Application manifest
# ---------------------------------------------------------------------------
phase "Applying ArgoCD Application"
kubectl apply -f /vagrant/confs/application.yaml

# ---------------------------------------------------------------------------
# 10. Summary
# ---------------------------------------------------------------------------
phase "Done"

echo ""
echo "Cluster state:"
kubectl get pods -A
echo ""
echo "ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(secret not found)"
echo ""
echo ""
echo "Total provisioning time: ${SECONDS}s"