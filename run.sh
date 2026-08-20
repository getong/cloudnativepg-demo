#!/bin/sh

# wget -c https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.0/cnpg-1.30.0.yaml

kubectl apply --server-side -f cnpg-1.30.0.yaml

sleep 5

kubectl apply -f new-launch.yaml
