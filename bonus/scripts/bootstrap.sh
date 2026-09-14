#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="p3-cluster"
GITLAB_CHART_VERSION="10.3.2"

# --- GitOps / GitLab settings ----------------------------------------------
GITLAB_PROJECT_PATH="playground"
GITLAB_LOCAL_PORT=8090
GITLAB_LOCAL_URL="http://localhost:${GITLAB_LOCAL_PORT}"
# Port 8181 = Workhorse. Rails on 8080 serves the API but REJECTS git-over-HTTP
# ("Nil JSON web token"), so 8181 is the only port that works for both.
GITLAB_INTERNAL_HOST="gitlab-webservice-default.gitlab.svc.cluster.local:8181"
GITLAB_INTERNAL_REPO="http://${GITLAB_INTERNAL_HOST}/root/${GITLAB_PROJECT_PATH}.git"
APP_IMAGE_REPO="wil42/playground"
# Must match the images in confs/gitlab-deps.yaml
POSTGRES_IMAGE="postgres:17-alpine"
REDIS_IMAGE="redis:7.2-alpine"
WORK_CLONE="/home/vagrant/${GITLAB_PROJECT_PATH}"

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

  # Under `set -e` a bare failing `wait` would exit right here, before the
  # FAILED line and the captured output get printed.
  local status=0
  wait "$pid" || status=$?

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
if ! command -v curl &> /dev/null; then
  apt-get update -qq && apt-get install -y -qq curl
fi
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

if ! command -v git &> /dev/null; then
  progress "Installing git" bash -c 'apt-get update -qq && apt-get install -y -qq git'
fi

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
# 6. Pre-import images
#
# Pull on the HOST and side-load into the k3d nodes so the kubelet never has to
# reach Docker Hub. With GitLab running this VM is memory-starved, CoreDNS gets
# flaky, and in-cluster image pulls fail with "lookup registry-1.docker.io:
# Try again". Importing both app tags up front makes the v1 -> v2 demo immune to
# that (and to Docker Hub rate limits); the datastore images get the same
# treatment so a restarted PostgreSQL/Redis pod never needs the network.
# ---------------------------------------------------------------------------
phase "Pre-importing images"
IMAGES=("${APP_IMAGE_REPO}:v1" "${APP_IMAGE_REPO}:v2" "${POSTGRES_IMAGE}" "${REDIS_IMAGE}")
for image in "${IMAGES[@]}"; do
  progress "Pulling ${image}" retry 3 docker pull "${image}"
done
progress "Importing images into k3d" k3d image import "${IMAGES[@]}" -c "${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 7. Namespaces
# ---------------------------------------------------------------------------
phase "Creating namespaces"
for ns in gitlab argocd dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# 8. ArgoCD FIRST — lighter, fails fast if something's wrong
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
# 9. PostgreSQL + Redis for GitLab
#
# Since chart 10.0 (GitLab 19.0) the GitLab chart no longer bundles its
# datastores, so we run one small instance of each from confs/gitlab-deps.yaml.
# Passwords are generated once and never replaced: PostgreSQL only reads
# POSTGRES_PASSWORD when it initialises its volume, so a rerun with a new
# Secret would lock GitLab out of its own database.
# ---------------------------------------------------------------------------
phase "Deploying PostgreSQL and Redis"

random_secret() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }

if ! kubectl get secret gitlab-postgresql-password -n gitlab &> /dev/null; then
  kubectl create secret generic gitlab-postgresql-password -n gitlab \
    --from-literal=postgresql-password="$(random_secret)"
fi
if ! kubectl get secret gitlab-redis-secret -n gitlab &> /dev/null; then
  kubectl create secret generic gitlab-redis-secret -n gitlab \
    --from-literal=secret="$(random_secret)"
fi

kubectl apply -f /vagrant/confs/gitlab-deps.yaml
progress "Waiting for PostgreSQL" kubectl rollout status deployment/postgresql -n gitlab --timeout=600s
progress "Waiting for Redis" kubectl rollout status deployment/redis -n gitlab --timeout=300s

# ---------------------------------------------------------------------------
# 10. GitLab SECOND — heaviest workload
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
# 11. GitLab project: token, project creation, manifest push
#
# The API calls and the push go through ONE kubectl port-forward. The VM is not
# on the pod network, so it cannot resolve *.svc.cluster.local — the tunnel is
# how we reach GitLab from here. ArgoCD itself IS in the cluster, so it uses the
# internal DNS name directly (see step 12).
# ---------------------------------------------------------------------------
phase "Setting up GitLab project"

GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath='{.data.password}' | base64 -d)

kubectl port-forward -n gitlab svc/gitlab-webservice-default \
  "${GITLAB_LOCAL_PORT}:8181" &> /tmp/gitlab-port-forward.log &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

# Rails answers 401 on /api/v4/version once it is booted; a connection error or
# 502 means it is still starting. 401 is therefore our readiness signal.
progress "Waiting for GitLab API through tunnel" bash -c "
  until [ \"\$(curl -s -o /dev/null -w '%{http_code}' '${GITLAB_LOCAL_URL}/api/v4/version' || true)\" = '401' ]; do
    sleep 5
  done
"

# GitLab 19 removed the OAuth password grant, so the root password can no longer
# be traded for an API token. Instead, register a token we generate ourselves
# with the Rails runner inside the toolbox pod — the documented way to create
# tokens programmatically. The token must be exactly 20 characters.
GITLAB_PAT=$(od -An -tx1 -N10 /dev/urandom | tr -d ' \n')
progress "Creating personal access token" kubectl exec -n gitlab deploy/gitlab-toolbox -- \
  gitlab-rails runner "
    token = User.find_by_username('root').personal_access_tokens.create(
      scopes: ['api', 'read_repository', 'write_repository'],
      name: 'argocd',
      expires_at: 365.days.from_now)
    token.set_token('${GITLAB_PAT}')
    token.save!
  "
echo "  token acquired: ${GITLAB_PAT:0:6}..."

# Create the project only if it does not already exist (idempotent reruns)
PROJECT_HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
  "${GITLAB_LOCAL_URL}/api/v4/projects/root%2F${GITLAB_PROJECT_PATH}" || true)

if [ "${PROJECT_HTTP}" = "200" ]; then
  echo "  project root/${GITLAB_PROJECT_PATH} already exists"
else
  progress "Creating project root/${GITLAB_PROJECT_PATH}" bash -c "
    curl -fsS -o /dev/null -X POST '${GITLAB_LOCAL_URL}/api/v4/projects' \
      -H 'PRIVATE-TOKEN: ${GITLAB_PAT}' \
      -d 'name=${GITLAB_PROJECT_PATH}' \
      -d 'visibility=public'
  "
fi

# Build the repo in the vagrant user's home so it survives as a working clone
# for the defense demo. Never git-init inside /vagrant — that folder is synced
# back to the host and would pollute the submission repo.
rm -rf "${WORK_CLONE}"
mkdir -p "${WORK_CLONE}/manifests"
cp /vagrant/confs/manifests/*.yaml "${WORK_CLONE}/manifests/"

progress "Pushing manifests to GitLab" bash -c "
  cd '${WORK_CLONE}'
  git init -q
  git checkout -q -b main
  git config user.email 'bootstrap@local'
  git config user.name 'bootstrap'
  git add manifests
  git commit -q -m 'Initial manifests' --allow-empty
  git remote add origin 'http://root:${GITLAB_PAT}@localhost:${GITLAB_LOCAL_PORT}/root/${GITLAB_PROJECT_PATH}.git'
  git push -q -f -u origin main
"
chown -R vagrant:vagrant "${WORK_CLONE}"

# ---------------------------------------------------------------------------
# 12. Register the repo with ArgoCD
#
# The label is the whole mechanism — without it ArgoCD ignores the Secret.
# 'url' must match spec.source.repoURL in application.yaml byte-for-byte;
# ArgoCD pairs credentials to Applications by string comparison.
# ---------------------------------------------------------------------------
phase "Registering GitLab repo with ArgoCD"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-playground-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${GITLAB_INTERNAL_REPO}
  username: root
  password: ${GITLAB_PAT}
EOF

# ---------------------------------------------------------------------------
# 13. Convenience artifacts for the defense
# ---------------------------------------------------------------------------
phase "Writing credentials and helper script"

cat > /home/vagrant/gitlab-creds.txt <<EOF
GitLab root password : ${GITLAB_ROOT_PASSWORD}
GitLab PAT (argocd)  : ${GITLAB_PAT}
Web UI               : http://gitlab.mjeannin.com
Repo (in-cluster)    : ${GITLAB_INTERNAL_REPO}
Working clone        : ${WORK_CLONE}
EOF
chmod 600 /home/vagrant/gitlab-creds.txt
chown vagrant:vagrant /home/vagrant/gitlab-creds.txt

cat > /home/vagrant/gitlab-tunnel.sh <<EOF
#!/usr/bin/env bash
# Open a tunnel from this VM to GitLab so 'git push' from ${WORK_CLONE} works.
# Leave it running in its own terminal; Ctrl-C to stop.
exec kubectl port-forward -n gitlab svc/gitlab-webservice-default ${GITLAB_LOCAL_PORT}:8181
EOF
chmod +x /home/vagrant/gitlab-tunnel.sh
chown vagrant:vagrant /home/vagrant/gitlab-tunnel.sh

# The tunnel has done its job; ArgoCD talks to GitLab over cluster DNS.
kill "${PF_PID}" 2>/dev/null || true
trap - EXIT

# ---------------------------------------------------------------------------
# 14. Application manifest
# ---------------------------------------------------------------------------
phase "Applying ArgoCD Application"
kubectl apply -f /vagrant/confs/application.yaml

# ---------------------------------------------------------------------------
# 15. Summary
# ---------------------------------------------------------------------------
phase "Done"

echo ""
echo "Cluster state:"
kubectl get pods -A
echo ""
echo "ArgoCD Application:"
kubectl get application -n argocd || true
echo ""
echo "ArgoCD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(secret not found)"
echo ""
echo ""
echo "GitLab credentials written to /home/vagrant/gitlab-creds.txt"
echo "Tunnel helper:              /home/vagrant/gitlab-tunnel.sh"
echo "Working clone:              ${WORK_CLONE}"
echo ""
echo "Total provisioning time: ${SECONDS}s"