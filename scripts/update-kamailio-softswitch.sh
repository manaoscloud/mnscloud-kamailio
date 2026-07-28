#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REF=""
MANAGED_LIFECYCLE_SCRIPTS=(
  "scripts/update-kamailio-softswitch.sh"
  "scripts/update-latest-kamailio-softswitch.sh"
  "scripts/validate-kamailio-softswitch.sh"
  "scripts/rollback-kamailio-softswitch.sh"
)

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

is_managed_lifecycle_script() {
  local path="$1" managed_path
  for managed_path in "${MANAGED_LIFECYCLE_SCRIPTS[@]}"; do
    [[ "$path" == "$managed_path" ]] && return 0
  done
  return 1
}

restore_managed_lifecycle_scripts() {
  local path backup_dir timestamp
  local -a modified_paths=() unexpected_paths=()

  mapfile -t modified_paths < <(
    { git diff --name-only; git diff --cached --name-only; } | awk 'NF' | sort -u
  )

  ((${#modified_paths[@]} == 0)) && return 0

  for path in "${modified_paths[@]}"; do
    if ! is_managed_lifecycle_script "$path"; then
      unexpected_paths+=("$path")
    fi
  done

  if ((${#unexpected_paths[@]} > 0)); then
    echo "[update-kamailio-softswitch] local repository changes outside managed lifecycle scripts:" >&2
    printf '  - %s\n' "${unexpected_paths[@]}" >&2
    echo "[update-kamailio-softswitch] commit, stash, or restore those files before updating." >&2
    exit 1
  fi

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="/var/backups/mnscloud/kamailio-softswitch/lifecycle-${timestamp}"
  install -d -m 0750 "${backup_dir}/files"

  git diff --binary -- "${modified_paths[@]}" >"${backup_dir}/worktree.patch"
  git diff --cached --binary -- "${modified_paths[@]}" >"${backup_dir}/index.patch"
  printf '%s\n' "${modified_paths[@]}" >"${backup_dir}/changed-paths.txt"

  for path in "${modified_paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a --parents "$path" "${backup_dir}/files"
    fi
  done

  git checkout "$REF" -- "${MANAGED_LIFECYCLE_SCRIPTS[@]}"
  chmod +x "${MANAGED_LIFECYCLE_SCRIPTS[@]}"
  echo "[update-kamailio-softswitch] backed up and restored managed lifecycle scripts from ${REF}: ${backup_dir}"
}

cd "$ROOT_DIR"
git fetch --all --tags --prune
git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null || {
  echo "[update-kamailio-softswitch] ref does not resolve to a commit: ${REF}" >&2
  exit 1
}
restore_managed_lifecycle_scripts
git -c advice.detachedHead=false checkout "$REF"

bash "${SCRIPT_DIR}/install-kamailio-softswitch.sh" "${ARGS[@]}"
bash "${SCRIPT_DIR}/validate-kamailio-softswitch.sh"
