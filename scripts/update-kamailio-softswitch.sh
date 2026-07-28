#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REF=""

usage() {
  cat <<'USAGE'
Usage: scripts/update-kamailio-softswitch.sh --ref <git-ref> [--dry-run]

Updates this checkout to the requested ref and reruns the installer.
USAGE
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      REF="${2:-}"
      shift 2
      ;;
    --dry-run)
      ARGS+=("--dry-run")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[update-kamailio-softswitch] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$REF" ]] || { echo "[update-kamailio-softswitch] --ref is required" >&2; exit 2; }
[[ "$REF" =~ ^[A-Za-z0-9._/@+-]+$ ]] || { echo "[update-kamailio-softswitch] invalid ref: $REF" >&2; exit 2; }

cd "$ROOT_DIR"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "[update-kamailio-softswitch] local repository changes detected; commit or stash them before updating." >&2
  exit 1
fi
git fetch --all --tags --prune
git -c advice.detachedHead=false checkout "$REF"

bash "${SCRIPT_DIR}/install-kamailio-softswitch.sh" "${ARGS[@]}"
bash "${SCRIPT_DIR}/validate-kamailio-softswitch.sh"
