#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 2 && "$1" == --input && -r "$2" && -f "$2" ]] || { echo 'Usage: kamailio-trunk-runtime-status.sh --input <json>' >&2; exit 64; }
command -v jq >/dev/null && command -v kamcmd >/dev/null || { echo 'jq and kamcmd are required.' >&2; exit 69; }
rpc_string() { printf 's:%s' "$1"; }
input="$2"; count="$(jq -er '.trunks | if type == "array" then length else error("trunks") end' "$input")"
(( count >= 1 && count <= 500 )) || { echo 'Trunk request must contain 1..500 trunks.' >&2; exit 65; }
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
while IFS= read -r trunk; do
  uuid="$(jq -er '.trunkUUID // empty' <<<"$trunk")"; name="$(jq -er '.name // empty' <<<"$trunk")"; mode="$(jq -er '.authenticationMode // empty' <<<"$trunk")"
  [[ "$uuid" =~ ^[A-Za-z0-9-]{1,64}$ && "$name" =~ ^[A-Za-z0-9._-]{1,100}$ && "$mode" =~ ^(register|ip_acl|none)$ ]] || { echo 'Invalid trunk diagnostic target.' >&2; exit 65; }
  status='not_applicable'; detail='Registration is not configured.'; runtime_error=''
  if [[ "$mode" == register ]]; then
    # The UAC RPC contract filters by attribute and value. The synchronizer uses
    # the UUID as l_uuid, so this gives an exact, bounded lookup.
    result=''; command_status=0
    result="$(timeout 5 kamcmd uac.reg_info l_uuid "$(rpc_string "$uuid")" 2>&1)" || command_status=$?
    entry="$result"
    if [[ -z "$entry" ]] || grep -Eqi 'not found|no such|does not exist|not registered|record not found|(^|[[:space:]])(error:[[:space:]]*)?404([[:space:]]|$)' <<<"$entry"; then
      status=not_registered; detail='Kamailio has no active trunk registration.'
      runtime_error="$(tr '\n' ' ' <<<"${entry:-$result}" | sed -E 's/[[:space:]]+/ /g; s/(password|authorization|credential)[^ ]*/[redacted]/Ig' | cut -c1-300)"
      if grep -Eqi 'command uac\.reg_info not found' <<<"$result"; then
        methods="$(timeout 5 kamcmd system.listMethods 2>&1 | grep -E '(^|[[:space:]])(uac\.|system\.)' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-180 || true)"
        modules="$(timeout 5 kamcmd core.modules 2>&1 | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-180 || true)"
        runtime_error="UAC registration RPC is unavailable in the running Kamailio process.${methods:+ Available RPCs: ${methods}}${modules:+ Loaded modules: ${modules}}"
      fi
    elif grep -Eqi 'registered|state[=: ]+ok' <<<"$entry"; then status=registered; detail='Kamailio registration is active.'
    elif grep -Eqi 'registering|trying' <<<"$entry"; then status=registering; detail='Kamailio is registering the trunk.'
    else
      status=unknown; detail='Kamailio could not determine the trunk registration state.'
      runtime_error="$(tr '\n' ' ' <<<"$result" | sed -E 's/[[:space:]]+/ /g' | cut -c1-300)"
      [[ -n "$runtime_error" ]] || runtime_error="kamcmd exited with status ${command_status}."
    fi
  fi
  jq -n --arg trunkUUID "$uuid" --arg name "$name" --arg registrationStatus "$status" --arg detail "$detail" --arg runtimeError "$runtime_error" '{trunkUUID:$trunkUUID,name:$name,registrationStatus:$registrationStatus,detail:$detail,runtimeError:(if $runtimeError=="" then null else $runtimeError end)}' >>"$out"
done < <(jq -c '.trunks[]' "$input")
jq -s --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{observedAt:$observedAt,trunks:.}' "$out"
