#!/usr/bin/env bash
set -Eeuo pipefail

KAMAILIO_CFG="${KAMAILIO_CFG:-/etc/kamailio/kamailio.cfg}"

echo "[validate-kamailio-softswitch] checking shell scripts"
bash -n "$(dirname "$0")/install-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/release-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/sync-kamailio-softswitch-runtime.sh"
bash -n "$(dirname "$0")/kamailio-subscriber-runtime-status.sh"
bash -n "$(dirname "$0")/kamailio-trunk-runtime-status.sh"
bash -n "$(dirname "$0")/update-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/update-latest-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/rollback-kamailio-softswitch.sh"

installer="$(dirname "$0")/install-kamailio-softswitch.sh"
echo "[validate-kamailio-softswitch] checking Kamailio HTTP runtime template"
grep -Fq 'loadmodule \"pike.so\"' "$installer"
grep -Fq 'pike_check_req()' "$installer"
grep -Fq 'loadmodule \"db_text.so\"' "$installer"
grep -Fq 'modparam(\"uac\", \"reg_db_url\", \"db_text://' "$installer"
grep -Fq 'uacreg:5' "$installer"

validate_http_client_calls() {
  local target="$1" scope="$2" query_calls request_calls
  query_calls="$(grep -Fc 'http_client_query(' "$target" || true)"
  request_calls="$(grep -Fc 'http_client_request(' "$target" || true)"

  if [[ "$query_calls" == "3" && "$request_calls" == "0" ]]; then
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

  if [[ "$request_calls" == "3" && "$query_calls" == "0" ]]; then
    return 0
  fi

  echo "[validate-kamailio-softswitch] ${scope} must use exactly three consistent HTTP runtime calls; found http_client_query=${query_calls}, http_client_request=${request_calls}" >&2
  exit 1
}

validate_http_client_calls "$installer" "runtime template"
for response_var in auth_reply route_reply inbound_reply; do
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
  grep -Fq 'modparam("uac", "reg_db_url", "db_text://' "$KAMAILIO_CFG" || {
    echo "[validate-kamailio-softswitch] deployed config is missing UAC reg_db_url db_text backend" >&2
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
