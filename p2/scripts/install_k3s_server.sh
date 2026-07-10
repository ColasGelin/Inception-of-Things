#!/bin/bash
set -e

apt-get update
apt-get install -y curl

curl -sfL https://get.k3s.io | sh -

mkdir -p /var/lib/rancher/k3s/server/manifests
cp /vagrant/apps.yaml /var/lib/rancher/k3s/server/manifests/apps.yaml
cp /vagrant/ingress.yaml /var/lib/rancher/k3s/server/manifests/ingress.yaml
