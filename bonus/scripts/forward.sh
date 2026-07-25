#!/bin/bash
vagrant ssh -c "kubectl -n gitlab port-forward --address 0.0.0.0 svc/gitlab-webservice-default 8181:8181"

#http://192.168.56.120:8181