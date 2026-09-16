#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="p3-cluster"
GITLAB_CHART_VERSION="9.9.2"

# --- GitOps / GitLab settings ---
# 8181 is Workhorse: Rails on 8080 serves the API but rejects git-over-HTTP, so
# 8181 is the only port that works for both. Both ports are opened by step 11.
GITLAB_PROJECT_PATH="playground"
VM_IP="192.168.56.120"
GITLAB_LOCAL_PORT=8181
ARGOCD_LOCAL_PORT=8080
GITLAB_LOCAL_URL="http://localhost:${GITLAB_LOCAL_PORT}"
GITLAB_INTERNAL_HOST="gitlab-webservice-default.gitlab.svc.cluster.local:8181"
GITLAB_INTERNAL_REPO="http://${GITLAB_INTERNAL_HOST}/root/${GITLAB_PROJECT_PATH}.git"
APP_IMAGE_REPO="wil42/playground"
WORK_CLONE="/home/vagrant/${GITLAB_PROJECT_PATH}"

# --- phase ---
# Print a permanent, timestamped marker between sections.
phase() {
  echo ""
  echo "============================================================"
  echo ">>> $* (elapsed: ${SECONDS}s)"
  echo "============================================================"
}

# --- progress ---
# Run a long command behind a spinner, printing its output only on failure.
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

# --- retry ---
# Re-run a command a few times; helm upgrade --install is idempotent, so it resumes.
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

# --- 1. Wait for network ---
# Provisioning starts before DNS is necessarily up, so block until the chart repo answers.
phase "Waiting for network"
progress "Waiting for charts.gitlab.io to be reachable" bash -c '
  until curl -fsSL -o /dev/null https://charts.gitlab.io/; do
    sleep 1
  done
'

# --- 2. Swap ---
# GitLab is memory-hungry; without swap the OOM killer takes its pods during startup.
phase "Setting up swap"
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -h

# --- 3. Tooling ---
# Install Docker, kubectl, k3d and Helm in parallel, each only if missing.
phase "Installing tooling"

install_docker_apt() {
  install -m 0755 -d /etc/apt/keyrings &&
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc &&
  chmod a+r /etc/apt/keyrings/docker.asc &&
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" \
    "$(. /etc/os-release && echo "${VERSION_CODENAME}")" \
    > /etc/apt/sources.list.d/docker.list &&
  apt-get update -qq &&
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io
}

install_docker() {
  install_docker_apt && return 0
  echo "  apt route failed, falling back to get.docker.com"
  rm -f /etc/apt/sources.list.d/docker.list
  curl -fsSL https://get.docker.com | sh
}

install_kubectl() {
  local v
  v=$(curl -fsSL https://dl.k8s.io/release/stable.txt) &&
  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${v}/bin/linux/amd64/kubectl" &&
  install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl &&
  rm -f /tmp/kubectl
}

install_k3d() {
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
}

install_helm() {
  curl -fsSL -o /tmp/get_helm.sh \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 &&
  chmod 700 /tmp/get_helm.sh &&
  /tmp/get_helm.sh &&
  rm -f /tmp/get_helm.sh
}

install_tooling() {
  local pids="" pid rc=0
  command -v docker  >/dev/null 2>&1 || { install_docker  & pids="${pids} $!"; }
  command -v kubectl >/dev/null 2>&1 || { install_kubectl & pids="${pids} $!"; }
  command -v k3d     >/dev/null 2>&1 || { install_k3d     & pids="${pids} $!"; }
  command -v helm    >/dev/null 2>&1 || { install_helm    & pids="${pids} $!"; }
  for pid in ${pids}; do wait "${pid}" || rc=1; done
  return ${rc}
}

progress "Installing Docker, kubectl, k3d and Helm (in parallel)" install_tooling
usermod -aG docker vagrant

docker --version
kubectl version --client
k3d version
helm version --short

# --- 4. Helm repositories ---
# Fetch the gitlab and argo chart indexes in the background while the cluster boots.
phase "Adding Helm repositories (in the background)"

add_helm_repos() {
  retry 5 helm repo add gitlab https://charts.gitlab.io/ &&
  retry 5 helm repo add argo https://argoproj.github.io/argo-helm &&
  helm repo update
}
add_helm_repos &> /tmp/helm-repos.log &
HELM_REPOS_PID=$!
echo "  running in the background (pid ${HELM_REPOS_PID}, log /tmp/helm-repos.log)"

# --- 5. k3d cluster ---
# Create the cluster with 8888 published; Traefik and metrics-server are unused here.
phase "Creating k3d cluster"
if ! k3d cluster list | grep -q "${CLUSTER_NAME}"; then
  progress "Creating k3d cluster ${CLUSTER_NAME}" k3d cluster create "${CLUSTER_NAME}" \
    -p "8888:8888@loadbalancer" \
    --k3s-arg "--disable=metrics-server@server:0" \
    --k3s-arg "--disable=traefik@server:0" \
    --wait
fi

mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

if wait "${HELM_REPOS_PID}"; then
  echo "  Helm repositories ready"
else
  echo "  Helm repositories FAILED — output follows"
  sed 's/^/  /' /tmp/helm-repos.log
  exit 1
fi

# --- 6. Background downloads ---
# Side-load both playground tags, plus git and the argocd CLI, while GitLab boots.
phase "Starting background downloads"
(
  if ! command -v git >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq git
  fi

  for tag in v1 v2; do
    retry 3 docker pull "${APP_IMAGE_REPO}:${tag}"
  done
  k3d image import "${APP_IMAGE_REPO}:v1" "${APP_IMAGE_REPO}:v2" -c "${CLUSTER_NAME}"

  if ! command -v argocd &> /dev/null; then
    curl -sSfL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    install -m 555 /tmp/argocd /usr/local/bin/argocd
    rm -f /tmp/argocd
  fi
) &> /tmp/background-downloads.log &
DOWNLOADS_PID=$!
echo "  running in the background (pid ${DOWNLOADS_PID}, log /tmp/background-downloads.log)"

# --- 7. Namespaces ---
# Create gitlab, argocd and dev, idempotently.
phase "Creating namespaces"
for ns in gitlab argocd dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- 8. GitLab ---
# Apply the chart without --wait so Rails boots while the script installs Argo CD;
# the readiness gate is in step 12, on the API we actually depend on.
phase "Installing GitLab (starts booting in the background)"
progress "Applying GitLab chart" retry 3 helm upgrade --install gitlab gitlab/gitlab \
  --namespace gitlab \
  --version "${GITLAB_CHART_VERSION}" \
  --values /vagrant/confs/gitlab-values.yaml \
  --timeout 1200s

# --- 9. Argo CD ---
# Install the chart with our values while GitLab is still starting.
phase "Installing ArgoCD"
progress "Installing ArgoCD via Helm (up to 10 min)" retry 3 helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values /vagrant/confs/argocd-values.yaml \
  --wait \
  --timeout 600s

# --- 10. Collect the background downloads ---
# Turn a failed download into a clear error here rather than an ImagePullBackOff later.
phase "Collecting background downloads"
if wait "${DOWNLOADS_PID}"; then
  echo "  git installed, application images imported, argocd CLI installed"
else
  echo "  FAILED — output follows"
  sed 's/^/  /' /tmp/background-downloads.log
  exit 1
fi

# --- 11. Port forwarding ---
# The VM is not on the pod network, so expose both UIs through systemd port-forwards.
phase "Installing permanent port-forward services"

install_port_forward() {
  local unit="$1" namespace="$2" service="$3" ports="$4" description="$5"

  cat > "/etc/systemd/system/${unit}.service" <<EOF
[Unit]
Description=${description}
After=docker.service
Wants=docker.service

[Service]
Environment=KUBECONFIG=/root/.kube/config
# Block here instead of restart-looping while the cluster is still coming up.
ExecStartPre=/bin/bash -c 'until kubectl -n ${namespace} get svc ${service} >/dev/null 2>&1; do sleep 5; done'
ExecStart=/usr/local/bin/kubectl port-forward --address 0.0.0.0 -n ${namespace} svc/${service} ${ports}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${unit}.service" &> /dev/null
  systemctl restart "${unit}.service"
}

install_port_forward gitlab-forward gitlab gitlab-webservice-default \
  "${GITLAB_LOCAL_PORT}:8181" "GitLab web UI on port ${GITLAB_LOCAL_PORT}"
install_port_forward argocd-forward argocd argocd-server \
  "${ARGOCD_LOCAL_PORT}:80" "ArgoCD web UI on port ${ARGOCD_LOCAL_PORT}"

systemctl is-active gitlab-forward.service argocd-forward.service || true
echo "  GitLab UI : http://${VM_IP}:${GITLAB_LOCAL_PORT}"
echo "  ArgoCD UI : http://${VM_IP}:${ARGOCD_LOCAL_PORT}"

# --- 12. GitLab project ---
# Wait for the API, mint a token, create the project and push the manifests through the forward.
phase "Setting up GitLab project"

GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath='{.data.password}' | base64 -d)

progress "Waiting for GitLab API through the forward" bash -c "
  until [ \"\$(curl -s -o /dev/null -w '%{http_code}' '${GITLAB_LOCAL_URL}/api/v4/version' || true)\" = '401' ]; do
    sleep 5
  done
"

echo ""
kubectl get pods -n gitlab
echo "Memory/swap usage now that GitLab is up:"
free -h
echo ""

progress "Obtaining OAuth token" bash -c "
  curl -fsS -X POST '${GITLAB_LOCAL_URL}/oauth/token' \
    -d 'grant_type=password' \
    -d 'username=root' \
    -d 'password=${GITLAB_ROOT_PASSWORD}' \
    -o /tmp/gitlab-oauth.json
"
GITLAB_OAUTH=$(grep -o '"access_token":"[^"]*"' /tmp/gitlab-oauth.json | cut -d'"' -f4)
rm -f /tmp/gitlab-oauth.json

PAT_EXPIRY=$(date -d '+1 year' +%Y-%m-%d)
progress "Creating personal access token" bash -c "
  curl -fsS -X POST '${GITLAB_LOCAL_URL}/api/v4/users/1/personal_access_tokens' \
    -H 'Authorization: Bearer ${GITLAB_OAUTH}' \
    -d 'name=argocd' \
    -d 'scopes[]=api' -d 'scopes[]=read_repository' -d 'scopes[]=write_repository' \
    -d 'expires_at=${PAT_EXPIRY}' \
    -o /tmp/gitlab-pat.json
"
GITLAB_PAT=$(grep -o '"token":"[^"]*"' /tmp/gitlab-pat.json | cut -d'"' -f4)
rm -f /tmp/gitlab-pat.json

if [ -z "${GITLAB_PAT}" ]; then
  echo "ERROR: failed to obtain a GitLab personal access token"
  exit 1
fi
echo "  token acquired: ${GITLAB_PAT:0:12}..."

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

# The clone lives in the vagrant user's home, never in /vagrant, which is synced
# back to the host.
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

# Prove the push landed somewhere ArgoCD can clone from. This is what backs the
# decision to run without Sidekiq: a failure surfaces here, not on defense day.
if ! progress "Verifying the repository serves its content back" bash -c "
  [ \"\$(curl -s -o /dev/null -w '%{http_code}' \
      -H 'PRIVATE-TOKEN: ${GITLAB_PAT}' \
      '${GITLAB_LOCAL_URL}/api/v4/projects/root%2F${GITLAB_PROJECT_PATH}/repository/files/manifests%2Fdeployment.yaml?ref=main')\" = '200' ]
"; then
  cat <<'MSG'

  ERROR: the manifests were pushed, but GitLab will not serve them back.

  Set `gitlab.sidekiq.enabled: true` in confs/gitlab-values.yaml and re-run
  `vagrant provision`. Everything else in this script is unaffected.

MSG
  exit 1
fi

# --- 13. Repository credentials ---
# Register the repo with ArgoCD; the label is what makes ArgoCD read the Secret, and
# url must match spec.source.repoURL byte-for-byte.
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

# --- 14. Credentials ---
# Keep both UI passwords and the PAT on disk for the defense.
phase "Writing credentials"

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

cat > /home/vagrant/gitlab-creds.txt <<EOF
GitLab web UI         : http://${VM_IP}:${GITLAB_LOCAL_PORT}   (user: root)
GitLab root password  : ${GITLAB_ROOT_PASSWORD}
GitLab PAT (argocd)   : ${GITLAB_PAT}
ArgoCD web UI         : http://${VM_IP}:${ARGOCD_LOCAL_PORT}   (user: admin)
ArgoCD admin password : ${ARGOCD_PASSWORD}
Repo (in-cluster)     : ${GITLAB_INTERNAL_REPO}
Working clone         : ${WORK_CLONE}
EOF
chmod 600 /home/vagrant/gitlab-creds.txt
chown vagrant:vagrant /home/vagrant/gitlab-creds.txt

# --- 15. Application ---
# Declare what ArgoCD deploys, once the repo-server that renders it is up, then
# clear any comparison that failed while it was starting.
phase "Applying ArgoCD Application"
progress "Waiting for the repo-server" \
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl apply -f /vagrant/confs/application.yaml
kubectl -n argocd annotate app playground \
  argocd.argoproj.io/refresh=hard --overwrite &> /dev/null || true

# --- 16. Summary ---
# Print the cluster state, both URLs and their passwords.
phase "Done"

echo ""
echo "Cluster state:"
kubectl get pods -A
echo ""
echo "ArgoCD Application:"
kubectl get application -n argocd || true
echo ""
echo "Port forwards (systemd, restored on every boot):"
systemctl is-active gitlab-forward.service argocd-forward.service || true
echo ""
echo "Web UIs, already reachable from the host — nothing to start:"
echo "  GitLab  http://${VM_IP}:${GITLAB_LOCAL_PORT}   root  / ${GITLAB_ROOT_PASSWORD}"
echo "  ArgoCD  http://${VM_IP}:${ARGOCD_LOCAL_PORT}   admin / ${ARGOCD_PASSWORD}"
echo "  App     http://${VM_IP}:8888"
echo ""
echo "Credentials also written to: /home/vagrant/gitlab-creds.txt"
echo "Working clone:               ${WORK_CLONE}"
echo ""
echo "Total provisioning time: ${SECONDS}s"
