# Part 3: K3d and Argo CD

One VM running **Docker**, a **K3d** cluster, and **Argo CD** inside it. Argo CD watches a **public GitHub repository** and deploys what it finds there, following the **GitOps** approach:

> Git is the single source of truth. To change what runs in the cluster, you change the repository, not the cluster.

This part is built exactly like the **bonus**, with one deliberate difference: the Git repository lives on **GitHub** instead of a GitLab instance running inside the cluster. Everything else — the phased bootstrap, Argo CD installed through Helm, the pre-imported images, the permanent port-forward — is the same machinery.

## Architecture

```
 GitHub: Maj-e/Inception-of-Things-CI        VM 192.168.56.120 (Ubuntu 22.04, 4 CPUs, 4 GB RAM)
 ┌──────────────────────────┐                ┌──────────────────────────────────────────────┐
 │ manifests/               │                │ Docker                                       │
 │   manifest.yaml (v1/v2)  │  polls /60s    │ └─ k3d cluster "p3-cluster"                  │
 │   service.yaml           │◄───────────────│    ├─ namespace argocd                       │
 └──────────────────────────┘                │    │    Argo CD (Helm)                       │
            ▲                                │    │    Application "playground"             │
            │ git push                       │    │          │ applies                      │
         developer                           │    │          ▼                              │
                                             │    └─ namespace dev                          │
                                             │         wil-playground (wil42/playground)    │
                                             │                                              │
                                             │ k3d load balancer :8888 ──► svc wil-playground│
                                             │ argocd-forward     :8080 ──► svc argocd-server│
                                             └──────────────────────────────────────────────┘
                                                     ▲                    ▲
                            curl http://192.168.56.120:8888    http://192.168.56.120:8080
```

## K3s vs K3d

- **K3s** (Parts 1 and 2) is installed directly on the operating system as a systemd service.
- **K3d** runs K3s **inside Docker containers**: each Kubernetes node is a container. Creating or deleting a cluster takes seconds and leaves nothing behind on the host, which is why it's popular for local development and CI. K3d also starts a small load-balancer container that publishes chosen ports from the cluster onto the host — that's how the app ends up on `192.168.56.120:8888`.

## Files

| File | Purpose |
|---|---|
| `Vagrantfile` | One Ubuntu 22.04 VM, IP `192.168.56.120`, 4 CPUs / 4 GB RAM, `confs/` and `scripts/` rsynced to `/vagrant`, host DNS resolver instead of VirtualBox's NAT proxy |
| `scripts/bootstrap.sh` | Provisions everything in numbered phases: tooling, cluster, images, Argo CD, port forward, Application |
| `confs/argocd-values.yaml` | Helm values for Argo CD: small resource requests, unused components off, plain HTTP UI, 60s sync interval |
| `confs/application.yaml` | The Argo CD `Application`: which repo to watch and where to deploy it |
| `confs/manifests/manifest.yaml` | Reference copy of what lives in the GitHub repo: the `wil-playground` Deployment |
| `confs/manifests/service.yaml` | Reference copy: the `LoadBalancer` Service on port 8888 |
| `IoT_commands_p3.md` | Notes for moving VirtualBox and Vagrant storage to `goinfre` on 42 machines |

`confs/manifests/` is **documentation, not input**. Argo CD reads the copies on GitHub; these exist so the manifests being deployed are visible without leaving the project.

## How the bootstrap works

`scripts/bootstrap.sh` runs in numbered phases. Long steps run behind a spinner; if one fails, its full output is printed, so nothing is lost.

### 1. Wait for network
Provisioning starts the moment `sshd` answers, which can be before DNS works. The script loops until `github.com` responds — a few seconds of waiting instead of a confusing failure three phases later.

### 2. Tooling
Docker, `kubectl`, `k3d` and Helm, each only if it's missing, and **in parallel**: the phase costs its slowest branch rather than the sum of the four.

Docker comes from its apt repository directly rather than `get.docker.com`, which skips `docker-buildx-plugin` and `docker-compose-plugin` (~120 MB nothing here invokes). The repository URL is built from `$ID` in `/etc/os-release`, so it works on a Debian box as well as an Ubuntu one; if anything about that fails, the script falls back to the official convenience script.

### 3. Helm repository (in the background)
Adding the `argo` chart repo is a network fetch, creating the cluster is local Docker work, and neither needs the other — so the repo downloads while the cluster boots and is collected just before the chart is needed.

### 4. The cluster

```bash
k3d cluster create p3-cluster \
  -p "8888:8888@loadbalancer" \                     # the playground app
  --k3s-arg "--disable=metrics-server@server:0" \
  --k3s-arg "--disable=traefik@server:0" \          # nothing left for it to route
  --wait
```

`-p "8888:8888@loadbalancer"` publishes port 8888 of the k3d load-balancer container on port 8888 of the VM. Inside the cluster, the `wil-playground` Service is a `LoadBalancer` on 8888, handled by K3s's own `servicelb`. That chain is what makes `http://192.168.56.120:8888` work.

Traefik is disabled because nothing here publishes an Ingress: the app is a `LoadBalancer` and the Argo CD UI comes through the port-forward of step 9. Dropping it (and metrics-server) removes a Helm-install Job, two pods and two image pulls.

The kubeconfig is copied to `/home/vagrant/.kube/config`, so `kubectl` works without `sudo` after `vagrant ssh`.

### 5. Pre-import every image

This phase exists because of a measured ten-minute stall. **Nothing is pulled from inside the cluster**: every image is fetched on the VM with Docker, which uses the host's resolver, and side-loaded into the k3d node with `k3d image import`.

In-cluster pulls go through CoreDNS → the VirtualBox NAT resolver, which fails under load with `lookup registry-1.docker.io: Try again`. On one run that hit `rancher/mirrored-pause:3.6` — the sandbox image **every** pod needs before any container starts. CoreDNS couldn't start either, so the cluster could not recover on its own, Argo CD's Helm pre-install hook never got a pod, and `helm --wait` burned its entire 600-second budget before the retry succeeded. Two thirds of that boot was one failed DNS lookup.

The list is discovered, not hardcoded:

| Image | Where it comes from |
|---|---|
| `rancher/mirrored-pause:3.6` | read out of the node's containerd config, with a fallback |
| `quay.io/argoproj/argocd`, `redis` | `helm template argo/argo-cd` with our own values, so the tags always match the chart |
| `wil42/playground:v1` and `v2` | both tags, so the v1 → v2 demo is instant and needs no network |

The sandbox image is imported **first, on its own**. CoreDNS is already trying to start by then and cannot until that image is on the node; it is a few hundred kilobytes, so putting it ahead of Argo CD's ~400 MB unblocks the cluster minutes earlier.

Both waves are non-fatal. If a pull fails, the cluster falls back to pulling the image itself — the old, slow way — instead of failing the provision.

### 6. Namespaces
`argocd` and `dev`, created with `--dry-run=client -o yaml | kubectl apply -f -`, the idempotent way to say "create it if it doesn't exist".

### 7. Argo CD (Helm)
Part 3 could install Argo CD from the stock `install.yaml`, but Helm is how the bonus does it and it's what makes `confs/argocd-values.yaml` possible:

- **smaller resource requests** — the scheduler just needs to be told these pods are cheap
- **`notifications` and `dex` off**, ApplicationSet controller at **`replicas: 0`** — features nothing here uses. (`applicationSet.enabled` no longer exists as of chart 10.x; the Deployment is always rendered, so zero replicas is the only lever.)
- **`server.insecure: true`** — the UI is served over plain **HTTP**, so the browser needs no self-signed-certificate exception
- **`timeout.reconciliation: 60s`** — Argo CD checks Git every minute instead of every three, which is what makes the demo short enough to watch
- **probe `timeoutSeconds: 5`, `failureThreshold: 6`** on `server` and `repoServer` — the chart allows each health check 1 second, and three misses kill the container. During provisioning the VM is pulling and importing images while Argo CD starts, and `argocd-repo-server`'s `/healthz?full=true` takes longer than a second under that load. Left at the default it crash-loops, and a dead repo-server is what produces `failed to generate manifest ... connection refused` in the UI.

Installed with `--wait`, unlike the bonus: there is no GitLab to overlap with here, and everything after this point talks to the Argo CD API.

The timeout is **240s, not 600s**. Step 5 already put every image on the node, so there is nothing legitimately slow left; if an attempt does get stuck, retrying it is better than waiting on it. The `retry 3` wrapper is unchanged, so the worst case is barely different while the common case recovers in four minutes instead of ten.

The `argocd` CLI — a convenience for the defense the script never calls — downloads in the background during this phase.

### 8. Collect the argocd CLI download
`wait` on that branch. Non-fatal: the CLI is a convenience, not a dependency, so a failed download prints a warning and provisioning continues.

### 9. Permanent port forwarding (systemd)
The app is reachable on its own — k3d publishes 8888 on the VM — but the Argo CD UI lives inside the cluster, and the VM is not on the pod network. A `kubectl port-forward` is the only way in, so instead of opening one by hand for every demo the bootstrap installs it as a systemd unit:

```ini
# /etc/systemd/system/argocd-forward.service
[Service]
Environment=KUBECONFIG=/root/.kube/config
ExecStartPre=/bin/bash -c 'until kubectl -n argocd get svc argocd-server >/dev/null 2>&1; do sleep 5; done'
ExecStart=/usr/local/bin/kubectl port-forward --address 0.0.0.0 -n argocd svc/argocd-server 8080:80
Restart=always
RestartSec=5
```

- **`--address 0.0.0.0`** — the forward listens on every interface, so the host reaches it at `192.168.56.120`, not just `localhost` inside the VM.
- **`Restart=always`** — a `port-forward` is bound to one pod and dies with it; systemd reopens it seconds later, so a rescheduled Argo CD pod isn't a dead link.
- **`enable` + `ExecStartPre`** — the unit starts again when the VM reboots, and waits for the cluster to come back instead of restart-looping in the meantime.

Port **80**, not 443: `server.insecure` means the UI is plain HTTP.

### 10. Repository credentials — only for a private repo
The repository is public, so Argo CD clones it anonymously and this phase is a no-op. If the repo ever becomes private, write a GitHub personal access token (scope `repo`) to `confs/github-token` and re-provision; the bootstrap then creates the Secret Argo CD looks for:

```yaml
metadata:
  labels:
    argocd.argoproj.io/secret-type: repository   # this label is how Argo CD finds it
stringData:
  type: git
  url: https://github.com/Maj-e/Inception-of-Things-CI.git
  username: git
  password: <PAT>
```

Argo CD matches credentials to Applications by comparing the URL **exactly**, so `url` has to equal `spec.source.repoURL` character for character. `confs/github-token` is in `.gitignore`.

### 11. The Argo CD Application (`confs/application.yaml`)

```yaml
source:
  repoURL: https://github.com/Maj-e/Inception-of-Things-CI.git
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

The controller renders everything under `manifests/` and compares it with what runs in `dev`:

- Git and cluster match → the app is **Synced**.
- A new commit lands → the app goes **OutOfSync**, and because `automated` is on, Argo CD applies it right away.
- Someone edits the cluster by hand (`kubectl scale ...`) → `selfHeal` puts it back to what Git says.

### 12. Wait for the first sync
Provisioning shouldn't end with "it'll probably converge". The script blocks until the app actually answers on `:8888`, which covers the clone from GitHub, the sync, the scheduling and the LoadBalancer in a single check.

While waiting it re-sends `argocd.argoproj.io/refresh=hard` once a minute. Argo CD **caches a failed comparison** on the Application, so if the repo-server was unavailable at the moment of the first attempt, the error stays on screen even after the repo-server recovers — until something asks for a refresh.

It's non-fatal: on a timeout everything is still declared and Kubernetes keeps converging, so the script says so and prints the refresh command instead of failing a cluster that is merely slow.

### 13–14. Credentials and summary
`/home/vagrant/argocd-creds.txt` (mode `600`) holds the UI URL and the `admin` password. The final phase prints the pods, the Application status, the state of the forward unit, both URLs and the total provisioning time.

## The application

`wil42/playground` is a tiny HTTP server on port 8888 that returns its version. Two tags exist, `v1` and `v2`, so a deployment is easy to see.

## Usage

```bash
cd p3
vagrant up          # the Argo CD password is printed at the end
```

Expect roughly **5–8 minutes** on a first boot, most of it downloading Argo CD's container image. The script prints a timestamped marker per phase and a total at the end, so a run that goes long says where it went.

### Check the cluster

```bash
vagrant ssh
kubectl get ns                        # argocd and dev exist
kubectl get pods -n argocd
kubectl get pods -n dev
kubectl get application -n argocd     # playground: Synced / Healthy
curl http://localhost:8888/           # {"status":"ok", "message": "v1"}
```

From the host, the same app:

```bash
curl http://192.168.56.120:8888/
```

### Open the Argo CD UI

Nothing to start — the forward comes up with the VM (step 9). From the host's browser:

| UI | URL | Login |
|---|---|---|
| Argo CD | `http://192.168.56.120:8080` | `admin` |
| Playground app | `http://192.168.56.120:8888` | — |

The password is printed at the end of `vagrant up` and kept in the VM:

```bash
vagrant ssh -c "cat argocd-creds.txt"
# or straight from the cluster:
vagrant ssh -c "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
```

### Troubleshooting

**The UI shows `Failed to load target state: ... dial tcp <ip>:8081: connect: connection refused`.**
That IP is `argocd-repo-server`, the pod that renders the manifests. The message is cached from the last comparison attempt and does not clear itself, so check whether the pod is actually still down:

```bash
vagrant ssh -c "kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-repo-server"
```

Once it's `Running` and stable, force the controller to retry:

```bash
vagrant ssh -c "kubectl -n argocd annotate app playground argocd.argoproj.io/refresh=hard --overwrite"
```

**A change to `confs/` seems to have no effect.** `vagrant provision` uploads the provisioning script directly but does **not** re-sync the rsync folders, so the VM keeps the old `confs/`. Run `vagrant rsync && vagrant provision`, or `vagrant reload --provision`.

**The UI stops answering.** The unit — not you — is what to look at:

```bash
vagrant ssh -c "systemctl status argocd-forward"
vagrant ssh -c "sudo systemctl restart argocd-forward"
```

### Demo: deploy v2 with a git push

The change happens on GitHub, in `Maj-e/Inception-of-Things-CI` — from a clone on your machine, or directly in GitHub's web editor:

```bash
git clone https://github.com/Maj-e/Inception-of-Things-CI
cd Inception-of-Things-CI
sed -i 's/playground:v1/playground:v2/' manifests/manifest.yaml
git commit -am "deploy v2"
git push
```

Argo CD notices within about a minute (or click **Refresh** in the UI), then:

```bash
vagrant ssh -c "kubectl get pods -n dev -w"    # the old pod is replaced
curl http://192.168.56.120:8888/
# {"status":"ok", "message": "v2"}
```

Both image tags were pre-imported into the cluster in step 5, so the new pod starts without pulling anything.

Change the tag back to `v1` to roll back — the rollback is just another commit.

## Differences from the bonus

| | Part 3 | Bonus |
|---|---|---|
| Git host | GitHub (public, remote) | GitLab CE, in-cluster |
| Repo URL Argo CD uses | `https://github.com/...` | `http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/...` |
| Credentials | none (public repo) | PAT minted by the bootstrap, stored in a repository Secret |
| Namespaces | `argocd`, `dev` | `argocd`, `dev`, `gitlab` |
| VM | 4 CPUs / 4 GB | 5 CPUs / 5 GB + 4 GB swap (GitLab is memory-hungry) |
| Where you commit | on GitHub, from anywhere | in the VM, `~/playground`, pushing through the port-forward |
| First `vagrant up` | a few minutes | 20–30 minutes |
