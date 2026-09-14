# Part 3: K3d and Argo CD

A single VM running **Docker** and a **K3d** cluster (no Vagrant multi-machine this time). **Argo CD** runs inside the cluster and deploys an application from a **public GitHub repository**, following the **GitOps** approach:

> Git is the single source of truth. To change what runs in the cluster, you change the repository, not the cluster.

## Architecture

```
 GitHub: Maj-e/Inception-of-Things-CI           VM 192.168.56.120 (Debian 13 (Trixie))
 ┌────────────────────────────┐                 ┌───────────────────────────────────────────┐
 │ manifests/                 │                 │ Docker                                    │
 │   deployment.yaml (v1/v2)  │   polls repo    │ └─ k3d cluster "p3-cluster"               │
 │   service.yaml             │◄────────────────│    ├─ namespace argocd                    │
 └────────────────────────────┘                 │    │   └─ Argo CD (Application playground)│
            ▲                                   │    │          │ applies manifests         │
            │ git push                          │    │          ▼                           │
         developer                              │    └─ namespace dev                       │
                                                │        └─ playground (wil42/playground)   │
                                                │                                           │
                                                │ k3d load balancer :8888 ──► svc playground│
                                                └───────────────────────────────────────────┘
                                                                  ▲
                                         curl http://192.168.56.120:8888
```

## K3s vs K3d

- **K3s** (Parts 1 and 2) is installed directly on the operating system as a systemd service.
- **K3d** runs K3s **inside Docker containers**: each Kubernetes node is a container. Creating or deleting a cluster takes seconds and leaves nothing behind on the host, which is why it's popular for local development and CI. K3d also starts a small load-balancer container that publishes chosen ports from the cluster onto the host.

## Files

| File | Purpose |
|---|---|
| `Vagrantfile` | One Debian 13 (Trixie) VM, IP `192.168.56.120`, 6 CPUs / 8 GB RAM, project folder rsynced to `/vagrant` |
| `scripts/bootstrap.sh` | Installs Docker, kubectl, k3d, creates the cluster, installs Argo CD and registers the Application |
| `confs/application.yaml` | The Argo CD `Application`: which repo to watch and where to deploy it |
| `confs/manifests/deployment.yaml` | Reference copy of the manifests stored in the GitHub repo: `wil42/playground` Deployment |
| `confs/manifests/service.yaml` | Reference copy: `LoadBalancer` Service on port 8888 |
| `IoT_commands_p3.md` | Notes for moving VirtualBox and Vagrant storage to `goinfre` on 42 machines |

## How it works

### 1. Tooling (`bootstrap.sh`)

Each tool is installed only if it's missing, so the script can be run again safely:

- **curl**, if the box doesn't ship it
- **Docker** via `get.docker.com`, with the `vagrant` user added to the `docker` group
- **kubectl**, latest stable binary
- **k3d** via its official install script

### 2. The cluster

```bash
k3d cluster create p3-cluster -p "8888:8888@loadbalancer" --wait
```

`-p "8888:8888@loadbalancer"` publishes port 8888 of the k3d load-balancer container on port 8888 of the VM. Inside the cluster, the `playground` Service is of type `LoadBalancer` on port 8888. K3s's built-in service load balancer exposes it on the nodes, and the k3d load balancer forwards VM traffic to it. That makes the app reachable at `http://192.168.56.120:8888`.

The kubeconfig is copied to `/home/vagrant/.kube/config` so `kubectl` works without `sudo` after `vagrant ssh`.

### 3. Namespaces and Argo CD

The subject requires two namespaces:

- **`argocd`**: Argo CD itself, installed from the official `install.yaml` manifest. The script waits until every Argo CD deployment is `Available`.
- **`dev`**: the application Argo CD deploys.

Namespaces are created with `--dry-run=client -o yaml | kubectl apply -f -`. This is the idempotent way to say "create it if it doesn't exist".

### 4. The Argo CD Application (`confs/application.yaml`)

```yaml
source:
  repoURL: https://github.com/Maj-e/Inception-of-Things-CI
  targetRevision: main
  path: manifests
destination:
  server: https://kubernetes.default.svc   # the cluster Argo CD runs in
  namespace: dev
syncPolicy:
  automated:
    prune: true      # delete resources that were removed from Git
    selfHeal: true   # undo manual changes made directly in the cluster
```

Argo CD's controller polls the repository (every ~3 minutes by default), renders the manifests under `manifests/`, and compares them with what is running in `dev`:

- If Git and the cluster match, the app is **Synced**.
- If Git changed (a new commit), the app is **OutOfSync**, and because `automated` is on, Argo CD applies the new manifests right away.
- If someone edits the cluster by hand (`kubectl scale ...`), `selfHeal` puts it back to what Git says.

### 5. The application

`wil42/playground` is a tiny HTTP server on port 8888 that returns its version. There are two tags, `v1` and `v2`, so it's easy to see a deployment happen.

## Usage

```bash
cd p3
vagrant up        # the bootstrap prints the Argo CD admin password at the end
vagrant ssh
```

Check the cluster:

```bash
kubectl get ns                       # argocd and dev exist
kubectl get pods -n argocd
kubectl get pods -n dev
kubectl get application -n argocd    # playground: Synced / Healthy
```

Query the app, from the VM or from your host:

```bash
curl http://192.168.56.120:8888/
# {"status":"ok", "message": "v1"}
```

### Open the Argo CD UI

```bash
# in the VM
kubectl port-forward --address 0.0.0.0 svc/argocd-server -n argocd 8080:443
# admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Then open `https://192.168.56.120:8080` from the host (self-signed certificate) and log in as `admin`.

### Demo: deploy v2 with a git push

In the GitHub repository `Maj-e/Inception-of-Things-CI`:

```bash
sed -i 's/playground:v1/playground:v2/' manifests/deployment.yaml
git commit -am "deploy v2"
git push
```

Wait for Argo CD to notice (or click **Refresh** in the UI), then:

```bash
kubectl get pods -n dev -w           # the old pod is replaced by a new one
curl http://192.168.56.120:8888/
# {"status":"ok", "message": "v2"}
```

Change it back to `v1` to roll back. The rollback is just another commit.
