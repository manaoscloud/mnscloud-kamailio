#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[install-kamailio-softswitch]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE_UUID_FILE="/etc/mnscloud/softswitch/node.uuid"
API_TOKEN_FILE="/etc/mnscloud/softswitch/api.token"
API_BASE_FILE="/etc/mnscloud/softswitch/api.base"
MEDIA_SOCKET_FILE="/etc/mnscloud/softswitch/media.socket"
UAC_DB_TEXT_DIR="/etc/mnscloud/softswitch/kamailio-db"
KAMAILIO_LOG_DIR="/var/log/mnscloud/kamailio"
DEFAULT_API_BASE="${MNSCLOUD_API_BASE:-https://api.example.com}"
SOFTSWITCH_ENGINE="${SOFTSWITCH_ENGINE:-kamailio}"
NODE_UUID="${MNSCLOUD_SOFTSWITCH_NODE_UUID:-}"
API_BASE=""
API_TOKEN="${MNSCLOUD_SOFTSWITCH_API_TOKEN:-}"
MEDIA_SOCKET=""
UAC_CONTACT_ADDR="${MNSCLOUD_KAMAILIO_UAC_CONTACT_ADDR:-}"
UAC_DEFAULT_SOCKET="${MNSCLOUD_KAMAILIO_UAC_DEFAULT_SOCKET:-udp:0.0.0.0:5060}"
KAMAILIO_SIP_LISTEN_IP="${MNSCLOUD_KAMAILIO_SIP_LISTEN_IP:-}"
SBC_INTERNAL_SIP_TARGET="${MNSCLOUD_SBC_INTERNAL_SIP_TARGET:-}"
KAMAILIO_RUNTIME_USER="${MNSCLOUD_KAMAILIO_RUNTIME_USER:-kamailio}"
KAMAILIO_RUNTIME_GROUP="${MNSCLOUD_KAMAILIO_RUNTIME_GROUP:-kamailio}"
KAMAILIO_RUNTIME_KIT_DIR="${KAMAILIO_RUNTIME_KIT_DIR:-/opt/mnscloud/runtime-kit}"
KAMAILIO_RUNTIME_KIT_REPO_URL="${KAMAILIO_RUNTIME_KIT_REPO_URL:-https://github.com/manaoscloud/mnscloud-runtime-kit.git}"
KAMAILIO_RUNTIME_KIT_CHANNEL="${KAMAILIO_RUNTIME_KIT_CHANNEL:-stable}"
KAMAILIO_RUNTIME_KIT_REF="${KAMAILIO_RUNTIME_KIT_REF:-}"
AGENT_VALIDATOR="/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh"
AGENT_REPO_INSTALLER="/opt/mnscloud/mnscloud-agent/scripts/install-agent.sh"
SKIP_AGENT_REFRESH="${MNSCLOUD_SKIP_AGENT_REFRESH:-false}"
KAMAILIO_PIKE_SAMPLING_TIME_UNIT="${MNSCLOUD_KAMAILIO_PIKE_SAMPLING_TIME_UNIT:-2}"
KAMAILIO_PIKE_REQUEST_DENSITY="${MNSCLOUD_KAMAILIO_PIKE_REQUEST_DENSITY:-30}"
KAMAILIO_PIKE_REMOVE_LATENCY="${MNSCLOUD_KAMAILIO_PIKE_REMOVE_LATENCY:-120}"

validate_mnscloud_agent() {
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "bash '${AGENT_VALIDATOR}' --require-active --require-enrolled --require-job voip.softswitch.runtime --require-capability voip.softswitch.manage"
    return 0
  fi
  [[ -x "${AGENT_VALIDATOR}" ]] ||
    { err "mnscloud-agent validator not found at ${AGENT_VALIDATOR}. Update/reinstall the Agent before installing Kamailio Softswitch."; return 1; }
  bash "${AGENT_VALIDATOR}" --require-active --require-enrolled --require-job voip.softswitch.runtime --require-capability voip.softswitch.manage
}

refresh_agent_capabilities() {
  local install_label
  install_label="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'mnscloud-agent')"

  if [[ "$SKIP_AGENT_REFRESH" == true || "$SKIP_AGENT_REFRESH" == "1" ]]; then
    info "Skipping mnscloud-agent capability refresh for this lifecycle run."
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log DRY "refresh mnscloud-agent capabilities so it publishes mnscloud.kamailio-softswitch.update"
    return 0
  fi

  if [[ -x "${AGENT_REPO_INSTALLER}" ]]; then
    info "Refreshing mnscloud-agent capabilities after Kamailio Softswitch runtime install."
    bash "${AGENT_REPO_INSTALLER}" --api-base "${API_BASE}" --install-label "${install_label}"
    return 0
  fi

  warn "mnscloud-agent source repo not found at ${AGENT_REPO_INSTALLER}; restarting service so runtime capability detection can refresh."
  run "systemctl restart mnscloud-agent"
}

normalize_url() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s#/*$##')"
  printf "%s" "$value"
}

validate_api_base() {
  [[ "$1" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/[^[:space:]]*)?$ ]]
}

validate_pike_settings() {
  local name value
  for name in \
    KAMAILIO_PIKE_SAMPLING_TIME_UNIT \
    KAMAILIO_PIKE_REQUEST_DENSITY \
    KAMAILIO_PIKE_REMOVE_LATENCY; do
    value="${!name}"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
      err "${name} must be a positive integer; received: ${value}"
      return 1
    }
  done
}

validate_uac_default_socket() {
  [[ "${UAC_DEFAULT_SOCKET}" =~ ^(udp|tcp):[^[:space:]]+:[0-9]{1,5}$ ]] || {
    err "MNSCLOUD_KAMAILIO_UAC_DEFAULT_SOCKET must be udp|tcp:host:port; received: ${UAC_DEFAULT_SOCKET}"
    return 1
  }
}

normalize_uac_contact_addr() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [[ -n "${value}" ]] || return 1
  [[ "${value}" != *[[:space:]]* ]] || return 1
  if [[ "${value}" == *:* ]]; then
    printf "%s" "${value}"
  else
    printf "%s:5060" "${value}"
  fi
}

resolve_uac_contact_addr() {
  local public_ip="${1:-}" private_ip="${2:-}" hostname_value="${3:-}" candidate=""
  if [[ -n "${MNSCLOUD_KAMAILIO_UAC_CONTACT_ADDR:-}" ]]; then
    candidate="${MNSCLOUD_KAMAILIO_UAC_CONTACT_ADDR}"
  elif [[ -n "${UAC_CONTACT_ADDR}" ]]; then
    candidate="${UAC_CONTACT_ADDR}"
  elif [[ -n "${public_ip}" ]]; then
    candidate="${public_ip}"
  elif [[ -n "${private_ip}" ]]; then
    candidate="${private_ip}"
  else
    candidate="${hostname_value}"
  fi
  normalize_uac_contact_addr "${candidate}"
}

ensure_uac_contact_addr() {
  local hostname_value private_ip public_ip
  if [[ -n "${UAC_CONTACT_ADDR}" ]]; then
    UAC_CONTACT_ADDR="$(normalize_uac_contact_addr "${UAC_CONTACT_ADDR}")" || {
      err "MNSCLOUD_KAMAILIO_UAC_CONTACT_ADDR invalido. Use host[:port] sem espacos."
      return 1
    }
    return 0
  fi
  hostname_value="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  private_ip="$(private_ipv4)"
  public_ip="$(public_ipv4)"
  UAC_CONTACT_ADDR="$(resolve_uac_contact_addr "${public_ip}" "${private_ip}" "${hostname_value}")" || {
    err "Nao foi possivel resolver reg_contact_addr do Kamailio UAC. Defina MNSCLOUD_KAMAILIO_UAC_CONTACT_ADDR=host:port."
    return 1
  }
}

ensure_uac_db_text() {
  local version_file="${UAC_DB_TEXT_DIR}/version"
  local uacreg_file="${UAC_DB_TEXT_DIR}/uacreg"
  local owner="${KAMAILIO_RUNTIME_USER}"
  local group="${KAMAILIO_RUNTIME_GROUP}"
  if ! id -u "${owner}" >/dev/null 2>&1 || ! getent group "${group}" >/dev/null 2>&1; then
    owner="root"
    group="root"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "install -d -m 0750 '${UAC_DB_TEXT_DIR}'"
    log DRY "install UAC db_text schema files in '${UAC_DB_TEXT_DIR}'"
    return 0
  fi

  install -d -m 0750 -o "${owner}" -g "${group}" "${UAC_DB_TEXT_DIR}"
  if [[ ! -f "${uacreg_file}" ]]; then
    cat >"${uacreg_file}" <<'EOF_UACREG'
id(int,auto) l_uuid(str) l_username(str) l_domain(str) r_username(str) r_domain(str) realm(str) auth_username(str) auth_password(str) auth_ha1(str,null) auth_proxy(str) expires(int) flags(int) reg_delay(int) contact_addr(str,null) socket(str,null)
EOF_UACREG
  fi
  if ! grep -Eq '^id\(int,auto\)[[:space:]]+l_uuid\(str\)[[:space:]]+l_username\(str\)' "${uacreg_file}"; then
    cat >"${uacreg_file}" <<'EOF_UACREG'
id(int,auto) l_uuid(str) l_username(str) l_domain(str) r_username(str) r_domain(str) realm(str) auth_username(str) auth_password(str) auth_ha1(str,null) auth_proxy(str) expires(int) flags(int) reg_delay(int) contact_addr(str,null) socket(str,null)
EOF_UACREG
  fi
  if [[ ! -f "${version_file}" ]] || ! grep -Eq '^id\(int,auto\)[[:space:]]+table_name\(str\)[[:space:]]+table_version\(int\)$' "${version_file}" || ! grep -Eq '^1:uacreg:5$' "${version_file}"; then
    cat >"${version_file}" <<'EOF_VERSION'
id(int,auto) table_name(str) table_version(int)
1:uacreg:5
EOF_VERSION
  fi
  chown "${owner}:${group}" "${uacreg_file}" "${version_file}"
  chmod 0640 "${uacreg_file}" "${version_file}"
}

prompt_api_base() {
  local value=""
  if [[ -t 0 ]]; then
    read -r -p "Enter the MNSCloud API base URL [${DEFAULT_API_BASE}]: " value
  fi
  value="${value:-${DEFAULT_API_BASE}}"
  normalize_url "$value"
}

ensure_api_base_file() {
  local dir value
  dir="$(dirname "${API_BASE_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -n "${MNSCLOUD_API_BASE:-}" ]]; then
    API_BASE="$(normalize_url "${MNSCLOUD_API_BASE}")"
    validate_api_base "${API_BASE}" || { err "URL base da API invalida: ${API_BASE}"; return 1; }
    write_file "${API_BASE_FILE}" "${API_BASE}"
    ok "API base saved from environment to ${API_BASE_FILE}: ${API_BASE}"
  elif [[ -f "${API_BASE_FILE}" ]]; then
    value="$(tr -d '[:space:]' < "${API_BASE_FILE}")"
    API_BASE="$(normalize_url "$value")"
    ok "API base carregada de ${API_BASE_FILE}: ${API_BASE}"
  else
    API_BASE="$(prompt_api_base)"
    validate_api_base "${API_BASE}" || { err "URL base da API invalida: ${API_BASE}"; return 1; }
    write_file "${API_BASE_FILE}" "${API_BASE}"
    ok "API base saved to ${API_BASE_FILE}: ${API_BASE}"
  fi

  validate_api_base "${API_BASE}" || { err "URL base da API invalida em ${API_BASE_FILE}: ${API_BASE}"; return 1; }
  run "chown root:root '${API_BASE_FILE}'"
  run "chmod 0640 '${API_BASE_FILE}'"
}

detect_kamailio_os() {
  if [[ ! -r /etc/os-release ]]; then
    err "Could not read /etc/os-release"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12|debian:13) echo "debian"; return 0 ;;
    rocky:8*|rocky:9*) echo "rocky"; return 0 ;;
  esac
  err "Unsupported operating system for Kamailio. Supported: Debian 12/13 and Rocky 8/9."
  exit 2
}

resolve_runtime_kit_ref() {
  local kit_dir="$1" channel="$2" manifest ref
  manifest="$(git -C "$kit_dir" show "origin/main:releases/manifest.json" 2>/dev/null)" ||
    { err "cannot read runtime kit release manifest from origin/main"; return 1; }
  ref="$(printf '%s\n' "$manifest" | awk -v channel="$channel" '
    $0 ~ "\"" channel "\"" { in_channel = 1; next }
    in_channel && /"ref"[[:space:]]*:/ {
      gsub(/.*"ref"[[:space:]]*:[[:space:]]*"/, "")
      gsub(/".*/, "")
      print
      exit
    }
    in_channel && /^[[:space:]]*}/ { in_channel = 0 }
  ')"
  [[ "$ref" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
    { err "invalid runtime kit ref for channel ${channel}: ${ref:-empty}"; return 1; }
  printf '%s\n' "$ref"
}

load_runtime_kit() {
  [[ "${KAMAILIO_RUNTIME_KIT_LOADED:-0}" == "1" ]] && return 0
  command -v git >/dev/null 2>&1 || run "if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y --no-install-recommends ca-certificates git; else dnf install -y ca-certificates git; fi"
  if [[ -d "${KAMAILIO_RUNTIME_KIT_DIR}/.git" ]]; then
    run "git -C '${KAMAILIO_RUNTIME_KIT_DIR}' fetch --all --tags --prune"
  else
    run "install -d -m 0755 '$(dirname "$KAMAILIO_RUNTIME_KIT_DIR")'"
    run "git clone '${KAMAILIO_RUNTIME_KIT_REPO_URL}' '${KAMAILIO_RUNTIME_KIT_DIR}'"
  fi
  if [[ -z "$KAMAILIO_RUNTIME_KIT_REF" ]]; then
    KAMAILIO_RUNTIME_KIT_REF="$(resolve_runtime_kit_ref "$KAMAILIO_RUNTIME_KIT_DIR" "$KAMAILIO_RUNTIME_KIT_CHANNEL")"
    info "Resolved runtime kit ${KAMAILIO_RUNTIME_KIT_CHANNEL} channel to ${KAMAILIO_RUNTIME_KIT_REF}"
  fi
  run "git -C '${KAMAILIO_RUNTIME_KIT_DIR}' -c advice.detachedHead=false checkout '${KAMAILIO_RUNTIME_KIT_REF}'"
  git -C "$KAMAILIO_RUNTIME_KIT_DIR" pull --ff-only origin "$KAMAILIO_RUNTIME_KIT_REF" 2>/dev/null || true
  [[ -r "${KAMAILIO_RUNTIME_KIT_DIR}/lib/packages.sh" ]] || { err "runtime kit packages library not found"; return 1; }
  export MNSCLOUD_RUNTIME_KIT_LOG_PREFIX="mnscloud-kamailio-softswitch/runtime-kit"
  # shellcheck disable=SC1091
  source "${KAMAILIO_RUNTIME_KIT_DIR}/lib/packages.sh"
  KAMAILIO_RUNTIME_KIT_LOADED=1
}

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    err "Could not generate local UUID."
    return 1
  fi
}

generate_secret_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
    return 0
  fi
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

ensure_api_token_file() {
  local dir
  dir="$(dirname "${API_TOKEN_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -n "${API_TOKEN}" ]]; then
    write_file "${API_TOKEN_FILE}" "${API_TOKEN}"
    ok "Softswitch API token saved from environment to ${API_TOKEN_FILE}"
  elif [[ -f "${API_TOKEN_FILE}" ]]; then
    API_TOKEN="$(tr -d '[:space:]' < "${API_TOKEN_FILE}")"
    ok "Softswitch API token loaded from ${API_TOKEN_FILE}"
  else
    API_TOKEN="$(generate_secret_32)"
    write_file "${API_TOKEN_FILE}" "${API_TOKEN}"
    ok "Softswitch API token created at ${API_TOKEN_FILE}"
  fi

  run "chown root:root '${API_TOKEN_FILE}'"
  run "chmod 0640 '${API_TOKEN_FILE}'"
}

ensure_node_uuid_file() {
  local dir compact
  dir="$(dirname "${NODE_UUID_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"
  if [[ -n "${NODE_UUID}" ]]; then
    write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
    ok "Node UUID saved from environment to ${NODE_UUID_FILE}: ${NODE_UUID}"
  elif [[ -f "${NODE_UUID_FILE}" ]]; then
    NODE_UUID="$(tr -d '[:space:]' < "${NODE_UUID_FILE}")"
    ok "Node UUID loaded from ${NODE_UUID_FILE}: ${NODE_UUID}"
  else
    NODE_UUID="$(generate_uuid)"
    write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
    ok "Node UUID created at ${NODE_UUID_FILE}: ${NODE_UUID}"
  fi
  compact="${NODE_UUID//-/}"
  [[ "${compact}" =~ ^[0-9A-Fa-f]{32}$ ]] || { err "Node UUID invalido em ${NODE_UUID_FILE}: ${NODE_UUID}"; return 1; }
  compact="$(echo "${compact}" | tr '[:upper:]' '[:lower:]')"
  NODE_UUID="${compact:0:8}-${compact:8:4}-${compact:12:4}-${compact:16:4}-${compact:20:12}"
  write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
  run "chown root:root '${NODE_UUID_FILE}'"
  run "chmod 0640 '${NODE_UUID_FILE}'"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf "%s" "$value"
}

json_field() {
  local field="$1" file="$2"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n1
}

private_ipv4() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true
}

validate_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || return 1
  awk -F. '{ exit !($1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255) }' <<<"$1"
}

resolve_kamailio_sip_listen_ip() {
  local candidate
  if [[ -n "${KAMAILIO_SIP_LISTEN_IP}" ]]; then
    candidate="${KAMAILIO_SIP_LISTEN_IP}"
  else
    candidate="$(private_ipv4)"
  fi
  validate_ipv4 "${candidate}" || {
    err "Nao foi possivel resolver um IPv4 local valido para Kamailio SIP. Defina MNSCLOUD_KAMAILIO_SIP_LISTEN_IP."
    return 1
  }
  if ! ip -o -4 addr show scope global | awk '{split($4,a,"/"); print a[1]}' | grep -qx "${candidate}"; then
    err "MNSCLOUD_KAMAILIO_SIP_LISTEN_IP=${candidate} nao esta atribuido a este host."
    return 1
  fi
  KAMAILIO_SIP_LISTEN_IP="${candidate}"
  if [[ "${UAC_DEFAULT_SOCKET}" == "udp:0.0.0.0:5060" ]]; then
    UAC_DEFAULT_SOCKET="udp:${KAMAILIO_SIP_LISTEN_IP}:5060"
  elif [[ "${UAC_DEFAULT_SOCKET}" == "tcp:0.0.0.0:5060" ]]; then
    UAC_DEFAULT_SOCKET="tcp:${KAMAILIO_SIP_LISTEN_IP}:5060"
  fi
}

public_ipv4() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null ||
    curl -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null ||
    true
}

bootstrap_node_via_api() {
  local hostname_value private_ip public_ip payload response_file http_code server_uuid media_socket
  hostname_value="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  private_ip="$(private_ipv4)"
  public_ip="$(public_ipv4)"
  UAC_CONTACT_ADDR="$(resolve_uac_contact_addr "${public_ip}" "${private_ip}" "${hostname_value}")" || UAC_CONTACT_ADDR=""
  payload="{\"engine\":\"$(json_escape "${SOFTSWITCH_ENGINE}")\",\"hostname\":\"$(json_escape "${hostname_value}")\""
  [[ -n "${private_ip}" ]] && payload+=",\"privateIP\":\"$(json_escape "${private_ip}")\""
  [[ -n "${public_ip}" ]] && payload+=",\"publicIP\":\"$(json_escape "${public_ip}")\""
  payload+="}"
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "POST ${API_BASE}/api/v1/softswitch/runtime/bootstrap?node_uuid=${NODE_UUID}&engine=${SOFTSWITCH_ENGINE} with local token ${API_TOKEN_FILE}"
    return 0
  fi
  response_file="$(mktemp)"
  http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" -X POST "${API_BASE}/api/v1/softswitch/runtime/bootstrap?node_uuid=${NODE_UUID}&engine=${SOFTSWITCH_ENGINE}" -H "Content-Type: application/json" -H "Authorization: Bearer ${API_TOKEN}" -H "X-Softswitch-Engine: ${SOFTSWITCH_ENGINE}" --data "${payload}" 2>>"${LOG_FILE}")"
  server_uuid="$(json_field "serverUUID" "${response_file}")"
  media_socket="$(json_field "rtpengineSocket" "${response_file}")"
  if [[ -n "${media_socket}" ]]; then
    MEDIA_SOCKET="${media_socket}"
    write_file "${MEDIA_SOCKET_FILE}" "${MEDIA_SOCKET}"
    run "chown root:root '${MEDIA_SOCKET_FILE}'"
    run "chmod 0640 '${MEDIA_SOCKET_FILE}'"
  else
    MEDIA_SOCKET=""
    rm -f "${MEDIA_SOCKET_FILE}"
  fi
  rm -f "${response_file}"
  if [[ "${http_code}" == "200" ]]; then
    ok "Node UUID vinculado via API bootstrap. serverUUID: ${server_uuid:-unknown}"
    if [[ -n "${MEDIA_SOCKET}" ]]; then
      ok "Media relay resolved from API: ${MEDIA_SOCKET}"
    else
      warn "No media relay returned by API. Kamailio will run without RTP anchoring."
    fi
    return 0
  fi
  warn "Softswitch API bootstrap returned HTTP ${http_code}. Register the Node UUID manually if necessary."
  return 1
}

install_packages_debian() {
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "load mnscloud-runtime-kit and run mrtk_ensure_kamailio"
    return 0
  fi
  load_runtime_kit
  MNSCLOUD_KAMAILIO_PACKAGE_PROFILE=core mrtk_ensure_kamailio
}

install_packages_rocky() {
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "load mnscloud-runtime-kit and run mrtk_ensure_kamailio"
    return 0
  fi
  load_runtime_kit
  MNSCLOUD_KAMAILIO_PACKAGE_PROFILE=core mrtk_ensure_kamailio
}

stop_existing_kamailio() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  run "systemctl stop kamailio 2>/dev/null || true"
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  for _ in 1 2 3 4 5; do
    pgrep -x kamailio >/dev/null 2>&1 || break
    sleep 1
  done

  if pgrep -x kamailio >/dev/null 2>&1; then
    warn "Kamailio processes still running after systemctl stop; sending TERM before applying new config."
    run "pkill -TERM -x kamailio || true"
    for _ in 1 2 3 4 5; do
      pgrep -x kamailio >/dev/null 2>&1 || break
      sleep 1
    done
  fi

  if pgrep -x kamailio >/dev/null 2>&1; then
    warn "Kamailio processes still running after TERM; sending KILL to avoid stale PID/socket conflicts."
    run "pkill -KILL -x kamailio || true"
  fi

  if ! pgrep -x kamailio >/dev/null 2>&1; then
    run "rm -f /run/kamailio/kamailio.pid"
  fi
}

backup_once() {
  local file="$1"
  if [[ -f "$file" && ! -f "${file}.bkp" ]]; then
    run "cp -a '${file}' '${file}.bkp'"
  fi
}

write_kamailio_config() {
  local cfg="/etc/kamailio/kamailio.cfg"
  local rtpengine_modules="" rtpengine_params="" rtpengine_offer="" rtpengine_delete=""
  local cfg_group="${KAMAILIO_RUNTIME_GROUP}"
  local private_ip="" public_ip="" listen_block="" alias_block="" record_route_block="" sbc_internal_route_rewrite=""
  resolve_kamailio_sip_listen_ip
  private_ip="${KAMAILIO_SIP_LISTEN_IP}"
  public_ip="$(public_ipv4)"
  if [[ -n "${public_ip}" ]]; then
    listen_block="listen=udp:${KAMAILIO_SIP_LISTEN_IP}:5060 advertise ${public_ip}:5060
listen=tcp:${KAMAILIO_SIP_LISTEN_IP}:5060 advertise ${public_ip}:5060"
    alias_block="alias=\"${KAMAILIO_SIP_LISTEN_IP}:5060\"
alias=\"${public_ip}:5060\""
    record_route_block="$(cat <<EOF
      record_route_preset("${public_ip}:5060");
EOF
)"
  else
    listen_block="listen=udp:${KAMAILIO_SIP_LISTEN_IP}:5060
listen=tcp:${KAMAILIO_SIP_LISTEN_IP}:5060"
    alias_block="alias=\"${KAMAILIO_SIP_LISTEN_IP}:5060\""
    record_route_block="      record_route();"
  fi
  rtpengine_offer='
route[MEDIA_OFFER] {
  return(1);
}
'
  backup_once "$cfg"
  if [[ -z "${MEDIA_SOCKET}" && -f "${MEDIA_SOCKET_FILE}" ]]; then
    MEDIA_SOCKET="$(tr -d '[:space:]' < "${MEDIA_SOCKET_FILE}")"
  fi
  if [[ -n "${MEDIA_SOCKET}" ]]; then
    rtpengine_modules="loadmodule \"rtpengine.so\"
loadmodule \"sdpops.so\""
    rtpengine_params="modparam(\"rtpengine\", \"rtpengine_sock\", \"${MEDIA_SOCKET}\")"
    rtpengine_offer='
route[MEDIA_OFFER] {
  if (has_body("application/sdp")) {
    $var(media_flags) = $avp(codec_flags);
    if ($var(media_flags) == "") {
      $var(media_flags) = "replace-origin replace-session-connection";
    }
    if (!rtpengine_offer("$var(media_flags)")) {
      xlog("L_ERR", "MNSCloud rtpengine_offer failed\n");
      sl_send_reply("503", "Media Relay Unavailable");
      exit;
    }
  }
  t_on_reply("MEDIA_ANSWER");
  return(1);
}

onreply_route[MEDIA_ANSWER] {
  if (status =~ "^(18[0-9]|2[0-9][0-9])" && has_body("application/sdp")) {
    $var(media_flags) = $avp(codec_flags);
    if ($var(media_flags) == "") {
      $var(media_flags) = "replace-origin replace-session-connection";
    }
    if (!rtpengine_answer("$var(media_flags)")) {
      xlog("L_ERR", "MNSCloud rtpengine_answer failed\n");
    }
  }
}
'
    rtpengine_delete='
    if (is_method("BYE|CANCEL")) {
      rtpengine_delete();
    }
'
  fi
  if [[ -n "${SBC_INTERNAL_SIP_TARGET}" && -n "${public_ip}" ]]; then
    sbc_internal_route_rewrite="$(cat <<EOF
      # Keep the public Record-Route identity for external SIP endpoints, but route established
      # dialogs to the SBC through the private/service network when this Softswitch is deployed
      # beside an MNSCloud SBC. This avoids public hairpin/NAT on endpoint-originated BYE and lets
      # the BYE 200 OK return to the Kamailio transaction socket.
      if (\$du =~ "sip:${public_ip}:5060" || \$rd == "${public_ip}") {
        \$du = "${SBC_INTERNAL_SIP_TARGET}";
      }
EOF
)"
  elif [[ -n "${SBC_INTERNAL_SIP_TARGET}" ]]; then
    warn "MNSCLOUD_SBC_INTERNAL_SIP_TARGET was provided, but no public SIP IP was detected; skipping SBC internal route rewrite"
  fi
  write_file "$cfg" "#!KAMAILIO
# MNSCloud managed Kamailio Softswitch runtime

${listen_block}
auto_aliases=no
${alias_block}
children=4
log_stderror=no
user_agent_header=\"User-Agent: MNSCloud Kamailio Softswitch\"
server_header=\"Server: MNSCloud Kamailio Softswitch\"

loadmodule \"tm.so\"
loadmodule \"sl.so\"
loadmodule \"rr.so\"
loadmodule \"path.so\"
loadmodule \"maxfwd.so\"
loadmodule \"textops.so\"
loadmodule \"siputils.so\"
loadmodule \"xlog.so\"
loadmodule \"pv.so\"
loadmodule \"pike.so\"
loadmodule \"auth.so\"
loadmodule \"usrloc.so\"
loadmodule \"registrar.so\"
loadmodule \"jsonrpcs.so\"
loadmodule \"kex.so\"
loadmodule \"corex.so\"
loadmodule \"ctl.so\"
loadmodule \"db_text.so\"
loadmodule \"http_client.so\"
loadmodule \"jansson.so\"
loadmodule \"uac.so\"
loadmodule \"exec.so\"
${rtpengine_modules}

modparam(\"usrloc\", \"db_mode\", 0)
modparam(\"usrloc\", \"use_domain\", 1)
modparam(\"registrar\", \"max_contacts\", 1)
modparam(\"registrar\", \"use_path\", 1)
modparam(\"registrar\", \"path_mode\", 0)
modparam(\"auth\", \"nonce_expire\", 300)
modparam(\"auth\", \"qop\", \"auth\")
modparam(\"http_client\", \"query_result\", 0)
modparam(\"pike\", \"sampling_time_unit\", ${KAMAILIO_PIKE_SAMPLING_TIME_UNIT})
modparam(\"pike\", \"reqs_density_per_unit\", ${KAMAILIO_PIKE_REQUEST_DENSITY})
modparam(\"pike\", \"remove_latency\", ${KAMAILIO_PIKE_REMOVE_LATENCY})
modparam(\"uac\", \"reg_db_url\", \"text://${UAC_DB_TEXT_DIR}\")
modparam(\"uac\", \"reg_contact_addr\", \"${UAC_CONTACT_ADDR}\")
modparam(\"uac\", \"default_socket\", \"${UAC_DEFAULT_SOCKET}\")
modparam(\"uac\", \"reg_active\", 1)
modparam(\"uac\", \"reg_timer_interval\", 60)
modparam(\"uac\", \"reg_retry_interval\", 300)
${rtpengine_params}

route[AUTH_LOOKUP] {
  \$var(from_user) = \$fU;
  # REGISTER authenticates in the domain addressed by the client. The From
  # domain frequently contains a device IP and is not the subscriber domain.
  \$var(auth_domain) = \$fd;
  if (is_method(\"REGISTER\")) {
    \$var(auth_domain) = \$td;
  }
  \$var(auth_url) = \"${API_BASE}/api/v1/softswitch/runtime/auth?node_uuid=${NODE_UUID}&engine=${SOFTSWITCH_ENGINE}\";
  \$var(auth_headers) = \"Content-Type: application/json\\r\\nAuthorization: Bearer ${API_TOKEN}\\r\\nX-Softswitch-Engine: ${SOFTSWITCH_ENGINE}\";
  \$var(auth_body) = '{}';
  jansson_set(\"string\", \"engine\", \"${SOFTSWITCH_ENGINE}\", \"\$var(auth_body)\");
  jansson_set(\"string\", \"username\", \"\$var(from_user)\", \"\$var(auth_body)\");
  jansson_set(\"string\", \"domain\", \"\$var(auth_domain)\", \"\$var(auth_body)\");
  \$var(auth_reply) = \"\";

  # http_client_query supports POST bodies and returns the HTTP response code in
  # \$rc. Keep this contract because authorization must distinguish a transport
  # failure from an API denial before challenging the SIP client.
  http_client_query(\$var(auth_url), \$var(auth_body), \$var(auth_headers), \"\$var(auth_reply)\");
  \$var(auth_http_code) = \$rc;
  if (\$var(auth_http_code) == 429) {
    xlog(\"L_WARN\", \"MNSCloud auth API rate limited engine=${SOFTSWITCH_ENGINE} source=\$si username=\$var(from_user) domain=\$var(auth_domain) http=\$var(auth_http_code)\\n\");
    return(-20);
  }
  if (\$var(auth_http_code) < 200 || \$var(auth_http_code) >= 300) {
    xlog(\"L_ERR\", \"MNSCloud auth API request failed engine=${SOFTSWITCH_ENGINE} source=\$si username=\$var(from_user) domain=\$var(auth_domain) http=\$var(auth_http_code) curl=\$curlerror(error)\\n\");
    return(-1);
  }

  if (!jansson_get(\"authorized\", \"\$var(auth_reply)\", \"\$var(auth_authorized)\")) {
    xlog(\"L_ERR\", \"MNSCloud auth API returned invalid JSON for \$fU@\$fd\\n\");
    return(-2);
  }

  if (!(\$var(auth_authorized) =~ \"^(true|1)$\")) {
    xlog(\"L_WARN\", \"MNSCloud SIP edge denied engine=${SOFTSWITCH_ENGINE} source=\$si username=\$var(from_user) domain=\$var(auth_domain) reason=authorization\\n\");
    return(-2);
  }

  if (!jansson_get(\"data.password\", \"\$var(auth_reply)\", \"\$var(auth_password)\")) {
    xlog(\"L_ERR\", \"MNSCloud auth response missing password for \$fU@\$fd\\n\");
    return(-3);
  }

  jansson_get(\"data.accountUUID\", \"\$var(auth_reply)\", \"\$avp(account_uuid)\");
  jansson_get(\"data.subscriberUUID\", \"\$var(auth_reply)\", \"\$avp(subscriber_uuid)\");
  if (!jansson_get(\"data.codecPolicy.rtpengineFlags\", \"\$var(auth_reply)\", \"\$avp(codec_flags)\")) {
    \$avp(codec_flags) = \"\";
  }
  return(1);
}

route[REGISTER_AUTH] {
  route(AUTH_LOOKUP);
  if (\$rc == -20) {
    append_to_reply(\"Retry-After: 60\\r\\n\");
    sl_send_reply(\"503\", \"Authentication Temporarily Unavailable\");
    exit;
  }
  if (\$rc < 0) {
    sl_send_reply(\"403\", \"Forbidden\");
    exit;
  }

  if (!pv_www_authenticate(\"\$fd\", \"\$var(auth_password)\", \"0\")) {
    www_challenge(\"\$fd\", \"1\");
    exit;
  }

  consume_credentials();
  return(1);
}

route[PROXY_AUTH] {
  route(AUTH_LOOKUP);
  if (\$rc == -20) {
    append_to_reply(\"Retry-After: 60\\r\\n\");
    sl_send_reply(\"503\", \"Authentication Temporarily Unavailable\");
    exit;
  }
  if (\$rc < 0) {
    sl_send_reply(\"403\", \"Forbidden\");
    exit;
  }

  if (!pv_proxy_authenticate(\"\$fd\", \"\$var(auth_password)\", \"0\")) {
    proxy_challenge(\"\$fd\", \"1\");
    exit;
  }

  consume_credentials();
  return(1);
}

route[API_ROUTE] {
  \$var(from_user) = \$fU;
  \$var(from_domain) = \$fd;
  \$var(request_user) = \$rU;
  \$var(route_url) = \"${API_BASE}/api/v1/softswitch/runtime/route?node_uuid=${NODE_UUID}&engine=${SOFTSWITCH_ENGINE}\";
  \$var(route_headers) = \"Content-Type: application/json\\r\\nAuthorization: Bearer ${API_TOKEN}\\r\\nX-Softswitch-Engine: ${SOFTSWITCH_ENGINE}\";
  \$var(route_body) = '{}';
  jansson_set(\"string\", \"engine\", \"${SOFTSWITCH_ENGINE}\", \"\$var(route_body)\");
  jansson_set(\"string\", \"direction\", \"outbound\", \"\$var(route_body)\");
  jansson_set(\"string\", \"domain\", \"\$var(from_domain)\", \"\$var(route_body)\");
  jansson_set(\"string\", \"sourceUsername\", \"\$var(from_user)\", \"\$var(route_body)\");
  jansson_set(\"string\", \"destination\", \"\$var(request_user)\", \"\$var(route_body)\");
  \$var(route_reply) = \"\";

  http_client_query(\$var(route_url), \$var(route_body), \$var(route_headers), \"\$var(route_reply)\");
  \$var(route_http_code) = \$rc;
  if (\$var(route_http_code) < 200 || \$var(route_http_code) >= 300) {
    xlog(\"L_ERR\", \"MNSCloud route API request failed for \$fU -> \$rU: http=\$var(route_http_code) curl=\$curlerror(error)\\n\");
    sl_send_reply(\"503\", \"Routing Unavailable\");
    exit;
  }

  if (!(\$var(route_reply) =~ \"\\\"routed\\\"[[:space:]]*:[[:space:]]*true\")) {
    sl_send_reply(\"404\", \"No Route\");
    exit;
  }

  if (!jansson_get(\"data.host\", \"\$var(route_reply)\", \"\$var(route_host)\")) {
    sl_send_reply(\"503\", \"Invalid Route\");
    exit;
  }
  if (!jansson_get(\"data.port\", \"\$var(route_reply)\", \"\$var(route_port)\")) {
    \$var(route_port) = \"5060\";
  }
  if (!jansson_get(\"data.transport\", \"\$var(route_reply)\", \"\$var(route_transport)\")) {
    \$var(route_transport) = \"udp\";
  }
  if (!jansson_get(\"data.destination\", \"\$var(route_reply)\", \"\$var(route_destination)\")) {
    \$var(route_destination) = \$rU;
  }
  jansson_get(\"data.accountUUID\", \"\$var(route_reply)\", \"\$avp(account_uuid)\");
  jansson_get(\"data.subscriberUUID\", \"\$var(route_reply)\", \"\$avp(subscriber_uuid)\");
  jansson_get(\"data.trunkUUID\", \"\$var(route_reply)\", \"\$avp(trunk_uuid)\");
  jansson_get(\"data.routeUUID\", \"\$var(route_reply)\", \"\$avp(route_uuid)\");
  jansson_get(\"data.rateUUID\", \"\$var(route_reply)\", \"\$avp(rate_uuid)\");
  if (!jansson_get(\"data.codecPolicy.rtpengineFlags\", \"\$var(route_reply)\", \"\$avp(codec_flags)\")) {
    \$avp(codec_flags) = \"\";
  }
  if (!jansson_get(\"data.codecPolicy.diagnosticCaptureEnabled\", \"\$var(route_reply)\", \"\$avp(diag_enabled)\")) {
    \$avp(diag_enabled) = \"0\";
  }
  if (!jansson_get(\"data.codecPolicy.diagnosticCaptureMode\", \"\$var(route_reply)\", \"\$avp(diag_mode)\")) {
    \$avp(diag_mode) = \"sip_capture\";
  }
  if (!jansson_get(\"data.codecPolicy.diagnosticCaptureSeconds\", \"\$var(route_reply)\", \"\$avp(diag_seconds)\")) {
    \$avp(diag_seconds) = \"60\";
  }

  \$ru = \"sip:\" + \$var(route_destination) + \"@\" + \$var(route_host) + \":\" + \$var(route_port);
  \$du = \"sip:\" + \$var(route_host) + \":\" + \$var(route_port) + \";transport=\" + \$var(route_transport);
  return(1);
}

route[INBOUND_ROUTE] {
  \$var(source_ip) = \$si;
  \$var(request_user) = \$rU;
  if (\$tU != \"\") {
    \$var(request_user) = \$tU;
  }
  \$var(request_domain) = \$rd;
  xlog(\"L_INFO\", \"MNSCloud inbound route lookup source=\$si request_user=\$rU to_user=\$tU destination=\$var(request_user) domain=\$var(request_domain)\\n\");
  \$var(inbound_url) = \"${API_BASE}/api/v1/softswitch/runtime/route?node_uuid=${NODE_UUID}&engine=${SOFTSWITCH_ENGINE}\";
  \$var(inbound_headers) = \"Content-Type: application/json\\r\\nAuthorization: Bearer ${API_TOKEN}\\r\\nX-Softswitch-Engine: ${SOFTSWITCH_ENGINE}\";
  \$var(inbound_body) = '{}';
  jansson_set(\"string\", \"engine\", \"${SOFTSWITCH_ENGINE}\", \"\$var(inbound_body)\");
  jansson_set(\"string\", \"direction\", \"inbound\", \"\$var(inbound_body)\");
  jansson_set(\"string\", \"sourceIP\", \"\$var(source_ip)\", \"\$var(inbound_body)\");
  jansson_set(\"string\", \"destination\", \"\$var(request_user)\", \"\$var(inbound_body)\");
  jansson_set(\"string\", \"domain\", \"\$var(request_domain)\", \"\$var(inbound_body)\");
  \$var(inbound_reply) = \"\";

  http_client_query(\$var(inbound_url), \$var(inbound_body), \$var(inbound_headers), \"\$var(inbound_reply)\");
  \$var(inbound_http_code) = \$rc;
  if (\$var(inbound_http_code) < 200 || \$var(inbound_http_code) >= 300) {
    xlog(\"L_ERR\", \"MNSCloud inbound route API request failed for \$si -> \$rU: http=\$var(inbound_http_code) curl=\$curlerror(error)\\n\");
    return(-1);
  }

  if (!(\$var(inbound_reply) =~ \"\\\"routed\\\"[[:space:]]*:[[:space:]]*true\")) {
    return(-1);
  }

  if (!jansson_get(\"data.targetType\", \"\$var(inbound_reply)\", \"\$var(inbound_target_type)\")) {
    return(-1);
  }
  if (!jansson_get(\"data.destination\", \"\$var(inbound_reply)\", \"\$var(inbound_destination)\")) {
    return(-1);
  }
  \$avp(callee_number) = \$var(inbound_destination);
  if (!jansson_get(\"data.codecPolicy.rtpengineFlags\", \"\$var(inbound_reply)\", \"\$avp(codec_flags)\")) {
    \$avp(codec_flags) = \"\";
  }
  if (!jansson_get(\"data.codecPolicy.diagnosticCaptureEnabled\", \"\$var(inbound_reply)\", \"\$avp(diag_enabled)\")) {
    \$avp(diag_enabled) = \"0\";
  }
  if (!jansson_get(\"data.codecPolicy.diagnosticCaptureMode\", \"\$var(inbound_reply)\", \"\$avp(diag_mode)\")) {
    \$avp(diag_mode) = \"sip_capture\";
  }
  if (!jansson_get(\"data.codecPolicy.diagnosticCaptureSeconds\", \"\$var(inbound_reply)\", \"\$avp(diag_seconds)\")) {
    \$avp(diag_seconds) = \"60\";
  }
  jansson_get(\"data.accountUUID\", \"\$var(inbound_reply)\", \"\$avp(account_uuid)\");
  jansson_get(\"data.subscriberUUID\", \"\$var(inbound_reply)\", \"\$avp(subscriber_uuid)\");
  jansson_get(\"data.trunkUUID\", \"\$var(inbound_reply)\", \"\$avp(trunk_uuid)\");
  jansson_get(\"data.routeUUID\", \"\$var(inbound_reply)\", \"\$avp(route_uuid)\");
  jansson_get(\"data.rateUUID\", \"\$var(inbound_reply)\", \"\$avp(rate_uuid)\");
  \$avp(direction) = \"inbound\";

  if (\$var(inbound_target_type) == \"subscriber\") {
    if (!jansson_get(\"data.domain\", \"\$var(inbound_reply)\", \"\$var(inbound_domain)\")) {
      return(-1);
    }
    \$ru = \"sip:\" + \$var(inbound_destination) + \"@\" + \$var(inbound_domain);
    if (!lookup(\"location\")) {
      sl_send_reply(\"480\", \"Temporarily Unavailable\");
      exit;
    }
    return(1);
  }

  if (\$var(inbound_target_type) == \"external\") {
    if (\$var(inbound_destination) =~ \"^sip:\") {
      \$ru = \$var(inbound_destination);
    } else {
      \$ru = \"sip:\" + \$var(inbound_destination);
    }
    return(1);
  }

  if (\$var(inbound_target_type) == \"trunk\") {
    if (!jansson_get(\"data.host\", \"\$var(inbound_reply)\", \"\$var(inbound_host)\")) {
      return(-1);
    }
    if (!jansson_get(\"data.port\", \"\$var(inbound_reply)\", \"\$var(inbound_port)\")) {
      \$var(inbound_port) = \"5060\";
    }
    if (!jansson_get(\"data.transport\", \"\$var(inbound_reply)\", \"\$var(inbound_transport)\")) {
      \$var(inbound_transport) = \"udp\";
    }
    \$ru = \"sip:\" + \$var(inbound_destination) + \"@\" + \$var(inbound_host) + \":\" + \$var(inbound_port);
    if (\$var(inbound_transport) == \"tcp\" || \$var(inbound_transport) == \"tls\") {
      \$ru = \$ru + \";transport=\" + \$var(inbound_transport);
    }
    return(1);
  }

  return(-1);
}

route[DIALOG_ROUTE] {
  \$var(dialog_routed) = \"0\";
  \$var(dialog_url) = \"${API_BASE}/api/v1/softswitch/runtime/dialog?node_uuid=${NODE_UUID}&engine=${SOFTSWITCH_ENGINE}\";
  \$var(dialog_headers) = \"Content-Type: application/json\\r\\nAuthorization: Bearer ${API_TOKEN}\\r\\nX-Softswitch-Engine: ${SOFTSWITCH_ENGINE}\";
  \$var(dialog_body) = '{}';
  jansson_set(\"string\", \"engine\", \"${SOFTSWITCH_ENGINE}\", \"\$var(dialog_body)\");
  jansson_set(\"string\", \"call_id\", \"\$ci\", \"\$var(dialog_body)\");
  jansson_set(\"string\", \"sourceIP\", \"\$si\", \"\$var(dialog_body)\");
  jansson_set(\"integer\", \"sourcePort\", \"\$sp\", \"\$var(dialog_body)\");
  jansson_set(\"string\", \"sourceTransport\", \"\$proto\", \"\$var(dialog_body)\");
  jansson_set(\"string\", \"ruriUser\", \"\$rU\", \"\$var(dialog_body)\");
  jansson_set(\"string\", \"ruriDomain\", \"\$rd\", \"\$var(dialog_body)\");
  \$var(dialog_reply) = \"\";

  http_client_query(\$var(dialog_url), \$var(dialog_body), \$var(dialog_headers), \"\$var(dialog_reply)\");
  \$var(dialog_http_code) = \$rc;
  if (\$var(dialog_http_code) < 200 || \$var(dialog_http_code) >= 300) {
    xlog(\"L_ERR\", \"MNSCloud dialog route API request failed call=\$ci source=\$si http=\$var(dialog_http_code) curl=\$curlerror(error)\\n\");
    return(-1);
  }
  if (!(\$var(dialog_reply) =~ \"\\\"allowed\\\"[[:space:]]*:[[:space:]]*true\")) {
    return(-1);
  }
  if (jansson_get(\"data.requestURI\", \"\$var(dialog_reply)\", \"\$var(dialog_request_uri)\")) {
    \$ru = \$var(dialog_request_uri);
    \$var(dialog_host) = \$(var(dialog_request_uri){uri.host});
    \$var(dialog_port) = \$(var(dialog_request_uri){uri.port});
    \$var(dialog_transport) = \$(var(dialog_request_uri){uri.transport});
    if (\$var(dialog_host) != \"\") {
      if (\$var(dialog_port) == \"\") {
        \$var(dialog_port) = \"5060\";
      }
      if (\$var(dialog_transport) == \"\") {
        \$var(dialog_transport) = \"udp\";
      }
      \$du = \"sip:\" + \$var(dialog_host) + \":\" + \$var(dialog_port) + \";transport=\" + \$var(dialog_transport);
    } else {
      \$du = \$var(dialog_request_uri);
    }
  }
  if (jansson_get(\"data.host\", \"\$var(dialog_reply)\", \"\$var(dialog_host)\")) {
    if (!jansson_get(\"data.port\", \"\$var(dialog_reply)\", \"\$var(dialog_port)\")) {
      \$var(dialog_port) = \"5060\";
    }
    if (!jansson_get(\"data.transport\", \"\$var(dialog_reply)\", \"\$var(dialog_transport)\")) {
      \$var(dialog_transport) = \"udp\";
    }
    \$du = \"sip:\" + \$var(dialog_host) + \":\" + \$var(dialog_port) + \";transport=\" + \$var(dialog_transport);
  }
  if (\$ru == \"\" && \$du == \"\") {
    return(-1);
  }
  remove_hf(\"Route\");
  \$var(dialog_routed) = \"1\";
  return(1);
}

route[ACCOUNTING_EVENT] {
  if (\$var(accounting_event) == \"\") {
    \$var(accounting_event) = \"unknown\";
  }
  if (\$avp(direction) == \"\") {
    \$avp(direction) = \"outbound\";
  }
  \$var(accounting_url) = \"${API_BASE}/api/v1/softswitch/runtime/accounting?node_uuid=${NODE_UUID}&engine=${SOFTSWITCH_ENGINE}\";
  \$var(accounting_headers) = \"Content-Type: application/json\\r\\nAuthorization: Bearer ${API_TOKEN}\\r\\nX-Softswitch-Engine: ${SOFTSWITCH_ENGINE}\";
  \$var(accounting_body) = '{}';
  jansson_set(\"string\", \"engine\", \"${SOFTSWITCH_ENGINE}\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"event\", \"\$var(accounting_event)\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"call_id\", \"\$ci\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"direction\", \"\$avp(direction)\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"caller\", \"\$fU\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"sourceIP\", \"\$si\", \"\$var(accounting_body)\");
  jansson_set(\"integer\", \"sourcePort\", \"\$sp\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"sourceTransport\", \"\$proto\", \"\$var(accounting_body)\");
  if (\$ct != \"\") {
    \$var(accounting_source_contact_uri) = \$(ct{nameaddr.uri});
    if (\$var(accounting_source_contact_uri) != \"\") {
      jansson_set(\"string\", \"sourceContactUri\", \"\$var(accounting_source_contact_uri)\", \"\$var(accounting_body)\");
    }
  }
  if (\$var(accounting_output_contact_uri) != \"\") {
    jansson_set(\"string\", \"outputContactUri\", \"\$var(accounting_output_contact_uri)\", \"\$var(accounting_body)\");
  }
  if (\$avp(callee_number) != \"\") {
    jansson_set(\"string\", \"callee\", \"\$avp(callee_number)\", \"\$var(accounting_body)\");
  } else {
    jansson_set(\"string\", \"callee\", \"\$rU\", \"\$var(accounting_body)\");
  }
  jansson_set(\"string\", \"accountUUID\", \"\$avp(account_uuid)\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"subscriberUUID\", \"\$avp(subscriber_uuid)\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"trunkUUID\", \"\$avp(trunk_uuid)\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"routeUUID\", \"\$avp(route_uuid)\", \"\$var(accounting_body)\");
  jansson_set(\"string\", \"rateUUID\", \"\$avp(rate_uuid)\", \"\$var(accounting_body)\");
  if (\$var(accounting_sip_code) != \"\") {
    jansson_set(\"integer\", \"sipCode\", \"\$var(accounting_sip_code)\", \"\$var(accounting_body)\");
  }
  if (\$var(accounting_sip_reason) != \"\") {
    jansson_set(\"string\", \"sipReason\", \"\$var(accounting_sip_reason)\", \"\$var(accounting_body)\");
  }
  \$var(accounting_reply) = \"\";
  http_client_query(\$var(accounting_url), \$var(accounting_body), \$var(accounting_headers), \"\$var(accounting_reply)\");
  \$var(accounting_http_code) = \$rc;
  if (\$var(accounting_http_code) < 200 || \$var(accounting_http_code) >= 300) {
    xlog(\"L_WARN\", \"MNSCloud accounting API request failed for call=\$ci event=\$var(accounting_event) http=\$var(accounting_http_code) curl=\$curlerror(error)\\n\");
  } else if (\$var(accounting_event) == \"invite\" &&
             (\$avp(diag_enabled) == 1 || \$avp(diag_enabled) == \"1\" || \$avp(diag_enabled) == \"true\")) {
    \$var(cdr_uuid) = \"\";
    if (!jansson_get(\"data.cdrUUID\", \"\$var(accounting_reply)\", \"\$var(cdr_uuid)\")) {
      jansson_get(\"data.callUUID\", \"\$var(accounting_reply)\", \"\$var(cdr_uuid)\");
    }
    if (\$var(cdr_uuid) =~ \"^[0-9A-Fa-f-]{36}$\") {
      if (!(\$avp(diag_mode) =~ \"^(sip_capture|pcapng)$\")) { \$avp(diag_mode) = \"sip_capture\"; }
      if (!(\$avp(diag_seconds) =~ \"^[0-9]+$\")) { \$avp(diag_seconds) = \"60\"; }
      exec_msg(\"/bin/sh -c 'MNSCLOUD_API_BASE=\\\"${API_BASE}\\\" MNSCLOUD_API_TOKEN=\\\"${API_TOKEN}\\\" MNSCLOUD_NODE_UUID=\\\"${NODE_UUID}\\\" /opt/mnscloud/mnscloud-kamailio-softswitch/scripts/mnscloud-cdr-diagnostic-capture.sh --enabled yes --module softswitch --engine ${SOFTSWITCH_ENGINE} --resource-type softswitch_cdr --resource-uuid \\\"\$var(cdr_uuid)\\\" --call-id \\\"\$ci\\\" --mode \\\"\$avp(diag_mode)\\\" --duration \\\"\$avp(diag_seconds)\\\" --filter \\\"port 5060\\\" >>${KAMAILIO_LOG_DIR}/cdr-diagnostic-capture.log 2>&1 &' \");
    }
  }
}

${rtpengine_offer}

request_route {
  if (!mf_process_maxfwd_header(\"10\")) { sl_send_reply(\"483\", \"Too Many Hops\"); exit; }
  if (is_method(\"OPTIONS\")) { sl_send_reply(\"200\", \"OK\"); exit; }

  # Keep unauthenticated SIP floods from exhausting the authenticated runtime API.
  if (is_method(\"REGISTER|INVITE|CANCEL\") && !pike_check_req()) {
    xlog(\"L_WARN\", \"MNSCloud dropped SIP flood: method=\$rm source=\$si\\n\");
    exit;
  }

  if (is_method(\"CANCEL\")) {
    if (t_check_trans()) {
${rtpengine_delete}
      if (!t_relay()) { sl_reply_error(); }
    }
    exit;
  }

  if (has_totag()) {
    if (is_method(\"ACK\")) {
      route(DIALOG_ROUTE);
    }
    if (is_method(\"ACK\") && \$var(dialog_routed) == \"1\") {
      xlog(\"L_WARN\", \"MNSCloud in-dialog ACK dialog-routed before loose_route engine=kamailio call=\$ci ruri=\$ru dst=\$du route=\$hdr(Route) source=\$si\\n\");
      if (!forward()) {
        xlog(\"L_ERR\", \"MNSCloud in-dialog ACK forward failed engine=kamailio call=\$ci ruri=\$ru dst=\$du source=\$si\\n\");
      }
      exit;
    }

    if (!loose_route()) {
      xlog(\"L_WARN\", \"MNSCloud in-dialog without Route engine=kamailio method=\$rm call=\$ci ruri=\$ru from=\$fu to=\$tu source=\$si\\n\");
      if (is_method(\"ACK|BYE\")) {
        route(DIALOG_ROUTE);
      }
      if (is_method(\"ACK|BYE\") && \$var(dialog_routed) == \"1\") {
        xlog(\"L_WARN\", \"MNSCloud in-dialog dialog-routed engine=kamailio method=\$rm call=\$ci ruri=\$ru dst=\$du source=\$si\\n\");
        if (is_method(\"BYE\")) {
          \$var(accounting_event) = \"bye\";
          \$var(accounting_sip_code) = \"\";
          \$var(accounting_sip_reason) = \"\";
          route(ACCOUNTING_EVENT);
${rtpengine_delete}
        }
        if (!t_relay()) {
          if (!is_method(\"ACK\")) { sl_reply_error(); }
        }
        exit;
      }
      if (is_method(\"ACK\") && t_check_trans()) {
        t_relay();
        exit;
      }
      sl_send_reply(\"404\", \"Not Here\");
      exit;
    }
${rtpengine_delete}
    if (is_method(\"BYE\")) {
      \$var(accounting_event) = \"bye\";
      \$var(accounting_sip_code) = \"\";
      \$var(accounting_sip_reason) = \"\";
      route(ACCOUNTING_EVENT);
    }
    if (is_method(\"BYE\")) {
${sbc_internal_route_rewrite}
      xlog(\"L_INFO\", \"MNSCloud in-dialog BYE loose_route engine=${SOFTSWITCH_ENGINE} call=\$ci ruri=\$ru dst=\$du route=\$hdr(Route) source=\$si\\n\");
    }
    if (!t_relay()) { sl_reply_error(); }
    exit;
  }

  if (is_method(\"REGISTER\")) {
    route(REGISTER_AUTH);
    if (!save(\"location\", \"0x04\")) {
      xlog(\"L_ERR\", \"MNSCloud REGISTER location save failed engine=${SOFTSWITCH_ENGINE} source=\$si username=\$fU domain=\$td contact=\$ct callid=\$ci cseq=\$cs\\n\");
      sl_send_reply(\"503\", \"Registration Storage Unavailable\");
      exit;
    }
    xlog(\"L_INFO\", \"MNSCloud REGISTER saved engine=${SOFTSWITCH_ENGINE} source=\$si username=\$fU domain=\$td contact=\$ct callid=\$ci cseq=\$cs\\n\");
    exit;
  }

  if (is_method(\"INVITE\")) {
    route(INBOUND_ROUTE);
    if (\$rc > 0) {
${record_route_block}
      route(MEDIA_OFFER);
      \$var(accounting_event) = \"invite\";
      \$var(accounting_sip_code) = \"\";
      \$var(accounting_sip_reason) = \"\";
      route(ACCOUNTING_EVENT);
      t_on_reply(\"MNSCLOUD_ACCOUNTING_REPLY\");
      if (!t_relay()) {
        \$var(accounting_event) = \"failed\";
        \$var(accounting_sip_code) = \"500\";
        \$var(accounting_sip_reason) = \"Relay failed\";
        route(ACCOUNTING_EVENT);
        sl_reply_error();
      }
      exit;
    }

    route(PROXY_AUTH);
${record_route_block}

    if (lookup(\"location\")) {
      \$avp(direction) = \"inbound\";
      route(MEDIA_OFFER);
      \$var(accounting_event) = \"invite\";
      \$var(accounting_sip_code) = \"\";
      \$var(accounting_sip_reason) = \"\";
      route(ACCOUNTING_EVENT);
      t_on_reply(\"MNSCLOUD_ACCOUNTING_REPLY\");
      if (!t_relay()) {
        \$var(accounting_event) = \"failed\";
        \$var(accounting_sip_code) = \"500\";
        \$var(accounting_sip_reason) = \"Relay failed\";
        route(ACCOUNTING_EVENT);
        sl_reply_error();
      }
      exit;
    }

    route(API_ROUTE);
    \$avp(direction) = \"outbound\";
    route(MEDIA_OFFER);
    \$var(accounting_event) = \"invite\";
    \$var(accounting_sip_code) = \"\";
    \$var(accounting_sip_reason) = \"\";
    route(ACCOUNTING_EVENT);
    t_on_reply(\"MNSCLOUD_ACCOUNTING_REPLY\");
    if (!t_relay()) {
      \$var(accounting_event) = \"failed\";
      \$var(accounting_sip_code) = \"500\";
      \$var(accounting_sip_reason) = \"Relay failed\";
      route(ACCOUNTING_EVENT);
      sl_reply_error();
    }
    exit;
  }

  sl_send_reply(\"405\", \"Method Not Allowed\");
  exit;
}

onreply_route[MNSCLOUD_ACCOUNTING_REPLY] {
  if (\$rs >= 200) {
    if (\$rs >= 200 && \$rs < 300) {
      \$var(accounting_event) = \"answered\";
      if (\$ct != \"\") {
        \$var(accounting_output_contact_uri) = \$(ct{nameaddr.uri});
      }
    } else {
      \$var(accounting_event) = \"failed\";
    }
    \$var(accounting_sip_code) = \$rs;
    \$var(accounting_sip_reason) = \$rr;
    route(ACCOUNTING_EVENT);
  }
}
"
  if ! getent group "${cfg_group}" >/dev/null 2>&1; then
    cfg_group="root"
  fi
  run "chown root:'${cfg_group}' '${cfg}'"
  run "chmod 0640 '${cfg}'"
  run "kamailio -c -f '${cfg}'"
}

install_systemd_override() {
  local override_dir="/etc/systemd/system/kamailio.service.d"
  local override_file="${override_dir}/mnscloud-softswitch.conf"
  if [[ "$DRY_RUN" == true ]]; then
    log DRY "install Kamailio systemd override at ${override_file}"
    return 0
  fi
  install -d -m 0755 "${override_dir}"
  install -d -m 0750 -o root -g "${KAMAILIO_RUNTIME_GROUP}" "${KAMAILIO_LOG_DIR}"
  touch "${KAMAILIO_LOG_DIR}/cdr-diagnostic-capture.log"
  chown root:"${KAMAILIO_RUNTIME_GROUP}" "${KAMAILIO_LOG_DIR}/cdr-diagnostic-capture.log" 2>/dev/null || chown root:root "${KAMAILIO_LOG_DIR}/cdr-diagnostic-capture.log"
  chmod 0660 "${KAMAILIO_LOG_DIR}/cdr-diagnostic-capture.log"
  cat >"${override_file}" <<'EOF_SYSTEMD_OVERRIDE'
[Service]
Type=simple
ExecStart=
User=root
Group=root
ExecStart=/usr/sbin/kamailio -DD -E -u kamailio -g kamailio -Y /run/kamailio -P /run/kamailio/kamailio.pid -f $CFGFILE -m $SHM_MEMORY -M $PKG_MEMORY --atexit=no
StandardOutput=append:/var/log/mnscloud/kamailio/kamailio.out.log
StandardError=append:/var/log/mnscloud/kamailio/kamailio.err.log
EOF_SYSTEMD_OVERRIDE
  chown root:root "${override_file}"
  chmod 0644 "${override_file}"
  run "systemctl daemon-reload"
}

ensure_kamailio_runtime_dir() {
  local owner="${KAMAILIO_RUNTIME_USER}"
  local group="${KAMAILIO_RUNTIME_GROUP}"
  if ! id -u "${owner}" >/dev/null 2>&1 || ! getent group "${group}" >/dev/null 2>&1; then
    owner="root"
    group="root"
  fi
  run "install -d -m 0770 -o '${owner}' -g '${group}' /run/kamailio"
}

enable_service() {
  run "systemctl enable kamailio"
  stop_existing_kamailio
  run "systemctl reset-failed kamailio 2>/dev/null || true"
  if ! run "systemctl start kamailio"; then
    run "systemctl status kamailio --no-pager -l || true"
    run "journalctl -xeu kamailio --no-pager -n 160 || true"
    run "journalctl -u kamailio --no-pager -l -n 160 || true"
    return 1
  fi
  if ! run "systemctl is-active kamailio"; then
    run "tail -n 160 '${KAMAILIO_LOG_DIR}/kamailio.err.log' || true"
    run "tail -n 80 '${KAMAILIO_LOG_DIR}/kamailio.out.log' || true"
    return 1
  fi
  run "sleep 2"
  if ! run "systemctl is-active kamailio"; then
    run "tail -n 160 '${KAMAILIO_LOG_DIR}/kamailio.err.log' || true"
    run "tail -n 80 '${KAMAILIO_LOG_DIR}/kamailio.out.log' || true"
    return 1
  fi
  if ! run "kamcmd system.listMethods >/dev/null"; then
    run "tail -n 160 '${KAMAILIO_LOG_DIR}/kamailio.err.log' || true"
    run "tail -n 80 '${KAMAILIO_LOG_DIR}/kamailio.out.log' || true"
    return 1
  fi
}

main() {
  require_root
  echo "kamailio        Softswitch - Kamailio 6.1.x (official repository)"
  echo "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="
  local app_security_script="${MNSCLOUD_MONOREPO_ROOT:-${PROJECT_ROOT}}/scripts/application-security.sh"
  [[ -f "${app_security_script}" ]] && run "bash '${app_security_script}'"
  ensure_local_hostname_hosts
  validate_mnscloud_agent
  ensure_api_base_file
  ensure_node_uuid_file
  ensure_api_token_file
  validate_pike_settings
  validate_uac_default_socket
  run "install -d -m 0750 '/etc/mnscloud/softswitch/runtime'"
  run "chown root:root '/etc/mnscloud/softswitch/runtime'"
  ensure_uac_db_text
  install_systemd_override
  case "$(detect_kamailio_os)" in
    debian) install_packages_debian ;;
    rocky) install_packages_rocky ;;
  esac
  stop_existing_kamailio
  bootstrap_node_via_api || true
  ensure_uac_contact_addr
  write_kamailio_config
  enable_service
  refresh_agent_capabilities
  ok "Kamailio installed. Node UUID: ${NODE_UUID}"
}

main "$@"
