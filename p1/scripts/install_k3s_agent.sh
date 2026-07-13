#!/bin/bash

SERVER_IP="192.168.56.110"
WORKER_IP="192.168.56.111"
TOKEN="mysecrettoken123"

set -e

apt-get update && apt-get install -y net-tools curl

curl -sfL https://get.k3s.io | \
  K3S_URL="https://${SERVER_IP}:6443" \
  K3S_TOKEN="${TOKEN}" \
  INSTALL_K3S_EXEC="agent --node-ip=${WORKER_IP}" \
  sh -