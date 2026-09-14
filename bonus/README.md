# Bonus: GitLab

Part 3, but **fully self-hosted**: the Git repository Argo CD watches no longer lives on GitHub. It lives in a **GitLab CE instance running inside the same Kubernetes cluster**. Once the VM is up, the whole GitOps loop (commit → push → sync → new pod) runs locally, and nothing is pulled from a public Git host.

## Architecture

```
VM 192.168.56.120 (Debian 13 (Trixie), 5 CPUs, 5 GB RAM + 4 GB swap)
└─ Docker
   └─ k3d cluster "p3-cluster"
      │
      ├─ namespace gitlab ─────────────────────────────────────────────┐
      │   GitLab CE (Helm chart 10.3.2)                                │
      │   webservice (Rails + Workhorse :8181), gitaly, sidekiq,       │
      │   toolbox, migrations                                          │
      │   + PostgreSQL 17, Redis 7.2 (confs/gitlab-deps.yaml)          │
      │   repo: root/playground  ── manifests/deployment.yaml          │
      │                             manifests/service.yaml             │
      │                                                                │
      ├─ namespace argocd                                              │
      │   Argo CD (Helm)  ── polls every 60s ──────────────────────────┘
      │        │   http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/playground.git
      │        │ applies
      │        ▼
      └─ namespace dev
          playground (wil42/playground:v1 / v2)

k3d load balancer:  VM :80   → Traefik → GitLab Ingress (gitlab.mjeannin.com)
                    VM :8888 → playground Service

systemd port-forwards (started at boot, see step 11):
                    VM :8181 → svc/gitlab-webservice-default   (GitLab UI)
                    VM :8080 → svc/argocd-server               (Argo CD UI)
```

The key point: **Argo CD reaches GitLab through the cluster's internal DNS** (`<service>.<namespace>.svc.cluster.local`), the same way microservices talk to each other in production.

## Files

| File | Purpose |
|---|---|
| `Vagrantfile` | One Debian 13 (Trixie) VM, IP `192.168.56.120`, 5 CPUs / 5 GB RAM, `confs/` rsynced to `/vagrant/confs` |
| `scripts/bootstrap.sh` | Provisions everything: tooling, cluster, Argo CD, GitLab, project, token, repo registration |
| `confs/argocd-values.yaml` | Helm values for Argo CD: small resource requests, unused components disabled, 60s sync interval |
| `confs/gitlab-values.yaml` | Helm values for GitLab: minimal CE install tuned to fit in a small VM, plugged into the external PostgreSQL/Redis and K3s's Traefik |
| `confs/gitlab-deps.yaml` | PostgreSQL 17 and Redis 7.2 for GitLab (the chart stopped bundling them in 10.0) |
| `confs/application.yaml` | Argo CD `Application` pointing at the in-cluster GitLab repo |
| `confs/manifests/*.yaml` | Initial app manifests, pushed to GitLab by the bootstrap |
| `IoT_commands_p3.md` | Notes for moving VirtualBox and Vagrant storage to `goinfre` on 42 machines |

## Helm

GitLab isn't one container. It's a dozen components (web app, Git storage, background jobs, database, cache, ...), each needing Deployments, StatefulSets, Services, Secrets, ConfigMaps and Jobs. Writing that by hand would mean thousands of lines of YAML.

**Helm** packages all of this as a **chart**: templated manifests plus a `values.yaml` of settings. `helm upgrade --install <release> <chart> --values my-values.yaml` renders the templates with your values and applies the result. Running it again updates the release in place, which is why the bootstrap can retry it safely.

## How the bootstrap works

`scripts/bootstrap.sh` runs in numbered phases. Long steps run behind a spinner. If a step fails, its full output is printed, so nothing is lost.

### 1. Wait for network
Loops until `charts.gitlab.io` responds, to avoid failing right at boot because DNS isn't ready yet.

### 2. Swap
Creates a 4 GB `/swapfile`. GitLab uses a lot of memory, and without swap the kernel's OOM killer can kill its pods during startup.

### 3. Tooling
Installs `curl` (if missing), `git`, Docker, `kubectl`, `k3d` and `helm`, each only if it's missing.

### 4. Helm repositories
Adds the `gitlab` and `argo` chart repositories (with retries).

### 5. k3d cluster
```bash
k3d cluster create p3-cluster \
  -p "80:80@loadbalancer" \          # Traefik -> GitLab Ingress
  -p "8888:8888@loadbalancer" \      # playground app
  --k3s-arg "--disable=metrics-server@server:0" \   # one less component eating RAM
  --wait
```

### 6. Pre-import images
`wil42/playground:v1` and `v2` (and the `postgres` and `redis` images) are pulled **on the VM** and loaded into the k3d node with `k3d image import`. With GitLab running, the VM is short on memory, CoreDNS can get flaky, and in-cluster pulls from Docker Hub can fail. Pre-loading them makes the v1 → v2 demo independent of the network and of Docker Hub rate limits.

### 7. Namespaces
Creates `gitlab`, `argocd` and `dev` (idempotently).

### 8. Argo CD (Helm)
Installed **first** because it's lighter and fails fast if something is wrong with the cluster. `argocd-values.yaml`:
- lowers the resource requests so the scheduler can fit everything
- disables `applicationSet`, `notifications` and `dex` (SSO), none of which are used here
- sets `server.insecure: true` so the UI is served over plain HTTP
- sets `timeout.reconciliation: 60s` so Argo CD checks Git every minute instead of every 3

The `argocd` CLI is installed as well.

### 9. PostgreSQL and Redis
Since Helm chart 10.0 (GitLab 19.0), the GitLab chart **no longer ships PostgreSQL, Redis or MinIO**. `confs/gitlab-deps.yaml` runs one small instance of each datastore in the `gitlab` namespace:

- **PostgreSQL 17** (the only major version GitLab 19 supports) with a 2 GiB volume. Its user is a superuser, so GitLab's migrations can create the extensions they need (`pg_trgm`, `btree_gist`, `amcheck`).
- **Redis 7.2** (the version GitLab recommends), password protected.

Both passwords are random and stored in Secrets (`gitlab-postgresql-password`, `gitlab-redis-secret`). They are created **once** and never replaced on a rerun: PostgreSQL only reads its password when it first initialises the volume, so a new Secret would lock GitLab out of its database. The script waits until both pods are ready before installing GitLab.

MinIO isn't replaced: object storage is only needed for LFS, CI artifacts, uploads and packages, which are disabled (see below).

### 10. GitLab (Helm)
The heaviest step (10–20 min). `gitlab-values.yaml` trims the chart down to the minimum:

| Setting | Why |
|---|---|
| `edition: ce`, `hosts.domain: mjeannin.com`, `https: false` | Community edition, reachable at `gitlab.mjeannin.com` over HTTP |
| `gatewayApi.enabled: false`, `gatewayApi.installEnvoy: false` | Chart 10.x defaults to Gateway API with its own Envoy Gateway. We don't need a second proxy |
| `ingress.enabled: true`, `ingress.provider/class: traefik`, `nginx-ingress.enabled: false` | Use a plain Ingress on the Traefik controller K3s already ships |
| `installCertmanager: false` | No TLS certificates needed locally |
| `prometheus`, `gitlab-runner`, `registry`, `gitlab-pages`, `kas`, `gitlab-shell` disabled | Features not needed for a Git repo served over HTTP |
| 1 webservice replica, 1 worker process, 1 sidekiq replica, small requests and limits | Fit into ~5 GB of RAM |
| `psql.host: postgresql.gitlab.svc`, `redis.host: redis.gitlab.svc`, passwords from Secrets | The external datastores from step 9 |
| `appConfig.lfs/artifacts/uploads/packages.enabled: false` | These require S3 object storage now that MinIO is gone, and aren't needed to host a Git repo |

### 11. Automatic port forwarding (systemd)
The VM isn't on the pod network, so it can't resolve `*.svc.cluster.local`: a `kubectl port-forward` is the only way to reach GitLab and Argo CD from outside the cluster. Instead of opening one by hand before every demo, the bootstrap installs **one systemd unit per UI**:

| Unit | Forward |
|---|---|
| `gitlab-forward.service` | `svc/gitlab-webservice-default` → `0.0.0.0:8181` |
| `argocd-forward.service` | `svc/argocd-server` → `0.0.0.0:8080` |

```ini
[Service]
Environment=KUBECONFIG=/root/.kube/config
ExecStartPre=/bin/bash -c 'until kubectl -n gitlab get svc gitlab-webservice-default >/dev/null 2>&1; do sleep 5; done'
ExecStart=/usr/local/bin/kubectl port-forward --address 0.0.0.0 -n gitlab svc/gitlab-webservice-default 8181:8181
Restart=always
RestartSec=5
```

Three details make this work unattended:

- **`--address 0.0.0.0`** — the forward listens on every interface of the VM, so the host reaches it at `192.168.56.120`, not just `localhost` inside the VM.
- **`Restart=always`** — a `port-forward` is bound to one pod and dies with it. systemd reopens it a few seconds later, so a rescheduled GitLab or Argo CD pod doesn't leave a dead link.
- **`enable` + `ExecStartPre`** — the units are enabled, so they start again when the VM reboots; the `ExecStartPre` loop simply waits for the cluster to come back instead of restart-looping in the meantime.

Argo CD itself is *in* the cluster and keeps talking to GitLab over internal DNS (step 13). These forwards exist only for humans — and for the working clone, which pushes to `localhost:8181` through the same one.

### 12. GitLab project, token and first push
Everything below goes through the GitLab forward from step 11:

1. **Wait for the API**: polls `/api/v4/version` until it returns `401`. That means Rails has booted and is refusing an unauthenticated request. A connection error or a `502` means it's still starting.
2. **Personal access token (PAT)**: GitLab 19 removed the OAuth password grant, so the root password can't be traded for an API token anymore. The script generates a random 20-character token and registers it for `root` with `gitlab-rails runner` inside the toolbox pod (scopes `api`, `read_repository`, `write_repository`, valid one year).
3. **Project**: creates the public project `root/playground` if it doesn't exist yet.
4. **Push**: builds a Git repo in `/home/vagrant/playground` with the manifests from `confs/manifests/` and pushes it to `main`. The clone is kept as a working copy for the demo.

> Port **8181** is GitLab **Workhorse**, the front proxy that handles Git over HTTP. Rails on port 8080 serves the API but rejects git clone/push, so 8181 is the only port that works for both.

### 13. Register the repo with Argo CD
Creates a Secret in `argocd` holding the repo URL and the PAT:

```yaml
metadata:
  labels:
    argocd.argoproj.io/secret-type: repository   # this label is how Argo CD finds it
stringData:
  type: git
  url: http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/playground.git
  username: root
  password: <PAT>
```

Argo CD matches credentials to Applications by comparing the URL **exactly**, so `url` has to match `spec.source.repoURL` in `application.yaml` character for character.

### 14. Credentials for the defense
`/home/vagrant/gitlab-creds.txt` (mode `600`) holds both URLs, the GitLab `root` password, the PAT and the Argo CD `admin` password. There's no tunnel helper to run: the forwards from step 11 are already up.

### 15–16. Apply the Application and print a summary
Applies `confs/application.yaml` (same auto-sync, `prune` and `selfHeal` policy as Part 3), then prints the pods, the Application status, the state of the two forward units, both URLs with their passwords, and the total provisioning time.

## Usage

```bash
cd bonus
vagrant up          # expect ~20-30 minutes on first boot
```

### Check the cluster

```bash
vagrant ssh
kubectl get ns                        # argocd, dev, gitlab
kubectl get pods -n gitlab
kubectl get application -n argocd     # playground: Synced / Healthy
curl http://localhost:8888/           # {"status":"ok", "message": "v1"}
```

### Open the web UIs

Nothing to start — the forwards come up with the VM (step 11). Straight from the host's browser:

| UI | URL | Login |
|---|---|---|
| GitLab | `http://192.168.56.120:8181` | `root` |
| Argo CD | `http://192.168.56.120:8080` | `admin` |
| Playground app | `http://192.168.56.120:8888` | — |

Both passwords are printed at the end of `vagrant up` and stored in the VM:

```bash
vagrant ssh -c "cat gitlab-creds.txt"
```

If a UI ever stops answering, the unit — not you — is what to look at:

```bash
vagrant ssh -c "systemctl status gitlab-forward argocd-forward"
vagrant ssh -c "sudo systemctl restart gitlab-forward"
```

GitLab is also reachable through the Ingress by adding `192.168.56.120 gitlab.mjeannin.com` to `/etc/hosts` on the host and opening `http://gitlab.mjeannin.com`.

### Demo: deploy v2 through GitLab

One terminal is enough — the working clone pushes through the permanent forward:

```bash
vagrant ssh
cd ~/playground
sed -i 's/playground:v1/playground:v2/' manifests/deployment.yaml
git commit -am "deploy v2"
git push
```

The commit can also be made in the GitLab web UI.

Within about a minute, Argo CD detects the new commit and rolls out the new version:

```bash
kubectl get pods -n dev -w
curl http://192.168.56.120:8888/     # {"status":"ok", "message": "v2"}
```

Credentials are in `/home/vagrant/gitlab-creds.txt` if you need them again.
