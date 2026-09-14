# Part 2: K3s and three simple applications

A single VM, built by Vagrant, running K3s. Three web applications (`app1`, `app2`, `app3`) are deployed on it and exposed through a single **Ingress** that routes each request according to its HTTP `Host` header.

## Architecture

```
Client
  |  Host: app1.com / app2.com / anything else
  v
192.168.56.110:80  (VM mjeanninS, K3s + Traefik ingress controller)
  |
  +-- host: app1.com  -> app1-service -> app1-deployment (1 pod)
  +-- host: app2.com  -> app2-service -> app2-deployment (3 pods, load-balanced)
  +-- no host match   -> app3-service -> app3-deployment (1 pod)
```

## Kubernetes objects involved

- A **Deployment** tells Kubernetes "keep N copies (replicas) of this container running". If a pod dies, the Deployment's ReplicaSet creates a new one.
- A **Service** gives a set of pods (selected by label, e.g. `app: app2`) a stable internal IP and DNS name, and load-balances between them. Pods come and go and change IPs; the Service stays the same.
- An **Ingress** is a set of HTTP routing rules (host/path → Service). It does nothing by itself: an **Ingress controller** has to read it and route the traffic. K3s ships **Traefik** as its built-in controller, listening on ports 80/443 of the node.

## Files

| File | Purpose |
|---|---|
| `Vagrantfile` | Defines the VM `mjeanninS` (IP `192.168.56.110`, Debian 13 (Trixie), provisioning script) |
| `scripts/install_k3s_server.sh` | Installs K3s and copies the manifests into K3s's auto-deploy directory |
| `confs/apps.yaml` | 3 Deployments + 3 Services |
| `confs/ingress.yaml` | Ingress rules mapping hostnames to Services, with a catch-all rule for app3 |

### `confs/apps.yaml`

Each app is a `Deployment` + `Service` pair:

- Image: `paulbouwer/hello-kubernetes:1.10`, a small web page that shows a message and the name of the pod serving the request.
- The `MESSAGE` environment variable sets the text for each app (`Hello from app1`, ...).
- The container listens on `8080`. The Service exposes it on port `80` (`port: 80` → `targetPort: 8080`).
- `app2-deployment` has `replicas: 3`, as the subject requires. Refresh `app2.com` a few times and the pod name on the page changes, showing that the Service load-balances between pods.

### `confs/ingress.yaml`

One `Ingress` named `ingress-apps` with `ingressClassName: traefik`:

| Rule | Backend |
|---|---|
| `host: app1.com`, path `/` | `app1-service:80` |
| `host: app2.com`, path `/` | `app2-service:80` |
| no `host`, path `/` | `app3-service:80` |

A rule without a `host` field matches **any** hostname. Traefik tries the more specific host rules first, so app3 only gets requests that match neither `app1.com` nor `app2.com`, including requests made straight to the IP.

## How manifests get applied

`kubectl apply` has to reach the Kubernetes API, which only exists inside the VM. Instead of SSH-ing in to apply the files by hand, the provisioning script copies `confs/apps.yaml` and `confs/ingress.yaml` (available in the VM under `/vagrant/confs` through Vagrant's default synced folder) into:

```
/var/lib/rancher/k3s/server/manifests/
```

K3s watches this directory and applies anything placed there. It also re-applies the files when they change and when the VM reboots. So there is no manual `kubectl apply` step and no need to wait for the API to be ready.

The script also symlinks `kubectl` to the `k3s` binary and starts K3s with `--write-kubeconfig-mode=644`, so `kubectl` works without `sudo`.

## Usage

Start the VM (this installs K3s and deploys everything):

```bash
cd p2
vagrant up
```

Check that everything is running:

```bash
vagrant ssh -c "kubectl get all,ingress"
```

You should see 5 pods in total (1 for app1, 3 for app2, 1 for app3), 3 Services and the Ingress.

Test the routing by setting the `Host` header (no need to edit `/etc/hosts`):

```bash
curl -H "Host: app1.com" http://192.168.56.110   # -> Hello from app1
curl -H "Host: app2.com" http://192.168.56.110   # -> Hello from app2
curl http://192.168.56.110                       # -> Hello from app3 (default)
```

To test from a browser, map the hostnames to the VM's IP in `/etc/hosts` on your host machine:

```
192.168.56.110 app1.com
192.168.56.110 app2.com
```

Try self-healing: delete a pod and watch Kubernetes replace it right away.

```bash
vagrant ssh -c "kubectl delete pod -l app=app2 --wait=false && kubectl get pods -w"
```

## Notes

- Workloads (`apps.yaml`) and routing (`ingress.yaml`) are in separate files by convention. Kubernetes doesn't require it.
- The VM gets 4 CPUs / ~4 GB RAM, which is more than enough for K3s plus five small pods.
