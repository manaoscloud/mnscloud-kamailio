#!/usr/bin/env bash
set -Eeuo pipefail

KAMAILIO_CFG="${KAMAILIO_CFG:-/etc/kamailio/kamailio.cfg}"

echo "[validate-kamailio-softswitch] checking shell scripts"
bash -n "$(dirname "$0")/install-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/release-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/sync-kamailio-softswitch-runtime.sh"
bash -n "$(dirname "$0")/kamailio-subscriber-runtime-status.sh"
! grep -Fq '"${username}" \' "$(dirname "$0")/kamailio-subscriber-runtime-status.sh"
! grep -Fq '"${username_lower}"' "$(dirname "$0")/kamailio-subscriber-runtime-status.sh"
bash -n "$(dirname "$0")/kamailio-trunk-runtime-status.sh"
bash -n "$(dirname "$0")/update-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/update-latest-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/rollback-kamailio-softswitch.sh"

installer="$(dirname "$0")/install-kamailio-softswitch.sh"
echo "[validate-kamailio-softswitch] checking Kamailio HTTP runtime template"
grep -Fq 'loadmodule \"pike.so\"' "$installer"
grep -Fq 'loadmodule \"path.so\"' "$installer"
grep -Fq 'pike_check_req()' "$installer"
grep -Fq 'loadmodule \"db_text.so\"' "$installer"
grep -Fq 'modparam(\"uac\", \"reg_db_url\", \"text://' "$installer"
grep -Fq 'modparam(\"uac\", \"reg_contact_addr\", \"' "$installer"
grep -Fq 'modparam(\"uac\", \"default_socket\", \"' "$installer"
grep -Fq 'modparam(\"uac\", \"reg_active\", 1)' "$installer"
grep -Fq 'modparam(\"usrloc\", \"use_domain\", 1)' "$installer"
grep -Fq 'modparam(\"registrar\", \"use_path\", 1)' "$installer"
grep -Fq 'modparam(\"registrar\", \"path_mode\", 0)' "$installer"
grep -Fq 'if (\$tU != \"\")' "$installer"
grep -Fq 'MNSCloud inbound route lookup source=' "$installer"
grep -Fq 'user_agent_header=\"User-Agent: MNSCloud Kamailio Softswitch\"' "$installer"
grep -Fq 'server_header=\"Server: MNSCloud Kamailio Softswitch\"' "$installer"
grep -Fq 'resolve_kamailio_sip_listen_ip' "$installer"
grep -Fq 'listen=udp:${KAMAILIO_SIP_LISTEN_IP}:5060 advertise ${public_ip}:5060' "$installer"
grep -Fq 'listen=tcp:${KAMAILIO_SIP_LISTEN_IP}:5060 advertise ${public_ip}:5060' "$installer"
grep -Fq 'alias=\"${KAMAILIO_SIP_LISTEN_IP}:5060\"' "$installer"
grep -Fq 'alias=\"${public_ip}:5060\"' "$installer"
grep -Fq 'UAC_DEFAULT_SOCKET="udp:${KAMAILIO_SIP_LISTEN_IP}:5060"' "$installer"
grep -Fq 'if (is_method(\"CANCEL\"))' "$installer"
grep -Fq 't_check_trans()' "$installer"
! grep -Fq 'consuming stacked local Route' "$installer"
! grep -Fq 'listen=udp:0.0.0.0:5060' "$installer"
! grep -Fq 'listen=tcp:0.0.0.0:5060' "$installer"
grep -Fq 'KAMAILIO_RUNTIME_USER' "$installer"
grep -Fq "chmod 0640 '" "$installer"
grep -Fq 'systemctl reset-failed kamailio' "$installer"
grep -Fq 'StandardOutput=append:' "$installer"
grep -Fq 'StandardError=append:' "$installer"
grep -Fq 'MNSCLOUD_SKIP_AGENT_REFRESH' "$installer"
grep -Fq 'Skipping mnscloud-agent capability refresh for this lifecycle run.' "$installer"
grep -Fq 'MNSCLOUD_SKIP_AGENT_REFRESH=true bash "${SCRIPT_DIR}/install-kamailio-softswitch.sh"' scripts/update-kamailio-softswitch.sh
grep -Fq 'Type=simple' "$installer"
grep -Fq 'kamailio -DD -E' "$installer"
grep -Fq 'User=root' "$installer"
grep -Fq 'Group=root' "$installer"
grep -Fq -- '-u kamailio -g kamailio' "$installer"
grep -Fq -- '-Y /run/kamailio' "$installer"
grep -Fq 'kamcmd system.listMethods' "$installer"
grep -Fq 'kamailio.err.log' "$installer"
grep -Fq 'ensure_kamailio_runtime_dir' "$installer"
! grep -Fq "runuser -u '" "$installer"
grep -Fq 'id(int,auto) table_name(str) table_version(int)' "$installer"
grep -Fq '1:uacreg:5' "$installer"
grep -Fq 'l_uuid(str)' "$installer"
grep -Fq 'recent kamailio log:' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'UAC_RELOAD_MIN_INTERVAL' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'flock -x' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'registration_is_active_or_in_progress' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'flag_value & 14' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'only initialized; it is not enough to skip reg_register' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'managed stderr:' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'registration_diagnostic' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'register_existing_registration' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'remove_existing_registration' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'uac.reg_remove' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'unregister_existing_registration' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'deactivate_existing_registration' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'uac.reg_unregister' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'dump_runtime_registration_ids' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'uac.reg_dump' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'purge_orphaned_runtime_registrations' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'not present in runtime policy' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'runtime_response_has_registration_id' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'reload_status == 75' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq '"$proxy" == "null"' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'auth_password|password|authorization|credential' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'failed to shift records' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'temporarily deferred' scripts/sync-kamailio-softswitch-runtime.sh
! grep -Fq 'sleep "$UAC_RELOAD_MIN_INTERVAL"' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'if (!(\$var(auth_authorized) =~ \"^(true|1)$\"))' "$installer"
grep -Fq '\$du = \$var(dialog_request_uri);' "$installer" || {
  echo "[validate-kamailio-softswitch] dialog route must force destination URI when API returns a direct dialog Request-URI" >&2
  exit 1
}
grep -Fq 'MNSCloud in-dialog ACK dialog-routed before loose_route' "$installer" || {
  echo "[validate-kamailio-softswitch] ACK 2xx dialog routing must run before loose_route" >&2
  exit 1
}
grep -Fq 'MNSCloud in-dialog ACK forward failed' "$installer" || {
  echo "[validate-kamailio-softswitch] ACK 2xx dialog routing must use stateless forward diagnostics" >&2
  exit 1
}
grep -Fq '\$var(dialog_routed) = \"1\";' "$installer" || {
  echo "[validate-kamailio-softswitch] dialog route must set an explicit routed flag" >&2
  exit 1
}
grep -Fq 'is_method(\"ACK\") && \$var(dialog_routed) == \"1\"' "$installer" || {
  echo "[validate-kamailio-softswitch] ACK routing must test the explicit dialog routed flag" >&2
  exit 1
}
grep -Fq 'UAC_DEFAULT_SOCKET' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'private_ipv4()' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'UAC_DEFAULT_SOCKET="${UAC_DEFAULT_SOCKET/0.0.0.0/${detected_private_ip}}"' scripts/sync-kamailio-softswitch-runtime.sh
grep -Fq 'KAMAILIO_RUNTIME_USER' scripts/sync-kamailio-softswitch-runtime.sh

validate_http_client_calls() {
  local target="$1" scope="$2" query_calls request_calls
  query_calls="$(grep -Fc 'http_client_query(' "$target" || true)"
  request_calls="$(grep -Fc 'http_client_request(' "$target" || true)"

  if [[ "$query_calls" -ge "3" && "$request_calls" == "0" ]]; then
    # The installer heredoc keeps quotes escaped, while the deployed Kamailio
    # configuration contains literal quotes. Validate the same required option
    # in either representation so a healthy runtime is never reported as bad.
    { grep -Fq 'modparam(\"http_client\", \"query_result\", 0)' "$target" ||
      grep -Fq 'modparam("http_client", "query_result", 0)' "$target"; } || {
      echo "[validate-kamailio-softswitch] ${scope} uses http_client_query without query_result=0" >&2
      exit 1
    }
    return 0
  fi

  if [[ "$request_calls" -ge "3" && "$query_calls" == "0" ]]; then
    return 0
  fi

  echo "[validate-kamailio-softswitch] ${scope} must use consistent HTTP runtime calls; found http_client_query=${query_calls}, http_client_request=${request_calls}" >&2
  exit 1
}

validate_http_client_calls "$installer" "runtime template"
for response_var in auth_reply route_reply inbound_reply accounting_reply; do
  grep -Fq "\\\"\\\$var(${response_var})\\\"" "$installer" || {
    echo "[validate-kamailio-softswitch] missing quoted writable response variable for ${response_var}" >&2
    exit 1
  }
done

is_managed_runtime_config() {
  [[ -r "$1" ]] && grep -Fq '# MNSCloud managed Kamailio Softswitch runtime' "$1"
}

if is_managed_runtime_config "$KAMAILIO_CFG"; then
  echo "[validate-kamailio-softswitch] checking deployed runtime contract in ${KAMAILIO_CFG}"
  grep -Fq 'loadmodule "pike.so"' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing pike.so" >&2
    exit 1
  }
  grep -Fq 'pike_check_req()' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing pike request protection" >&2
    exit 1
  }
  grep -Fq 'loadmodule "db_text.so"' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing db_text.so for UAC remote registrations" >&2
    exit 1
  }
  grep -Fq 'modparam("uac", "reg_db_url", "text://' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing UAC reg_db_url text backend" >&2
    exit 1
  }
  grep -Fq 'modparam("uac", "reg_contact_addr", "' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing UAC reg_contact_addr" >&2
    exit 1
  }
  grep -Fq 'modparam("uac", "reg_active", 1)' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing UAC reg_active=1" >&2
    exit 1
  }
  grep -Fq 'if ($tU != "")' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing To-user DID inbound fallback" >&2
    exit 1
  }
  grep -Fq 'MNSCloud inbound route lookup source=' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing inbound route diagnostic log" >&2
    exit 1
  }
  grep -Fq 'user_agent_header="User-Agent: MNSCloud Kamailio Softswitch"' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing MNSCloud User-Agent header" >&2
    exit 1
  }
  grep -Fq 'server_header="Server: MNSCloud Kamailio Softswitch"' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing MNSCloud Server header" >&2
    exit 1
  }
  ! grep -Fq 'listen=udp:0.0.0.0:5060' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config must not advertise 0.0.0.0 for UDP SIP" >&2
    exit 1
  }
  ! grep -Fq 'listen=tcp:0.0.0.0:5060' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config must not advertise 0.0.0.0 for TCP SIP" >&2
    exit 1
  }
  grep -Fq 'if (is_method("CANCEL"))' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing CANCEL transaction handling" >&2
    exit 1
  }
  grep -Fq 't_check_trans()' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing CANCEL t_check_trans handling" >&2
    exit 1
  }
  ! grep -Fq 'modparam("uac", "default_socket", "udp:0.0.0.0:5060")' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config must not use 0.0.0.0 as UAC default_socket" >&2
    exit 1
  }
  validate_http_client_calls "$KAMAILIO_CFG" "deployed config"
  for response_var in auth_reply route_reply inbound_reply; do
    grep -Fq "\"\$var(${response_var})\"" "$KAMAILIO_CFG" || {
      echo "[validate-kamailio-softswitch] deployed config has an unquoted or missing response variable: ${response_var}" >&2
      exit 1
    }
  done
elif [[ -r "$KAMAILIO_CFG" ]]; then
  echo "[validate-kamailio-softswitch] ${KAMAILIO_CFG} is not an MNSCloud managed runtime; skipped deployed runtime contract"
fi

if command -v kamailio >/dev/null 2>&1 && is_managed_runtime_config "$KAMAILIO_CFG"; then
  echo "[validate-kamailio-softswitch] checking Kamailio syntax in ${KAMAILIO_CFG}"
  kamailio -c -f "$KAMAILIO_CFG"
else
  echo "[validate-kamailio-softswitch] managed Kamailio runtime config not available; skipped syntax check"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files kamailio.service >/dev/null 2>&1; then
  systemctl is-enabled kamailio >/dev/null 2>&1 || true
  systemctl is-active kamailio >/dev/null 2>&1 || true
fi

echo "[validate-kamailio-softswitch] ok"
