#!/usr/bin/env bash
# Create Secret loki-external-bearer-token on this cluster (spoke) for external Loki auth.
# The value must be a Bearer token the HUB Loki gateway accepts (create on hub, e.g. oc create token ...).
set -euo pipefail
NAMESPACE=openshift-logging
SECRET_NAME=loki-external-bearer-token

if [[ -n "${EXTERNAL_LOKI_BEARER_TOKEN:-}" ]]; then
  TOKEN=$EXTERNAL_LOKI_BEARER_TOKEN
else
  read -r -s -p "Paste hub Loki bearer token: " TOKEN
  echo
fi

if [[ -z "${TOKEN}" ]]; then
  echo "Token is empty." >&2
  exit 1
fi

oc create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | oc apply -f -
echo "Secret ${SECRET_NAME} updated in ${NAMESPACE}."
