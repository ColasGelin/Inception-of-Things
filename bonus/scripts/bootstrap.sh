#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="p3-cluster"
GITLAB_CHART_VERSION="9.9.2"

# --- GitOps / GitLab settings ----------------------------------------------
GITLAB_PROJECT_PATH="playground"
# These two ports are opened permanently by the systemd units of step 11, on
# 0.0.0.0, so the same address works inside the VM and from the host.
VM_IP="192.168.56.120"
GITLAB_LOCAL_PORT=8181
ARGOCD_LOCAL_PORT=8080
GITLAB_LOCAL_URL="http://localhost:${GITLAB_LOCAL_PORT}"
# Port 8181 = Workhorse. Rails on 8080 serves the API but REJECTS git-over-HTTP
# ("Nil JSON web token"), so 8181 is the only port that works for both.
GITLAB_INTERNAL_HOST="gitlab-webservice-default.gitlab.svc.cluster.local:8181"
GITLAB_INTERNAL_REPO="http://${GITLAB_INTERNAL_HOST}/root/${GITLAB_PROJECT_PATH}.git"
APP_IMAGE_REPO="wil42/playground"
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
#
# Five independent downloads. git and Docker both go through apt, so they share
# one branch (dpkg takes an exclusive lock); kubectl, k3d and Helm are plain
# binary fetches and run alongside them. The phase costs its slowest branch
# instead of the sum of all five.
# ---------------------------------------------------------------------------
phase "Installing tooling"

progress "Installing git, Docker, kubectl, k3d and Helm (in parallel)" bash -c '
  set -eu
  pids=""

  # One branch for everything apt-based: dpkg would refuse to run these at the
  # same time anyway.
  (
    command -v git >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq git; }
    command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
  ) &
  pids="$pids $!"

  if ! command -v kubectl >/dev/null 2>&1; then
    (
      v=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
      curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${v}/bin/linux/amd64/kubectl"
      install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
      rm -f /tmp/kubectl
    ) &
    pids="$pids $!"
  fi

  if ! command -v k3d >/dev/null 2>&1; then
    ( curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash ) &
    pids="$pids $!"
  fi

  if ! command -v helm >/dev/null 2>&1; then
    (
      curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
      chmod 700 /tmp/get_helm.sh
      /tmp/get_helm.sh
      rm -f /tmp/get_helm.sh
    ) &
    pids="$pids $!"
  fi

  rc=0
  for pid in $pids; do wait "$pid" || rc=1; done
  exit $rc
'
usermod -aG docker vagrant

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
# GitLab no longer publishes an Ingress (see confs/gitlab-values.yaml) and the
# playground Service is a LoadBalancer served by k3s's own servicelb, so
# Traefik has nothing left to route: disabling it drops a Helm-install job, a
# pod and an image pull from the critical path. Port 80 goes with it.
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

# ---------------------------------------------------------------------------
# 6. Pre-import application images — started here, collected in step 10
#
# Pull on the HOST and side-load into the k3d nodes so the kubelet never has to
# reach Docker Hub. With GitLab running this VM is memory-starved, CoreDNS gets
# flaky, and in-cluster image pulls fail with "lookup registry-1.docker.io:
# Try again". Importing both tags up front makes the v1 -> v2 demo immune to
# that (and to Docker Hub rate limits).
#
# Nothing needs these images until Argo CD syncs, several minutes from now, so
# the download runs in the background and overlaps GitLab's startup instead of
# sitting in front of it. The Argo CD CLI rides along: it is a convenience for
# the defense, not something this script uses.
# ---------------------------------------------------------------------------
phase "Starting background downloads"
(
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

# ---------------------------------------------------------------------------
# 7. Namespaces
# ---------------------------------------------------------------------------
phase "Creating namespaces"
for ns in gitlab argocd dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# 8. GitLab FIRST, and deliberately without --wait
#
# GitLab is the long pole: database migrations plus a Rails boot that nothing
# can shorten. `helm upgrade --install` without `--wait` returns as soon as the
# objects exist, so the cluster starts pulling images and migrating while this
# script goes on to install Argo CD and collect the background downloads.
# Waiting on the whole release would have serialised all of that behind it.
#
# The readiness gate has not disappeared, it has moved to step 12, where we
# poll the GitLab API — which is the thing we actually depend on, and a far
# tighter condition than "every pod in the release is ready".
# ---------------------------------------------------------------------------
phase "Installing GitLab (starts booting in the background)"
progress "Applying GitLab chart" retry 3 helm upgrade --install gitlab gitlab/gitlab \
  --namespace gitlab \
  --version "${GITLAB_CHART_VERSION}" \
  --values /vagrant/confs/gitlab-values.yaml \
  --timeout 1200s

# ---------------------------------------------------------------------------
# 9. ArgoCD — installed while GitLab boots
# ---------------------------------------------------------------------------
phase "Installing ArgoCD"
progress "Installing ArgoCD via Helm (up to 10 min)" retry 3 helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values /vagrant/confs/argocd-values.yaml \
  --wait \
  --timeout 600s

# ---------------------------------------------------------------------------
# 10. Collect the background downloads from step 6
# ---------------------------------------------------------------------------
phase "Collecting background downloads"
if wait "${DOWNLOADS_PID}"; then
  echo "  application images imported, argocd CLI installed"
else
  echo "  FAILED — output follows"
  sed 's/^/  /' /tmp/background-downloads.log
  exit 1
fi

# ---------------------------------------------------------------------------
# 11. Permanent port forwarding (systemd)
#
# The VM is not on the pod network, so it cannot resolve *.svc.cluster.local:
# a kubectl port-forward is the only way to reach GitLab and ArgoCD from here.
# Rather than opening one by hand for every demo, install one systemd unit per
# UI:
#   * enabled         -> they come back on their own when the VM reboots
#   * Restart=always  -> a forward dies with the pod it is attached to; systemd
#     reopens it seconds later, so a rescheduled pod is not a dead link
#   * --address 0.0.0.0 -> reachable from the host at ${VM_IP}, not only from
#     inside the VM, which is what removes the need for a helper CLI
#
# ArgoCD itself IS in the cluster and still reaches GitLab over internal DNS
# (see step 13); these tunnels exist only for humans.
# ---------------------------------------------------------------------------
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

  # Reload before enabling: on a re-provision the file we just overwrote is
  # already loaded, and systemd would otherwise keep serving the old one.
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

# ---------------------------------------------------------------------------
# 12. GitLab project: token, project creation, manifest push
#
# This is where we finally block on GitLab, through the forward installed just
# above — which is also why the working clone can push without any extra
# terminal.
# ---------------------------------------------------------------------------
phase "Setting up GitLab project"

GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath='{.data.password}' | base64 -d)

# Rails answers 401 on /api/v4/version once it is booted; a connection error or
# 502 means it is still starting. 401 is therefore our readiness signal.
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

# GitLab 18.x rejects username/password on the REST API, so authenticate via
# the OAuth password grant first. That token is short-lived (~2h), so we
# immediately use it to mint a long-lived PAT for ArgoCD.
progress "Obtaining OAuth token" bash -c "
  curl -fsS -X POST '${GITLAB_LOCAL_URL}/oauth/token' \
    -d 'grant_type=password' \
    -d 'username=root' \
    -d 'password=${GITLAB_ROOT_PASSWORD}' \
    -o /tmp/gitlab-oauth.json
"
GITLAB_OAUTH=$(grep -o '"access_token":"[^"]*"' /tmp/gitlab-oauth.json | cut -d'"' -f4)
rm -f /tmp/gitlab-oauth.json

# /api/v4/users/:id/personal_access_tokens is the ADMIN endpoint. The
# self-service /api/v4/personal_access_tokens endpoint 404s on this version.
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

# Prove the push landed somewhere ArgoCD can clone from. This is the check that
# backs the disabled Sidekiq: if skipping the post-receive background jobs ever
# did break repository bookkeeping, it surfaces HERE, during provisioning, with
# a fix attached — not on defense day.
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

# ---------------------------------------------------------------------------
# 13. Register the repo with ArgoCD
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
# 14. Credentials for the defense
#
# No tunnel helper any more: both UIs are permanently forwarded (step 11), and
# the working clone pushes to localhost:${GITLAB_LOCAL_PORT} through the very
# same forward.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 15. Application manifest
# ---------------------------------------------------------------------------
phase "Applying ArgoCD Application"
kubectl apply -f /vagrant/confs/application.yaml

# ---------------------------------------------------------------------------
# 16. Summary
# ---------------------------------------------------------------------------
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