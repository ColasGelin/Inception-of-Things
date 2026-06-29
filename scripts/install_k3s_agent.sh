#!/bin/bash

SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"

until [ -f /vagrant/node-token ]; do
  sleep 1
done

TOKEN=$(cat /vagrant/node-token)

curl -sfL https://get.k3s.io | \
  K3S_URL="https://${SERVER_IP}:6443" \
  K3S_TOKEN="${TOKEN}" \
  INSTALL_K3S_EXEC="agent --node-ip=${WORKER_IP}" \
  sh -