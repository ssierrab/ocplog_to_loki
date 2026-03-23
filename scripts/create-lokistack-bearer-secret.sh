#!/usr/bin/env bash
# Create Secret loki-stack-bearer-token in openshift-logging with a Bearer token for LokiStack gateway.
# Requires: logcollector SA (run serviceaccount.sh first). Uses oc create token when available.
set -euo pipefail
NAMESPACE=openshift-logging
SA=logcollector
SECRET_NAME=loki-stack-bearer-token

TOKEN=""
if TOKEN=$(oc create token "$SA" -n "$NAMESPACE" --duration=720h 2>/dev/null); then
  :
else
  # Legacy: kubernetes.io/service-account-token Secret linked to the SA
  for s in $(oc get sa "$SA" -n "$NAMESPACE" -o jsonpath='{.secrets[*].name}' 2>/dev/null); do
    if [[ "$(oc get secret "$s" -n "$NAMESPACE" -o jsonpath='{.type}' 2>/dev/null)" == "kubernetes.io/service-account-token" ]]; then
      TOKEN=$(oc get secret "$s" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
      break
    fi
  done
  if [[ -z "${TOKEN}" ]]; then
    echo "Could not create or find a token for serviceaccount/${SA} in ${NAMESPACE}." >&2
    echo "Ensure the SA exists (bash config/02-openshift-logging/serviceaccount.sh) and retry." >&2
    exit 1
  fi
fi

oc create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | oc apply -f -
echo "Secret ${SECRET_NAME} updated in ${NAMESPACE}."
