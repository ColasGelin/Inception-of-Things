#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="p3-cluster"
GITLAB_CHART_VERSION="9.9.2"

# ---------------------------------------------------------------------------
# Helper: print a timestamped phase marker (permanent, multi-line, never
# overwritten)
# ---------------------------------------------------------------------------
phase() {
  echo ""
  echo "============================================================"
  echo ">>> $* (elapsed: ${SECONDS}s)"
  echo "============================================================"
}

# ---------------------------------------------------------------------------
# Helper: run a long command with a single-line spinner. On success the
# spinner line is replaced by a one-line "OK"; on failure it's replaced by
# a "FAILED" line followed by the captured output, so nothing is lost.
# ---------------------------------------------------------------------------
progress() {
  local msg="$1"; shift
  local logfile
  logfile=$(mktemp)
  local start=$SECONDS

  ( "$@" ) > "$logfile" 2>&1 &
  local pid=$!

  local spin='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r\033[K  %s %s (%ss)" "${spin:$i:1}" "$msg" "$((SECONDS - start))"
    sleep 0.3
  done

  wait "$pid"
  local status=$?

  if [ $status -eq 0 ]; then
    printf "\r\033[K  \xe2\x9c\x93 %s (%ss)\n" "$msg" "$((SECONDS - start))"
  else
    printf "\r\033[K  \xe2\x9c\x97 %s FAILED (%ss)\n" "$msg" "$((SECONDS - start))"
    echo "  ----- output -----"
    sed 's/^/  /' "$logfile"
    echo "  -------------------"
  fi

  rm -f "$logfile"
  return $status
}

# ---------------------------------------------------------------------------
# Helper: retry a command a few times before giving up for real.
# helm upgrade --install is idempotent, so re-running after a transient
# failure (flaky DNS mid-pull, etc.) resumes instead of restarting.
# ---------------------------------------------------------------------------
retry() {
  local attempts="$1"; shift
  local i=1
  until "$@"; do
    if [ "$i" -ge "$attempts" ]; then
      return 1
    fi
    i=$((i + 1))
    sleep 10
  done
}

# ---------------------------------------------------------------------------
# 1. Wait for network
# ---------------------------------------------------------------------------
phase "Waiting for network"
progress "Waiting for charts.gitlab.io to be reachable" bash -c '
  until curl -fsSL -o /dev/null https://charts.gitlab.io/; do
    sleep 5
  done
'

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

if ! command -v docker &> /dev/null; then
  progress "Installing Docker" bash -c 'curl -fsSL https://get.docker.com | sh'
fi
usermod -aG docker vagrant

if ! command -v kubectl &> /dev/null; then
  progress "Installing kubectl" bash -c '
    curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
  '
fi

if ! command -v k3d &> /dev/null; then
  progress "Installing k3d" bash -c 'curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash'
fi

if ! command -v helm &> /dev/null; then
  progress "Installing Helm" bash -c '
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  '
fi

docker --version
kubectl version --client
k3d version
helm version --short

# ---------------------------------------------------------------------------
# 4. Helm repositories
# ---------------------------------------------------------------------------
phase "Adding Helm repositories"
progress "Adding gitlab repo" retry 5 helm repo add gitlab https://charts.gitlab.io/
progress "Adding argo repo" retry 5 helm repo add argo https://argoproj.github.io/argo-helm
progress "Updating repos" helm repo update

# ---------------------------------------------------------------------------
# 5. k3d cluster
# ---------------------------------------------------------------------------
phase "Creating k3d cluster"
if ! k3d cluster list | grep -q "${CLUSTER_NAME}"; then
  progress "Creating k3d cluster ${CLUSTER_NAME}" k3d cluster create "${CLUSTER_NAME}" \
    -p "80:80@loadbalancer" \
    -p "8888:8888@loadbalancer" \
    --k3s-arg "--disable=metrics-server@server:0" \
    --wait
fi

mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# ---------------------------------------------------------------------------
# 6. Namespaces
# ---------------------------------------------------------------------------
phase "Creating namespaces"
for ns in gitlab argocd dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# 7. ArgoCD FIRST — lighter, fails fast if something's wrong
# ---------------------------------------------------------------------------
phase "Installing ArgoCD"
progress "Installing ArgoCD via Helm (up to 10 min)" retry 3 helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values /vagrant/confs/argocd-values.yaml \
  --wait \
  --timeout 600s

if ! command -v argocd &> /dev/null; then
  progress "Installing ArgoCD CLI" bash -c '
    curl -sSfL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    install -m 555 /tmp/argocd /usr/local/bin/argocd
    rm -f /tmp/argocd
  '
fi

# ---------------------------------------------------------------------------
# 8. GitLab SECOND — heaviest workload
# ---------------------------------------------------------------------------
phase "Installing GitLab (this is the slow one — expect 10-20 min)"
progress "Installing GitLab via Helm (up to 20 min)" retry 3 helm upgrade --install gitlab gitlab/gitlab \
  --namespace gitlab \
  --version "${GITLAB_CHART_VERSION}" \
  --values /vagrant/confs/gitlab-values.yaml \
  --wait \
  --timeout 1200s

phase "GitLab ready"
kubectl get pods -n gitlab
echo "Memory/swap usage after GitLab install:"
free -h

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