#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="p3-cluster"

# --- GitOps source ---
# Public GitHub repo Argo CD watches. Must match repoURL in confs/application.yaml
# byte-for-byte. A PAT in confs/github-token is only needed if the repo is private.
GITHUB_REPO_URL="https://github.com/Maj-e/Inception-of-Things-CI.git"
GITHUB_TOKEN_FILE="/vagrant/confs/github-token"

# --- Endpoints ---
# 8080 is opened by the systemd unit of step 9; k3d publishes 8888 by itself.
VM_IP="192.168.56.120"
ARGOCD_LOCAL_PORT=8080
APP_PORT=8888

APP_IMAGE_REPO="wil42/playground"

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
# Re-run a command a few times, for fetches that lose a DNS lookup.
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
# Provisioning starts before DNS is necessarily up, so block until github.com answers.
phase "Waiting for network"
progress "Waiting for github.com to be reachable" bash -c '
  until curl -fsSL -o /dev/null https://github.com/; do
    sleep 1
  done
'

# --- 2. Tooling ---
# Install Docker, kubectl, k3d and Helm in parallel, each only if missing.
phase "Installing tooling"

install_docker_apt() {
  local distro codename
  distro=$(. /etc/os-release && echo "${ID}")
  codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")

  install -m 0755 -d /etc/apt/keyrings &&
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
    -o /etc/apt/keyrings/docker.asc &&
  chmod a+r /etc/apt/keyrings/docker.asc &&
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "${distro}" "${codename}" \
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

# --- 3. Helm repository ---
# Fetch the Argo CD chart index in the background while the cluster boots.
phase "Adding the Argo CD Helm repository (in the background)"

add_helm_repos() {
  retry 5 helm repo add argo https://argoproj.github.io/argo-helm &&
  helm repo update
}
add_helm_repos &> /tmp/helm-repos.log &
HELM_REPOS_PID=$!
echo "  running in the background (pid ${HELM_REPOS_PID}, log /tmp/helm-repos.log)"

# --- 4. k3d cluster ---
# Create the cluster with 8888 published; Traefik and metrics-server are unused here.
phase "Creating k3d cluster"
if ! k3d cluster list | grep -q "${CLUSTER_NAME}"; then
  progress "Creating k3d cluster ${CLUSTER_NAME}" k3d cluster create "${CLUSTER_NAME}" \
    -p "${APP_PORT}:${APP_PORT}@loadbalancer" \
    --k3s-arg "--disable=metrics-server@server:0" \
    --k3s-arg "--disable=traefik@server:0" \
    --wait
fi

mkdir -p /home/vagrant/.kube
cp /root/.kube/config /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

if wait "${HELM_REPOS_PID}"; then
  echo "  Helm repository ready"
else
  echo "  Helm repository FAILED — output follows"
  sed 's/^/  /' /tmp/helm-repos.log
  exit 1
fi

# --- 5. Pre-import images ---
# Pull every image the cluster needs here, on the VM, and side-load it, so that
# containerd never has to resolve a registry. In-cluster DNS is the part that
# fails under load, and it takes the whole cluster down with it.
phase "Pre-importing images"

# The sandbox image, needed before ANY container starts -- including CoreDNS, so
# a failure to pull it is unrecoverable rather than merely slow.
sandbox_image() {
  local img
  img=$(docker exec "k3d-${CLUSTER_NAME}-server-0" \
    grep -rhoE 'rancher/mirrored-pause:[0-9.]+' \
    /var/lib/rancher/k3s/agent/etc/containerd/ 2>/dev/null | head -1)
  echo "${img:-rancher/mirrored-pause:3.6}"
}

# Ask the chart what it runs instead of pinning versions here by hand.
chart_images() {
  helm template argocd argo/argo-cd \
    --values /vagrant/confs/argocd-values.yaml 2>/dev/null \
    | grep -oE 'image: *"?[^"]+"?' \
    | sed -E 's/image: *"?([^"]+)"?/\1/' \
    | sort -u
}

import_images() {
  local image
  for image in $1; do
    retry 3 docker pull "${image}" || return 1
  done
  k3d image import $1 -c "${CLUSTER_NAME}"
}

SANDBOX_IMAGE="$(sandbox_image)"
IMAGES="$(chart_images) ${APP_IMAGE_REPO}:v1 ${APP_IMAGE_REPO}:v2"
echo "${SANDBOX_IMAGE} ${IMAGES}" | tr ' ' '\n' | sed '/^$/d;s/^/    /'

# The sandbox goes first, on its own: CoreDNS is already trying to start and
# cannot until this image is on the node. It is a few hundred kilobytes, so
# putting it ahead of the ~400 MB of Argo CD costs nothing and unblocks the
# cluster a couple of minutes earlier.
#
# Both waves are non-fatal: this is an optimisation, and if it fails the cluster
# pulls the images itself, the old slow way.
if ! progress "Importing the sandbox image" import_images "${SANDBOX_IMAGE}"; then
  echo "  WARNING: sandbox pre-import failed — the cluster will pull it itself."
fi
if ! progress "Pulling and importing the remaining images" import_images "${IMAGES}"; then
  echo "  WARNING: pre-import failed — the cluster will pull these itself."
fi

# --- 6. Namespaces ---
# Create argocd and dev, idempotently.
phase "Creating namespaces"
for ns in argocd dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- 7. Argo CD ---
# Install the chart and wait for it; every image it needs is already on the node.
phase "Installing ArgoCD"

# A convenience for the defense that this script never calls, downloaded while
# Helm works.
(
  if ! command -v argocd &> /dev/null; then
    curl -sSfL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    install -m 555 /tmp/argocd /usr/local/bin/argocd
    rm -f /tmp/argocd
  fi
) &> /tmp/argocd-cli.log &
CLI_PID=$!

# 240s, not 600s: with the images already local there is nothing slow left, so a
# stuck attempt is better retried than waited on.
progress "Installing ArgoCD via Helm" retry 3 helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values /vagrant/confs/argocd-values.yaml \
  --wait \
  --timeout 240s

# --- 8. Collect the argocd CLI download ---
# Non-fatal: the CLI is a convenience for the defense, not a dependency.
phase "Collecting background download"
if wait "${CLI_PID}"; then
  echo "  argocd CLI installed"
else
  echo "  WARNING: argocd CLI download failed (not required) — see /tmp/argocd-cli.log"
fi

# --- 9. Port forwarding ---
# The VM is not on the pod network, so expose the Argo CD UI through a systemd port-forward.
phase "Installing the permanent port-forward service"

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

install_port_forward argocd-forward argocd argocd-server \
  "${ARGOCD_LOCAL_PORT}:80" "ArgoCD web UI on port ${ARGOCD_LOCAL_PORT}"

systemctl is-active argocd-forward.service || true
echo "  ArgoCD UI : http://${VM_IP}:${ARGOCD_LOCAL_PORT}"

# --- 10. Repository credentials ---
# No-op for a public repo; with a token in confs/github-token, register it for a private one.
phase "Registering the GitHub repository"
if [ -f "${GITHUB_TOKEN_FILE}" ]; then
  GITHUB_TOKEN=$(tr -d '[:space:]' < "${GITHUB_TOKEN_FILE}")
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-playground-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${GITHUB_REPO_URL}
  username: git
  password: ${GITHUB_TOKEN}
EOF
  echo "  registered with the token from confs/github-token"
else
  echo "  public repository — no credentials needed"
  echo "  (${GITHUB_REPO_URL})"
fi

# --- 11. Application ---
# Declare what Argo CD deploys, once the repo-server that renders it is up.
phase "Applying ArgoCD Application"
progress "Waiting for the repo-server" \
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl apply -f /vagrant/confs/application.yaml

# --- 12. First sync ---
# Wait until the app actually answers, re-nudging Argo CD every minute: a
# comparison that failed while the repo-server was starting is cached until
# something asks for a refresh.
phase "Waiting for the first sync"

wait_for_app() {
  local deadline=$((SECONDS + 420)) i=0
  until curl -fsS -o /dev/null "http://localhost:${APP_PORT}/"; do
    if [ "${SECONDS}" -ge "${deadline}" ]; then
      return 1
    fi
    i=$((i + 1))
    if [ $((i % 12)) -eq 0 ]; then
      kubectl -n argocd annotate app playground \
        argocd.argoproj.io/refresh=hard --overwrite &> /dev/null || true
    fi
    sleep 5
  done
}

if progress "Waiting for the playground app to answer on :${APP_PORT}" wait_for_app; then
  echo "  app responded: $(curl -fsS "http://localhost:${APP_PORT}/" || true)"
else
  echo "  WARNING: the app is not answering yet."
  echo "  Check:  kubectl -n argocd get application playground"
  echo "          kubectl -n dev get pods"
  echo "          kubectl -n argocd get pods"
  echo "  To force a retry:"
  echo "          kubectl -n argocd annotate app playground argocd.argoproj.io/refresh=hard --overwrite"
fi

# --- 13. Credentials ---
# Keep the UI password on disk for the defense.
phase "Writing credentials"

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

cat > /home/vagrant/argocd-creds.txt <<EOF
ArgoCD web UI         : http://${VM_IP}:${ARGOCD_LOCAL_PORT}   (user: admin)
ArgoCD admin password : ${ARGOCD_PASSWORD}
Application           : http://${VM_IP}:${APP_PORT}
Watched repository    : ${GITHUB_REPO_URL} (branch main, path manifests)
EOF
chmod 600 /home/vagrant/argocd-creds.txt
chown vagrant:vagrant /home/vagrant/argocd-creds.txt

# --- 14. Summary ---
# Print the cluster state and both URLs.
phase "Done"

echo ""
echo "Cluster state:"
kubectl get pods -A
echo ""
echo "ArgoCD Application:"
kubectl get application -n argocd || true
echo ""
echo "Port forward (systemd, restored on every boot):"
systemctl is-active argocd-forward.service || true
echo ""
echo "Reachable from the host — nothing to start:"
echo "  ArgoCD  http://${VM_IP}:${ARGOCD_LOCAL_PORT}   admin / ${ARGOCD_PASSWORD}"
echo "  App     http://${VM_IP}:${APP_PORT}"
echo ""
echo "Watched repository: ${GITHUB_REPO_URL}"
echo "Credentials also written to: /home/vagrant/argocd-creds.txt"
echo ""
echo "Total provisioning time: ${SECONDS}s"
