#!/usr/bin/env bash
set -euo pipefail

# Use the flake beside the launcher even if called from a different directory.
cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

case "${1:-start}" in
  update)
    shift
    nix flake update
    exec nix run -L . -- "$@"
    ;;
  *)
    exec nix run -L . -- "$@"
    ;;
esac
