# Inception-of-Things

A hands-on introduction to **Kubernetes** from the 42 curriculum. The project goes step by step from a bare two-node cluster to a fully self-hosted GitOps pipeline: GitLab and Argo CD, both running inside the cluster they deploy to.

Everything runs in local virtual machines built by **Vagrant** on **VirtualBox**, so each part can be rebuilt from nothing with a single `vagrant up`.

---

## Why Kubernetes? A concrete example

Picture a large online store on **Black Friday**.

The platform isn't one program. It is a few hundred **microservices**: product catalog, search, cart, payment, recommendations, stock, email notifications and so on. Each one is packaged as a container image and runs as many copies, spread over a few hundred servers in several datacenters.

Without an orchestrator, a team of engineers would have to decide by hand which service runs on which machine, restart crashed processes, add servers when traffic goes up, and roll out new versions without taking the site down. Kubernetes automates all of this:

| Problem at scale | What Kubernetes does |
|---|---|
| **Traffic goes up 20x** at midnight | The *Horizontal Pod Autoscaler* sees the extra CPU load and scales `checkout` from 10 to 200 pods. The *Cluster Autoscaler* adds new servers from the cloud provider to hold them. When traffic drops, both scale back down, so you stop paying for idle machines. |
| **A server's hardware fails** | The control plane sees that the node is gone and reschedules its pods onto healthy nodes within seconds. Customers don't notice. |
| **A process crashes or hangs** | *Liveness probes* catch it and restart the container. *Readiness probes* stop traffic to a pod until it can actually serve requests. |
| **Shipping a new version of `payment`** mid-sale | A *rolling update* swaps pods a few at a time. If the new version fails its health checks, the rollout stops and can be rolled back with one command. |
| **Hundreds of services need to find each other** | Each *Service* gets a stable DNS name (`payment.shop.svc.cluster.local`) and load-balances across its pods, wherever they run. |
| **One public entry point for many apps** | An *Ingress* sends `shop.com/api/cart` to the cart service and `shop.com/search` to search, all behind one IP and one TLS certificate. |
| **Many teams share the same hardware** | *Namespaces*, *resource quotas* and *RBAC* keep team A's batch jobs from starving team B's checkout service. |
| **"What is actually running in production?"** | With **GitOps** (Argo CD), the desired state of every service lives in Git. Every change is a reviewed commit, the cluster syncs itself to match, and a rollback is just a `git revert`. |

The key idea is that **you describe the state you want** ("3 replicas of image `payment:v42`, reachable on port 80") and Kubernetes keeps working to make reality match. That model is what lets a handful of engineers run infrastructure at a scale that used to take whole operations departments.

This project covers each of those building blocks on a small scale:

- **Part 1**: a multi-node cluster (control plane + worker)
- **Part 2**: Deployments, replicas, Services and Ingress routing
- **Part 3**: GitOps with Argo CD (deploy by pushing to Git)
- **Bonus**: the whole pipeline self-hosted, with GitLab running inside the cluster

---

## Technologies

| Tool | Role in this project |
|---|---|
| **Vagrant** | Describes VMs as code (`Vagrantfile`) and provisions them with shell scripts |
| **VirtualBox** | Hypervisor that runs the VMs |
| **K3s** | Lightweight, certified Kubernetes distribution (single binary, ships Traefik and a service load balancer) |
| **K3d** | Runs K3s nodes as Docker containers, so a cluster can be created or destroyed in seconds |
| **kubectl** | Command-line client for the Kubernetes API |
| **Traefik** | Ingress controller bundled with K3s, routes HTTP traffic to Services |
| **Argo CD** | GitOps controller that keeps the cluster in sync with a Git repository |
| **Helm** | Package manager for Kubernetes, used to install GitLab and Argo CD in the bonus |
| **GitLab CE** | Self-hosted Git server, deployed inside the cluster in the bonus |

---

## Repository layout

```
.
├── p1/        Part 1: K3s cluster with a server and a worker (2 VMs)
├── p2/        Part 2: K3s + 3 web apps behind an Ingress (1 VM)
├── p3/        Part 3: K3d + Argo CD syncing from GitHub (1 VM)
└── bonus/     Bonus: K3d + Argo CD + self-hosted GitLab (1 VM)
```

Each directory is self-contained and has its own README explaining how it works:

- [`p1/README.md`](p1/README.md)
- [`p2/README.md`](p2/README.md)
- [`p3/README.md`](p3/README.md)
- [`bonus/README.md`](bonus/README.md)

---

## The parts at a glance

### Part 1: K3s and Vagrant

Two Debian VMs on a private network:

- `mjeanninS` (`192.168.56.110`) runs K3s in **server** mode (the control plane).
- `mjeanninSW` (`192.168.56.111`) runs K3s in **agent** mode and joins the server with a shared token.

Result: a real two-node Kubernetes cluster where `kubectl get nodes` lists both machines.

### Part 2: K3s and three simple applications

One VM (`192.168.56.110`) running K3s with three web apps. The built-in Traefik Ingress controller routes requests by their `Host` header:

- `app1.com` → app1
- `app2.com` → app2 (**3 replicas**)
- anything else → app3 (default backend)

The manifests are dropped into K3s's auto-deploy directory, so the apps come up without anyone running `kubectl apply`.

### Part 3: K3d and Argo CD

One VM (`192.168.56.120`) running Docker and a K3d cluster. Argo CD is installed with Helm in the `argocd` namespace and watches a **public GitHub repository**, deploying whatever it finds there into the `dev` namespace. To deploy `wil42/playground:v2` instead of `v1`, you change the image tag in GitHub and push. No `kubectl` needed.

The bootstrap is built like the bonus one: numbered phases, parallel tooling install, both app images pre-imported into the cluster, and a systemd unit that keeps the Argo CD UI forwarded to `192.168.56.120:8080` across reboots.

### Bonus: GitLab

Same idea as Part 3, but the Git server is also self-hosted: **GitLab CE is installed in the cluster with Helm**, in its own `gitlab` namespace. The bootstrap script creates the GitLab project, pushes the manifests to it, generates an access token and registers the repository with Argo CD, all automatically. The full loop (commit → GitLab → Argo CD → running pod) happens inside a single VM.

### Comparison

| | Part 1 | Part 2 | Part 3 | Bonus |
|---|---|---|---|---|
| VMs | 2 | 1 | 1 | 1 |
| Kubernetes | K3s | K3s | K3d (K3s in Docker) | K3d |
| Nodes | server + agent | server | server (container) | server (container) |
| How things get deployed | nothing deployed | K3s auto-deploy manifests | Argo CD ← GitHub | Argo CD ← GitLab (in-cluster) |
| Exposed on | `:6443` (API) | `:80` (Ingress) | `:8888` (app), `:8080` (Argo CD) | `:8888` (app), `:8080` (Argo CD), `:8181` (GitLab) |

---

## Prerequisites

- [VirtualBox](https://www.virtualbox.org/)
- [Vagrant](https://developer.hashicorp.com/vagrant)
- Enough resources for the part you run. The bonus VM asks for **5 CPUs and 5 GB RAM**, plus 4 GB of swap created inside the VM.
- An internet connection on first boot (boxes, K3s, container images, Helm charts)

On 42 school machines, move the VirtualBox and Vagrant storage to `goinfre` first (see `p3/IoT_commands_p3.md`).

## Quick start

```bash
cd p1        # or p2, p3, bonus
vagrant up   # build and provision the VM(s)
vagrant ssh  # open a shell in the VM (use `vagrant ssh mjeanninSW` for the p1 worker)
vagrant destroy -f   # tear everything down
```

The parts use overlapping IP addresses (`.110` for p1/p2, `.120` for p3/bonus), so run **one part at a time**.
