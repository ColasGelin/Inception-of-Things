#!/bin/bash
set -e

SERVER_IP="192.168.56.110"

apt-get update && apt-get install -y net-tools curl

curl -sfL https://get.k3s.io | \
INSTALL_K3S_EXEC="server --node-ip=${SERVER_IP} --tls-san=${SERVER_IP}" \
sh -

ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl

mkdir -p /var/lib/rancher/k3s/server/manifests
cp /vagrant/apps.yaml /var/lib/rancher/k3s/server/manifests/apps.yaml
cp /vagrant/ingress.yaml /var/lib/rancher/k3s/server/manifests/ingress.yaml
