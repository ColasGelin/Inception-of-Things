#!/bin/bash

SERVER_IP="192.168.56.110"

set -e

apt-get update && apt-get install -y net-tools curl

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --node-ip=${SERVER_IP} --tls-san=${SERVER_IP}" sh -

until [ -f /var/lib/rancher/k3s/server/node-token ]; do
  sleep 1
done

cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

chmod 644 /etc/rancher/k3s/k3s.yaml