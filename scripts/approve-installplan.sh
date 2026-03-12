#!/usr/bin/env bash
# Approve pending InstallPlans in the given namespace.
# Usage: ./approve-installplan.sh <namespace>
set -euo pipefail
NS="${1:?Usage: $0 <namespace>}"
for ip in $(oc get installplan -o name -n "$NS" 2>/dev/null || true); do
  oc patch "$ip" --namespace "$NS" --type merge --patch '{"spec":{"approved":true}}'
done
