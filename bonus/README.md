# Bonus: GitLab

Part 3, but **fully self-hosted**: the Git repository Argo CD watches no longer lives on GitHub. It lives in a **GitLab CE instance running inside the same Kubernetes cluster**. Once the VM is up, the whole GitOps loop (commit → push → sync → new pod) runs locally, and nothing is pulled from a public Git host.

## Architecture

```
VM 192.168.56.120 (Ubuntu 22.04, 5 CPUs, 5 GB RAM + 4 GB swap)
└─ Docker
   └─ k3d cluster "p3-cluster"
      │
      ├─ namespace gitlab ─────────────────────────────────────────────┐
      │   GitLab CE (Helm chart 9.9.2 = GitLab 18.9), stripped to      │
      │   four pods: webservice (Rails + Workhorse :8181), gitaly,     │
      │   postgresql, redis  — plus two one-shot Jobs                  │
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

k3d load balancer:  VM :8888 → playground Service (k3s servicelb)

systemd port-forwards (started at boot, see step 11):
                    VM :8181 → svc/gitlab-webservice-default   (GitLab UI)
                    VM :8080 → svc/argocd-server               (Argo CD UI)
```

The key point: **Argo CD reaches GitLab through the cluster's internal DNS** (`<service>.<namespace>.svc.cluster.local`), the same way microservices talk to each other in production.

## Files

| File | Purpose |
|---|---|
| `Vagrantfile` | One Ubuntu 22.04 VM, IP `192.168.56.120`, 5 CPUs / 5 GB RAM, `confs/` rsynced to `/vagrant/confs` |
| `scripts/bootstrap.sh` | Provisions everything: tooling, cluster, Argo CD, GitLab, project, token, repo registration |
| `confs/argocd-values.yaml` | Helm values for Argo CD: small resource requests, unused components disabled, 60s sync interval |
| `confs/gitlab-values.yaml` | Helm values for GitLab: every component that isn't needed to serve one repo over HTTP, switched off |
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
Installs `git`, Docker, `kubectl`, `k3d` and `helm`, each only if it's missing — and **in parallel**. `git` and Docker share one branch because both go through `apt` and dpkg holds an exclusive lock; `kubectl`, `k3d` and `helm` are plain binary downloads and run alongside. The phase costs its slowest branch rather than the sum of all five.

### 4. Helm repositories
Adds the `gitlab` and `argo` chart repositories (with retries).

### 5. k3d cluster
```bash
k3d cluster create p3-cluster \
  -p "8888:8888@loadbalancer" \                     # playground app
  --k3s-arg "--disable=metrics-server@server:0" \   # one less component eating RAM
  --k3s-arg "--disable=traefik@server:0" \          # nothing left for it to route
  --wait
```

Traefik is gone because GitLab no longer publishes an Ingress (step 10) and the playground Service is a `LoadBalancer` handled by K3s's own `servicelb`. That removes a Helm-install Job, a pod and an image pull. Port 80 goes with it.

### 6. Pre-import images (in the background)
`wil42/playground:v1` and `v2` are pulled **on the VM** and loaded into the k3d node with `k3d image import`. With GitLab running, the VM is short on memory, CoreDNS can get flaky, and in-cluster pulls from Docker Hub can fail. Pre-loading them makes the v1 → v2 demo independent of the network and of Docker Hub rate limits.

Nothing needs these images until Argo CD syncs, several minutes later, so the download is **started here and collected in step 10**, overlapping GitLab's startup instead of sitting in front of it. The `argocd` CLI — a convenience for the defense, never used by the script — rides along in the same background branch.

### 7. Namespaces
Creates `gitlab`, `argocd` and `dev` (idempotently).

### 8. GitLab (Helm) — first, and deliberately without `--wait`

GitLab is the long pole: database migrations plus a Rails boot that nothing can shorten. `helm upgrade --install` **without** `--wait` returns as soon as the objects exist, so the cluster starts pulling images and migrating while the script goes on to install Argo CD and collect the background downloads. Waiting on the whole release would have serialised all of that behind it.

The readiness gate hasn't disappeared, it has *moved* — to step 12, where the script polls `/api/v4/version`. That is both the thing we actually depend on and a tighter condition than "every pod in the release is ready".

#### What `gitlab-values.yaml` leaves running

This instance has one job: host `root/playground` over HTTP. Every component off that path is switched off, because each one is an image to pull *and* memory the webservice has to compete for — and memory pressure is what makes the first boot slow, as Rails gets pushed into swap.

| Turned off | What it is | Why we don't need it |
|---|---|---|
| `gitlab.sidekiq` | background job runner | Creating the project and writing the repository both happen synchronously through Rails and Gitaly; Argo CD clones from Gitaly. The single biggest win — close to a gigabyte |
| `gitlab.toolbox` | backup / rails-console pod | The bootstrap drives GitLab through the REST API |
| `global.minio` | object storage | Only backs LFS, artifacts, uploads and packages, all disabled |
| `global.kas` | agent server for the k8s integration | Argo CD is what talks to the cluster here |
| `global.ingress` | Ingress objects | The UI comes through the port-forward, Argo CD through cluster DNS |
| `gitlab.gitlab-shell` | SSH access | Git over HTTP only |
| `gitlab.gitlab-exporter`, `postgresql.metrics` | Prometheus exporters | Prometheus is off; the exporter was a sidecar running for nothing |
| `registry`, `gitlab-pages`, `gitlab-runner`, `gitlab-zoekt`, `upgradeCheck`, `certmanager` | registry, Pages, CI, code search, version check, TLS | None of it is on the path |

Disabling MinIO **forces** `appConfig.lfs/artifacts/uploads/packages.enabled: false`: the chart refuses to render otherwise ("the `connection` property can not be empty"). What's left is `webservice` (Rails + Workhorse), `gitaly`, `postgresql`, `redis`, and the `migrations` and `shared-secrets` Jobs.

Rendering the chart before and after:

| | pods | Jobs | Ingresses | distinct images |
|---|---|---|---|---|
| before | 8 | 4 | 3 | 14 |
| after | **4** | **2** | **0** | **9** |

The webservice is then *given back* some of what the others freed — `requests: 1Gi`, `limits: 2Gi`. A tight limit is a false economy here: an OOMKill costs a two-minute restart.

> One knob in that table carries real risk: **Sidekiq**. It should be safe — nothing we do depends on background jobs — but rather than trust that, step 12 verifies after the push that GitLab really serves the manifests back. If it ever doesn't, the provision fails right there with the fix attached: set `gitlab.sidekiq.enabled: true` and re-run `vagrant provision`.

### 9. Argo CD (Helm) — while GitLab boots
`argocd-values.yaml`:
- lowers the resource requests so the scheduler can fit everything
- disables `notifications` and `dex` (SSO), and runs the ApplicationSet controller at `replicas: 0` (chart 10.x dropped `applicationSet.enabled`), none of which are used here
- raises the `server` and `repoServer` probe budget to `timeoutSeconds: 5` / `failureThreshold: 6`: the chart allows 1 second per health check, and on a VM that is simultaneously booting GitLab, `argocd-repo-server` misses three in a row and gets killed
- sets `server.insecure: true` so the UI is served over plain HTTP
- sets `timeout.reconciliation: 60s` so Argo CD checks Git every minute instead of every 3

### 10. Collect the background downloads
`wait` on the branch started in step 6. By now it has almost always finished, so this costs nothing — it exists to turn a failed download into a clear error instead of a mysterious `ImagePullBackOff` later.

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
This is where the script finally blocks on GitLab, through the forward from step 11:

1. **Wait for the API**: polls `/api/v4/version` until it returns `401`. That means Rails has booted and is refusing an unauthenticated request. A connection error or a `502` means it's still starting.
2. **Personal access token (PAT)**: GitLab 19 removed the OAuth password grant, so the root password can't be traded for an API token anymore. The script generates a random 20-character token and registers it for `root` with `gitlab-rails runner` inside the toolbox pod (scopes `api`, `read_repository`, `write_repository`, valid one year).
3. **Project**: creates the public project `root/playground` if it doesn't exist yet.
4. **Push**: builds a Git repo in `/home/vagrant/playground` with the manifests from `confs/manifests/` and pushes it to `main`. The clone is kept as a working copy for the demo.
5. **Verify**: asks the API for `manifests/deployment.yaml` at `ref=main` and requires a `200`. This proves the push landed somewhere Argo CD can clone from, and is what backs the decision to run without Sidekiq — a failure surfaces here, during provisioning, not on defense day.

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
