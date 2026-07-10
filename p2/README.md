# p2 — K3s Ingress

A single VirtualBox VM, provisioned with Vagrant, running a lightweight Kubernetes distribution (k3s). Three sample apps (`app1`, `app2`, `app3`) are deployed and exposed through a single Ingress that routes traffic based on the HTTP `Host` header.

## Architecture

```
Client
  |  Host: app1.com / app2.com / (anything else)
  v
192.168.56.110 (VM, k3s + Traefik ingress controller)
  |
  +-- host: app1.com  -> app1-service -> app1-deployment (displays "app1")
  +-- host: app2.com  -> app2-service -> app2-deployment (displays "app2")
  +-- (no host match)  -> app3-service -> app3-deployment (displays "app3")
```

- **Vagrant** creates the VM and syncs this project folder to `/vagrant` inside it.
- **k3s** is installed by a shell provisioner and comes with **Traefik** built in as the Ingress controller — no extra install needed.
- **Deployments/Services** (`apps.yaml`) run the actual workloads and expose them internally to the cluster.
- **Ingress** (`ingress.yaml`) is a routing rule set: it maps a `Host` header to a backend `Service`, without knowing anything about how that service is implemented.

## Files

| File | Purpose |
|---|---|
| `Vagrantfile` | Defines the VM (IP `192.168.56.110`, resources, provisioning script) |
| `scripts/install_k3s_server.sh` | Installs k3s and drops the manifests into k3s's auto-apply directory |
| `apps.yaml` | 3 Deployments + 3 Services (app1, app2, app3) |
| `ingress.yaml` | Ingress rules mapping hostnames to services, with a default (catch-all) backend |

## How manifests get applied

`kubectl apply` needs to run against the Kubernetes API, which only exists inside the VM. Instead of SSH-ing in and applying manually, the provisioning script copies `apps.yaml` and `ingress.yaml` (available via the Vagrant synced folder at `/vagrant`) into:

```
/var/lib/rancher/k3s/server/manifests/
```

k3s watches this directory continuously and applies/reconciles anything placed there automatically — including on every reboot — so no manual `kubectl apply` step or readiness wait is required.

## Usage

Start the VM (this installs k3s and deploys everything automatically):

```bash
cd p2
vagrant up
```

Check that everything is running:

```bash
vagrant ssh -c "sudo k3s kubectl get pods,svc,ingress"
```

Test routing by host (no need to edit `/etc/hosts`, just set the `Host` header):

```bash
curl -H "Host: app1.com" http://192.168.56.110   # -> app1
curl -H "Host: app2.com" http://192.168.56.110   # -> app2
curl http://192.168.56.110                       # -> app3 (default backend)
```

To test from a browser instead of curl, map the hostnames to the VM's IP on your host machine (`/etc/hosts`):

```
192.168.56.110 app1.com
192.168.56.110 app2.com
```

## Notes

- `ingressClassName: traefik` is set explicitly so the Ingress is picked up by k3s's built-in Traefik controller.
- Deployments/Services and Ingress rules are kept in separate files by convention (workloads vs. routing), even though Kubernetes doesn't require it — both are just applied from the same manifests directory.
