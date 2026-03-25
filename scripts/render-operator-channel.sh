#!/usr/bin/env bash
# Substitute __OPERATOR_CHANNEL__ in subscription YAML for oc apply.
# Channel resolution:
#   1. OPERATOR_CHANNEL (or LOGGING_LOKI_CHANNEL) if set
#   2. loki-operator PackageManifest defaultChannel (same cluster/catalog as subscriptions)
#   3. stable-6.4
set -euo pipefail

if [[ $# -ne 1 ]] || [[ ! -f "$1" ]]; then
  echo "usage: OPERATOR_CHANNEL=<ch> $0 <subscription.yaml>" >&2
  exit 1
fi

CH="${OPERATOR_CHANNEL:-${LOGGING_LOKI_CHANNEL:-}}"
if [[ -z "$CH" ]] && command -v oc >/dev/null 2>&1; then
  CH="$(oc get packagemanifest loki-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)"
fi
if [[ -z "$CH" ]]; then
  CH="stable-6.4"
fi

echo "Using operator channel: ${CH}" >&2
sed "s|__OPERATOR_CHANNEL__|${CH}|g" "$1"
