# Part 1: K3s and Vagrant

Two virtual machines, built by Vagrant, that together form a **two-node Kubernetes cluster** using K3s:

- one **server** node (control plane)
- one **agent** node (worker)

No applications are deployed in this part. The goal is to understand how a cluster is put together and how nodes join it.

## Architecture

```
                 private network 192.168.56.0/24
   ┌─────────────────────────────┐        ┌─────────────────────────────┐
   │ mjeanninS   192.168.56.110  │        │ mjeanninSW  192.168.56.111  │
   │                             │        │                             │
   │ k3s server                  │◄───────│ k3s agent                   │
   │  - API server  :6443        │ joins  │  - kubelet                  │
   │  - scheduler / controllers  │ with   │  - container runtime        │
   │  - datastore                │ token  │  - kube-proxy               │
   │  - kubectl                  │        │                             │
   └─────────────────────────────┘        └─────────────────────────────┘
```

- The **server** runs the Kubernetes control plane: the API server, the scheduler, the controllers and the datastore. It is also a node itself, so it can run pods.
- The **agent** only runs the components needed to execute workloads (kubelet, containerd, networking). It registers with the server's API at `https://192.168.56.110:6443`.

## Files

| File | Purpose |
|---|---|
| `Vagrantfile` | Defines both VMs: names, hostnames, IPs, 1 CPU / 1 GB RAM each, Debian 13 (Trixie) box, provisioning script |
| `scripts/install_k3s_server.sh` | Installs K3s in server mode on `mjeanninS` |
| `scripts/install_k3s_agent.sh` | Installs K3s in agent mode on `mjeanninSW` and points it at the server |

## How it works

### 1. Vagrant creates the machines

The `Vagrantfile` declares two machines with `config.vm.define`. Both use the `bento/debian-13` box and get a static IP on a VirtualBox **host-only private network**, so they can reach each other and the host can reach them. The machine names follow the subject: the login followed by `S` (server) or `SW` (server worker).

Vagrant brings the machines up in the order they are declared: server first, then worker. The agent needs this, because it can only join once the server's API is listening.

### 2. The server installs K3s

`install_k3s_server.sh` runs the official installer with:

```bash
INSTALL_K3S_EXEC="server --node-ip=192.168.56.110 --tls-san=192.168.56.110 --token=mysecrettoken123 --write-kubeconfig-mode=644"
```

- `--node-ip` makes K3s advertise the private-network IP. Vagrant VMs also have a NAT interface (`10.0.2.15`) that is **identical on every VM**. Without this flag the nodes would advertise that address and couldn't talk to each other.
- `--tls-san` adds the IP to the API server's TLS certificate, so clients connecting to `192.168.56.110` trust it.
- `--token` sets a known shared secret that the agent uses to authenticate when it joins.
- `--write-kubeconfig-mode=644` makes the kubeconfig readable by every user, so `kubectl` works without `sudo`.

The installer also creates a `kubectl` symlink, sets up a systemd service (`k3s`) and writes the kubeconfig to `/etc/rancher/k3s/k3s.yaml`.

### 3. The worker joins the cluster

`install_k3s_agent.sh` runs the same installer with:

```bash
K3S_URL="https://192.168.56.110:6443"
K3S_TOKEN="mysecrettoken123"
INSTALL_K3S_EXEC="agent --node-ip=192.168.56.111"
```

Because `K3S_URL` is set, the installer sets the node up as an **agent** (systemd service `k3s-agent`). It contacts the server, authenticates with the token, and registers itself as a node.

> The token is hard-coded to keep the setup reproducible without passing files between VMs. On a real cluster it would be a generated secret handed over securely.

## Usage

```bash
cd p1
vagrant up
```

Check the cluster from the server:

```bash
vagrant ssh mjeanninS
kubectl get nodes -o wide
```

Expected output (both nodes `Ready`, each with its private IP):

```
NAME         STATUS   ROLES                  AGE   VERSION        INTERNAL-IP
mjeannins    Ready    control-plane,master   2m    v1.xx.x+k3s1   192.168.56.110
mjeanninsw   Ready    <none>                 1m    v1.xx.x+k3s1   192.168.56.111
```

Other useful checks:

```bash
ip a                                  # the private IP on each VM (interface name depends on the box, e.g. eth1 or enp0s8)
sudo systemctl status k3s             # on the server
sudo systemctl status k3s-agent       # on the worker (vagrant ssh mjeanninSW)
kubectl get pods -A              # system pods (CoreDNS, Traefik, ...)
```

Tear down:

```bash
vagrant destroy -f
```
