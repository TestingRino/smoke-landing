#!/usr/bin/env bash
# Shared helpers for the gcp/ scripts (run by the operator in Cloud Shell). Source it.

# New service accounts, roles and resources take a while to become visible to IAM policy bindings: retry.
bind() {
  local i
  for i in 1 2 3 4 5 6 7 8; do
    "$@" >/dev/null 2>&1 && return 0
    echo "  waiting for new IAM resources to propagate (attempt $i)..."; sleep $((i * 5))
  done
  "$@" >/dev/null   # final attempt shows the real error
}

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
