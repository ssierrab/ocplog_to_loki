#!/usr/bin/env bash
# SPOKE: create/update Secret to-loki-secret (token + ca-bundle.crt) for external Loki on hub.
# Prerequisites on HUB: remote-log-writer SA + RBAC, then long-lived token (see README).
#
# Usage:
#   TO_LOKI_TOKEN='<jwt>' HUB_LOKI_CA_FILE=./hub-service-ca.crt ./scripts/create-to-loki-secret.sh
# Legacy env: EXTERNAL_LOKI_BEARER_TOKEN is accepted as alias for TO_LOKI_TOKEN.
set -euo pipefail
NAMESPACE=openshift-logging
SECRET_NAME=to-loki-secret

TOKEN="${TO_LOKI_TOKEN:-${EXTERNAL_LOKI_BEARER_TOKEN:-}}"
if [[ -z "${TOKEN}" ]]; then
  read -r -s -p "Paste hub token (raw JWT, optional 'Bearer ' prefix will be stripped): " TOKEN
  echo
fi
# Strip optional "Bearer " prefix — HTTP client adds Authorization: Bearer automatically
TOKEN="${TOKEN#Bearer }"
TOKEN="${TOKEN#bearer }"

if [[ -z "${TOKEN}" ]]; then
  echo "Token is empty." >&2
  exit 1
fi

CA_FILE="${HUB_LOKI_CA_FILE:-}"
if [[ -z "${CA_FILE}" || ! -f "${CA_FILE}" ]]; then
  echo "Set HUB_LOKI_CA_FILE to a file containing the hub gateway CA PEM (e.g. hub-service-ca.crt)." >&2
  exit 1
fi

oc create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=token="$TOKEN" \
  --from-file=ca-bundle.crt="$CA_FILE" \
  --dry-run=client -o yaml | oc apply -f -
echo "Secret ${SECRET_NAME} updated in ${NAMESPACE}."
