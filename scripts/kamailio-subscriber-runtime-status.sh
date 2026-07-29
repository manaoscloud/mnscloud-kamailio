#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --input <subscriber-request.json>" >&2
  exit 64
}

[[ $# -eq 2 && "$1" == "--input" ]] || usage
input_file="$2"
[[ -r "$input_file" && -f "$input_file" ]] || {
  echo "Subscriber diagnostic input is not a readable file." >&2
  exit 66
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required for subscriber diagnostics." >&2
  exit 69
}
command -v kamcmd >/dev/null 2>&1 || {
  echo "kamcmd is required for subscriber diagnostics." >&2
  exit 69
}

subscriber_count="$(jq -er '.subscribers | if type == "array" then length else error("subscribers must be an array") end' "$input_file")" || {
  echo "Invalid subscriber diagnostic request." >&2
  exit 65
}
(( subscriber_count >= 1 && subscriber_count <= 500 )) || {
  echo "Subscriber diagnostic request must contain between 1 and 500 subscribers." >&2
  exit 65
}

result_file="$(mktemp)"
trap 'rm -f "$result_file"' EXIT

while IFS= read -r subscriber; do
  subscriber_uuid="$(jq -er '.subscriberUUID // empty' <<<"$subscriber")"
  username="$(jq -er '.username // empty' <<<"$subscriber")"
  domain="$(jq -er '.domain // empty' <<<"$subscriber")"

  [[ "$subscriber_uuid" =~ ^[A-Za-z0-9-]{1,64}$ ]] || {
    echo "Invalid subscriber UUID in diagnostic request." >&2
    exit 65
  }
  [[ "$username" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || {
    echo "Invalid subscriber username in diagnostic request." >&2
    exit 65
  }
  [[ "$domain" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || {
    echo "Invalid subscriber domain in diagnostic request." >&2
    exit 65
  }

  uri="sip:${username}@${domain}"
  registration_status="unknown"
  contact=""
  lookup_output=""

  if lookup_output="$(timeout 5 kamcmd ul.lookup location "$uri" 2>&1)"; then
    if grep -qi 'Contact::' <<<"$lookup_output"; then
      registration_status="registered"
      contact="$(sed -n 's/^[[:space:]]*Contact::[[:space:]]*//p' <<<"$lookup_output" | head -n 1)"
    else
      registration_status="not_registered"
    fi
  elif grep -Eqi 'not found|no such user|404|not registered' <<<"$lookup_output"; then
    registration_status="not_registered"
  fi

  jq -n \
    --arg subscriberUUID "$subscriber_uuid" \
    --arg username "$username" \
    --arg domain "$domain" \
    --arg registrationStatus "$registration_status" \
    --arg contact "$contact" \
    '{subscriberUUID: $subscriberUUID, username: $username, domain: $domain, registrationStatus: $registrationStatus, contact: (if $contact == "" then null else $contact end)}' \
    >>"$result_file"
done < <(jq -c '.subscribers[]' "$input_file")

jq -s --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{observedAt: $observedAt, subscribers: .}' "$result_file"
