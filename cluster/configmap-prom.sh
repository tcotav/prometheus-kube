#!/bin/bash

set -e

# main prometheus config
PROMCONFIG=./prometheus.yml
# prometheus alert rule config
RULECONFIG=./kube.rules
# alertmanager config
AMCONFIG=./am-simple.yml

NAMESPACE=kube-system

# name of configmap in k8s
MAPNAME=cluster-prom-config

# comment this out if you don't want the alertmanager config
AMCONFIG_GEN=--from-file=am-config=${AMCONFIG}

TTEST=$( kubectl get configmaps --namespace=${NAMESPACE} | grep ${MAPNAME} | wc -l )

# half-ass update
if [ ${TTEST} -eq 1 ]; then
  # if it exists, delete it first and then recreate
  kubectl delete configmap ${MAPNAME} --namespace=${NAMESPACE}
fi

kubectl create configmap ${MAPNAME} --from-file=prom-config=${PROMCONFIG} --from-file=prom-rules=${RULECONFIG} ${AMCONFIG_GEN} --namespace=${NAMESPACE}

# then kill the pods causing them to spin up the controller
AMPOD=`kubectl get pods --namespace=${NAMESPACE} | grep "^am-cluster" | cut -d " " -f 1`
PROMPOD=`kubectl get pods --namespace=${NAMESPACE} | grep "^prom-cluster" | cut -d " " -f 1`

if [[ ! -z ${AMPOD} ]]; then
  kubectl delete pod ${AMPOD} --namespace=${NAMESPACE} 
fi

if [[ ! -z ${PROMPOD} ]]; then
  kubectl delete pod ${PROMPOD} --namespace=${NAMESPACE} 
fi

