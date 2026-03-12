#!/usr/bin/env bash
# Create service account and RBAC for ClusterLogForwarder (Logging 6.x).
set -euo pipefail
oc create serviceaccount logcollector -n openshift-logging --dry-run=client -o yaml | oc apply -f -
oc adm policy add-cluster-role-to-user collect-application-logs system:serviceaccount:openshift-logging:logcollector
oc adm policy add-cluster-role-to-user collect-infrastructure-logs system:serviceaccount:openshift-logging:logcollector
oc adm policy add-cluster-role-to-user collect-audit-logs system:serviceaccount:openshift-logging:logcollector
oc adm policy add-cluster-role-to-user cluster-logging-write-application-logs system:serviceaccount:openshift-logging:logcollector
oc adm policy add-cluster-role-to-user cluster-logging-write-audit-logs system:serviceaccount:openshift-logging:logcollector
oc adm policy add-cluster-role-to-user cluster-logging-write-infrastructure-logs system:serviceaccount:openshift-logging:logcollector
