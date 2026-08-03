#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 2 && "$1" == --input && -r "$2" && -f "$2" ]] || { echo 'Usage: kamailio-trunk-runtime-status.sh --input <json>' >&2; exit 64; }
command -v jq >/dev/null && command -v kamcmd >/dev/null || { echo 'jq and kamcmd are required.' >&2; exit 69; }
input="$2"; count="$(jq -er '.trunks | if type == "array" then length else error("trunks") end' "$input")"
(( count >= 1 && count <= 500 )) || { echo 'Trunk request must contain 1..500 trunks.' >&2; exit 65; }
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
while IFS= read -r trunk; do
  uuid="$(jq -er '.trunkUUID // empty' <<<"$trunk")"; name="$(jq -er '.name // empty' <<<"$trunk")"; mode="$(jq -er '.authenticationMode // empty' <<<"$trunk")"
  [[ "$uuid" =~ ^[A-Za-z0-9-]{1,64}$ && "$name" =~ ^[A-Za-z0-9._-]{1,100}$ && "$mode" =~ ^(register|ip_acl|none)$ ]] || { echo 'Invalid trunk diagnostic target.' >&2; exit 65; }
  status='not_applicable'; detail='Registration is not configured.'
  if [[ "$mode" == register ]]; then
    # Fixed command and validated, locally generated name: no caller input reaches a shell.
    result="$(timeout 5 kamcmd uac.reg_info "$name" 2>&1 || true)"
    if grep -Eqi 'registered|state[=: ]+ok' <<<"$result"; then status=registered; detail='Kamailio registration is active.'
    elif grep -Eqi 'registering|trying' <<<"$result"; then status=registering; detail='Kamailio is registering the trunk.'
    elif [[ -n "$result" ]]; then status=not_registered; detail='Kamailio has no active trunk registration.'
    else status=unknown; detail='Kamailio did not return registration information.'; fi
  fi
  jq -n --arg trunkUUID "$uuid" --arg name "$name" --arg registrationStatus "$status" --arg detail "$detail" '{trunkUUID:$trunkUUID,name:$name,registrationStatus:$registrationStatus,detail:$detail}' >>"$out"
done < <(jq -c '.trunks[]' "$input")
jq -s --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{observedAt:$observedAt,trunks:.}' "$out"
