# Inception-of-Things — Part 3 Commands (Steps 1–5)

> Progress so far: VM prep → K3d cluster → namespaces → Argo CD installed and healthy.
> This doc will be updated/extended as we complete Steps 6+ (GitHub repo, Argo CD Application, sync test) and the Bonus (GitLab).

---

## Step 1 — VM prep (install.sh)

```bash
#!/bin/bash
set -e

# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

# kubectl
KVER=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# k3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

**Test:**
```bash
docker ps
kubectl version --client
k3d version
```

---

## Step 2 — Create the K3d cluster

```bash
k3d cluster create iot-cluster --servers 1 --agents 1
```

**Test:**
```bash
docker ps
kubectl get nodes
kubectl cluster-info
```

---

## Step 4 — Namespaces

```bash
kubectl create namespace argocd
kubectl create namespace dev
```

**Test:**
```bash
kubectl get ns
```

---

## Step 5 — Install Argo CD

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

**Test:**
```bash
kubectl -n argocd get pods -w
```

**Access the UI:**
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```
Then visit `https://localhost:8080` (accept self-signed cert warning).

**Get admin password:**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
```
Username: `admin`

---

## Troubleshooting — Disk pressure (node taint blocking pod scheduling)

Symptom: pods stuck `Pending`, node had taint `node.kubernetes.io/disk-pressure:NoSchedule`.

```bash
# Diagnose
kubectl -n argocd describe pod <pod-name>
kubectl describe node k3d-iot-cluster-server-0 | grep -A 3 Taints
df -h
docker system df

# Clean up Docker
docker system prune -a

# Clean up unused Vagrant VM instances/boxes
vagrant destroy -f
vagrant box list
vagrant box remove debian/trixie64

# Find and remove orphaned libvirt disk images (the actual space hogs)
sudo du -sh /var/lib/libvirt/images/* 2>/dev/null | sort -rh
sudo rm /var/lib/libvirt/images/debian-VAGRANTSLASH-trixie64_vagrant_box_image_13.20260519.1_box.img
sudo rm /var/lib/libvirt/images/Inception-of-Things_cgelinS.img
sudo rm /var/lib/libvirt/images/Inception-of-Things_cgelinSW.img

# Recheck
df -h
kubectl describe node k3d-iot-cluster-server-0 | grep -A 3 Taints
kubectl -n argocd get pods
```

**Note:** Do NOT remove the `debian/bookworm64` Vagrant box if p1/p2 still need it — only destroy the VM *instances* between uses (`vagrant destroy -f`), keep the box cached so `vagrant up` works offline/fast at defense time.

---

## Troubleshooting — Crash-looping pod

```bash
kubectl -n argocd logs <pod-name>
kubectl -n argocd describe pod <pod-name>
kubectl -n argocd delete pod <pod-name>   # Deployment recreates it automatically
kubectl -n argocd get pods -w
```

---

## Housekeeping between sessions (p1/p2)

```bash
# When done testing p1/p2:
cd p1 && vagrant destroy -f
cd ../p2 && vagrant destroy -f

# To bring them back up for testing/defense:
cd p1 && vagrant up
```

---

*(To be continued: Step 6 — GitHub repo + app manifests, Step 7 — Argo CD Application resource, Step 8-9 — deploy & v1→v2 sync test, Bonus — GitLab.)*
