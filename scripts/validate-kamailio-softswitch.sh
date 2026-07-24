#!/usr/bin/env bash
set -Eeuo pipefail

KAMAILIO_CFG="${KAMAILIO_CFG:-/etc/kamailio/kamailio.cfg}"

echo "[validate-kamailio-softswitch] checking shell scripts"
bash -n "$(dirname "$0")/install-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/release-kamailio-softswitch.sh"
bash -n "$(dirname "$0")/sync-kamailio-softswitch-runtime.sh"

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
