# MNSCloud Kamailio Softswitch

Public standalone Kamailio softswitch connector for MNSCloud.

This repository installs and configures local Kamailio runtime assets that consume the MNSCloud API
contract. It can run on MNSCloud, customer, or partner infrastructure.

## Boundary

- This repository is public and auditable by design.
- It must remain standalone and must not depend on the private MNSCloud monorepo at runtime.
- The MNSCloud API is the source of truth for authorization, tenant scope, routing ownership, billing,
  policy, and secret resolution.
- Do not commit secrets, customer data, production infrastructure values, provider credentials, or
  private business rules.
- This repository is the generic Kamailio softswitch/SIP connector. RTP/SRTP media anchoring is
  consumed from the autonomous `mnscloud-media` runtime when the API assigns a media relay to this
  Softswitch server.
- WebRTC SIP over WebSocket and local WebRTC TLS termination remain in
  `mnscloud-kamailio-webrtc`; the media relay itself remains reusable infrastructure owned by
  `mnscloud-media`.

## Contract

- Product/runtime: `mnscloud-kamailio-softswitch`
- Project directory: `/opt/mnscloud/mnscloud-kamailio-softswitch`
- Installer: `scripts/install-kamailio-softswitch.sh`
- Validator: `scripts/validate-kamailio-softswitch.sh`
- Update by ref: `scripts/update-kamailio-softswitch.sh --ref <git-ref>`
- Update channel: `scripts/update-latest-kamailio-softswitch.sh [stable]`
- Rollback local Kamailio cfg: `scripts/rollback-kamailio-softswitch.sh`
- Shared package installer: `mnscloud-runtime-kit`
- Service: `kamailio.service`
- Local state prefix: `/etc/mnscloud/softswitch`
- Node UUID: `/etc/mnscloud/softswitch/node.uuid`
- API token: `/etc/mnscloud/softswitch/api.token`
- API base URL: `/etc/mnscloud/softswitch/api.base`
- Kamailio config: `/etc/kamailio/kamailio.cfg`
- Config validation: `kamailio -c -f /etc/kamailio/kamailio.cfg`
- Runtime API: `/api/v1/softswitch/runtime/*`
- Runtime engine: `kamailio`
- Optional media relay: API-selected `RealtimeMediaServer` exposed to Kamailio as an
  `rtpengineSocket`.

The API/control plane must be deployed with the canonical softswitch runtime contract before this
connector is installed or updated. This connector does not call engine-specific legacy runtime
endpoints.

## Requirements

- Debian 12/13 or Rocky Linux 8/9.
- Root privileges for package installation, `/etc/kamailio`, systemd, and `/etc/mnscloud`.
- Network reachability from the Kamailio host to the MNSCloud API base URL.
- `mnscloud-agent` already installed, enrolled, and active. The installer validates the shared
  Agent prerequisite contract with
  `/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh --require-active --require-enrolled`.
- A `VoipSoftswitchServer` record in the API/control plane for this runtime, with engine
  `kamailio` and a matching `VsrNodeUUID`, or an operational bootstrap flow that can bind the local
  node UUID.
- Optional: an active `RealtimeMediaServer` selected on the `VoipSoftswitchServer` record when this
  node must anchor RTP/SRTP through `mnscloud-media`.
- SIP firewall rules opened according to the deployment model, typically `5060/udp` and `5060/tcp`.

## Install

Install GitHub CLI if needed:
[cli/cli installation](https://github.com/cli/cli#installation).

Authenticate GitHub CLI:

```bash
gh auth login
```

Clone the private repository and install:

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud
gh repo clone manaoscloud/mnscloud-kamailio-softswitch
cd /opt/mnscloud/mnscloud-kamailio-softswitch
sudo bash scripts/install-kamailio-softswitch.sh
```

For a no-change preview:

```bash
sudo bash scripts/install-kamailio-softswitch.sh --dry-run
```

The installer creates or reuses `/etc/mnscloud/softswitch/node.uuid`,
`/etc/mnscloud/softswitch/api.token`, and `/etc/mnscloud/softswitch/api.base`, writes the Kamailio
configuration, validates bootstrap against the API when possible, and keeps the original
`/etc/kamailio/kamailio.cfg` as `/etc/kamailio/kamailio.cfg.bkp`.
API-generated commands may pass `MNSCLOUD_API_BASE`, `MNSCLOUD_SOFTSWITCH_NODE_UUID`, and
`MNSCLOUD_SOFTSWITCH_API_TOKEN`; when present, the installer persists those values before
bootstrapping.
When the API returns `rtpengineSocket`, the installer stores it in
`/etc/mnscloud/softswitch/media.socket` and enables Kamailio `rtpengine` handling in the generated
configuration. Without an assigned media relay, Kamailio runs as SIP signaling/proxy only.
When runtime route/auth responses include `codecPolicy.rtpengineFlags`, the generated Kamailio
configuration passes those control-plane generated flags to `rtpengine_offer()` and
`rtpengine_answer()`. Codec manipulation remains fail-closed and API-owned: this connector must not
accept tenant-provided raw rtpengine flags or invent local transcoding policy.

## Validate

```bash
sudo bash scripts/validate-kamailio-softswitch.sh
sudo kamailio -c -f /etc/kamailio/kamailio.cfg
sudo systemctl status kamailio
```

The validator checks shell syntax and, when Kamailio is installed, validates the active Kamailio
configuration.

## Update

Update to an explicit release, branch, tag, or commit:

```bash
sudo bash scripts/update-kamailio-softswitch.sh --ref v0.1.5
```

Update to the release manifest channel, defaulting to `stable`:

```bash
sudo bash scripts/update-latest-kamailio-softswitch.sh stable
```

Both update flows fetch the repository, checkout the target ref, rerun the installer, and then run
the validator. Existing local state under `/etc/mnscloud/softswitch` is reused.

## Rollback

```bash
sudo bash scripts/rollback-kamailio-softswitch.sh
```

Rollback restores `/etc/kamailio/kamailio.cfg.bkp`, validates the restored config, and restarts
`kamailio.service`. It is a local Kamailio configuration rollback; API/control-plane records and
repository refs are not changed.

See `kamailio.md` and `SECURITY.md` for details.

## Runtime Behavior

- SIP REGISTER is authorized by the MNSCloud runtime API and then validated with real SIP digest
  authentication before the contact is saved locally.
- SIP INVITE from subscribers is also proxy-authenticated before local lookup or outbound routing.
- Local subscriber-to-subscriber calls use Kamailio `usrloc` after authentication.
- Outbound calls use `/api/v1/softswitch/runtime/route`; the API remains responsible for tenant,
  policy, ownership, and route selection.
- Inbound trunk calls use `/api/v1/softswitch/runtime/route` with `direction=inbound`, source IP,
  and DID. The API only returns a route when the source IP matches the trunk `trustedCidrs` contract
  and the DID is active.
- If the API-selected Softswitch server has a media relay, INVITE dialogs with SDP are anchored via
  `mnscloud-media`/`rtpengine`; otherwise RTP remains outside this connector.
