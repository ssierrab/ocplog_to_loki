#!/usr/bin/env bash
# Substitute __OPERATOR_CHANNEL__ in subscription YAML for oc apply.
# If OPERATOR_CHANNEL is set in the environment, it is used (non-interactive / CI).
# Otherwise, prompts on the terminal for the channel (e.g. stable-6.4).
set -euo pipefail

if [[ $# -ne 1 ]] || [[ ! -f "$1" ]]; then
  echo "usage: $0 <subscription.yaml>" >&2
  echo "  Set OPERATOR_CHANNEL to skip the prompt, or run from a terminal to enter it interactively." >&2
  exit 1
fi

if [[ -n "${OPERATOR_CHANNEL:-}" ]]; then
  CH="$OPERATOR_CHANNEL"
elif [[ -t 0 ]]; then
  read -r -p "OLM channel for Loki and cluster-logging (e.g. stable-6.4): " CH
  if [[ -z "${CH// }" ]]; then
    echo "error: channel cannot be empty (set OPERATOR_CHANNEL or type a channel name)" >&2
    exit 1
  fi
else
  echo "error: stdin is not a terminal; set OPERATOR_CHANNEL for non-interactive use." >&2
  exit 1
fi

echo "Using operator channel: ${CH}" >&2
sed "s|__OPERATOR_CHANNEL__|${CH}|g" "$1"
