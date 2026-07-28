#!/usr/bin/env bash
set -Eeuo pipefail

KAMAILIO_CFG="${KAMAILIO_CFG:-/etc/kamailio/kamailio.cfg}"

echo "[validate-kamailio-softswitch] checking shell scripts"
bash -n "$(dirname "$0")/install-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/release-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/sync-kamailio-softswitch-runtime.sh"

installer="$(dirname "$0")/install-kamailio-softswitch.sh"
echo "[validate-kamailio-softswitch] checking Kamailio HTTP runtime template"
grep -Fq 'modparam(\"http_client\", \"query_result\", 0)' "$installer"
query_calls="$(grep -Fc 'http_client_query(' "$installer")"
[[ "$query_calls" == "3" ]] || {
  echo "[validate-kamailio-softswitch] expected three http_client_query calls, found ${query_calls}" >&2
  exit 1
}
for response_var in auth_reply route_reply inbound_reply; do
  grep -Fq "\\\"\\\$var(${response_var})\\\"" "$installer" || {
    echo "[validate-kamailio-softswitch] missing quoted writable response variable for ${response_var}" >&2
    exit 1
  }
done

if command -v kamailio >/dev/null 2>&1 && [[ -r "$KAMAILIO_CFG" ]]; then
  echo "[validate-kamailio-softswitch] checking ${KAMAILIO_CFG}"
  kamailio -c -f "$KAMAILIO_CFG"
else
  echo "[validate-kamailio-softswitch] kamailio or ${KAMAILIO_CFG} not available; skipped runtime cfg check"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files kamailio.service >/dev/null 2>&1; then
  systemctl is-enabled kamailio >/dev/null 2>&1 || true
  systemctl is-active kamailio >/dev/null 2>&1 || true
fi

echo "[validate-kamailio-softswitch] ok"
