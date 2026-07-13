#!/bin/bash

SERVER_IP="192.168.56.110"
TOKEN="mysecrettoken123"

set -e

apt-get update && apt-get install -y net-tools curl

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --node-ip=${SERVER_IP} --tls-san=${SERVER_IP} --token=${TOKEN}" sh -