# MNSCloud Kamailio Connector Skill

Use this contract when changing the `kamailio/` module or publishing `manaoscloud/mnscloud-kamailio-softswitch`.

## Public Repository Boundary

This module is a public edge connector. It may run on MNSCloud, customer, or partner servers and
consume the MNSCloud API contract. It must be fully standalone and must not depend on the private
monorepo at runtime.

## Security Rules

- Do not commit secrets, tokens, private keys, provider credentials, customer data, production IPs, or
  tenant-specific values.
- Do not copy API-side authorization, billing, tenant scoping, routing ownership, or private business
  rules into this module.
- Do not add hidden API bypasses, static master tokens, default production credentials, or privileged
  shortcuts.
- Use placeholders in examples: `<api_base>`, `<node_uuid>`, `<token>`, `<tenant_domain>`.
- Node UUIDs generated, persisted, displayed, or sent by installers must be normalized to lowercase.
- Local secrets must be generated on the target host and stored with restrictive permissions.
- Permanent provider credentials stay in the API/control plane.

## Contract

- Product repository: `manaoscloud/mnscloud-kamailio-softswitch`
- Local installer: `scripts/install-kamailio-softswitch.sh`
- Lifecycle scripts: `scripts/validate-kamailio-softswitch.sh`,
  `scripts/update-kamailio-softswitch.sh`, `scripts/update-latest-kamailio-softswitch.sh`, and
  `scripts/rollback-kamailio-softswitch.sh`
- Runtime API consumer: MNSCloud Softswitch endpoints under `/api/v1/softswitch/runtime/*`
- Runtime engine: `kamailio`; do not reintroduce engine-specific legacy runtime endpoints.
- Local state prefix: `/etc/mnscloud/softswitch`
- WebRTC SIP/WSS and local WebRTC TLS are not owned by this generic connector; use
  `mnscloud-kamailio-webrtc` for that realtime signaling edge contract.
- RTP/SRTP anchoring is consumed from the autonomous `mnscloud-media` runtime when the API assigns
  a `RealtimeMediaServer` to this Softswitch server. Do not embed media relay ownership inside this
  repository.

## Checklist

- Validate all shell scripts with `bash -n scripts/*.sh`.
- Keep REGISTER and subscriber-originated INVITE authentication fail-closed with SIP digest.
- Inbound trunk/IP routing must remain API-owned: Kamailio sends source IP and DID to `/route`, and
  only routes when the API confirms a trusted trunk/DID match.
- When `rtpengineSocket` is returned by runtime bootstrap, generated Kamailio config must load
  `rtpengine.so`, set `rtpengine_sock`, and anchor INVITE dialogs with SDP. Without that socket, the
  connector must keep running without RTP anchoring.
- Codec policy is control-plane owned. When runtime auth/route responses include
  `codecPolicy.rtpengineFlags`, pass those API-generated flags to `rtpengine_offer()` and
  `rtpengine_answer()`. Do not expose or persist arbitrary user-provided rtpengine flags in this
  connector.
- Registration trunks have one canonical identity: `username@fromDomain`, falling back to
  `username@host` when no origin domain is configured. Do not add AOR, contact or From User
  override compatibility fields.
- Search the module for sensitive values before publishing.
- Keep all required installer helpers inside this repository.
- Keep the module consuming API contracts only.
- Keep README and `kamailio.md` explicit about install, dry-run, validate, update by ref, update by
  channel, rollback scope, local state files, runtime API contract, and API/control-plane
  prerequisites.

## Contribution Governance

- External contributions must be submitted through Pull Requests.
- Follow `CONTRIBUTING.md`, `SECURITY.md`, `AGENTS.md`, and this `SKILL.md` before proposing changes.
- Do not add secrets, customer data, private infrastructure details, production domains/IPs, or hidden bypass logic.
- MNSCloud may choose to pay, sponsor, contract, or hire contributors when work demonstrates strong value, but paid work requires explicit written agreement and is never implied by opening a Pull Request.
- Keep security-sensitive decisions, tenant scope, billing, authorization, routing ownership, and secret resolution in the MNSCloud API/control plane.
