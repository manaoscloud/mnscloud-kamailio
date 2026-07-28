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
- This connector installs Kamailio only. OpenSIPS remains a supported Softswitch
  engine in the control plane, but requires its own autonomous connector before
  an install command can be generated.

The API/control plane must be deployed with the canonical softswitch runtime contract before this
connector is installed or updated. This connector does not call engine-specific legacy runtime
endpoints.

## Requirements

- Debian 12/13 or Rocky Linux 8/9.
- Root privileges for package installation, `/etc/kamailio`, systemd, and `/etc/mnscloud`.
- Network reachability from the Kamailio host to the MNSCloud API base URL.
- `mnscloud-agent` already installed, enrolled, and active. The installer validates the shared
  Agent prerequisite contract with
  `/opt/mnscloud/mnscloud-agent/scripts/validate-agent.sh --require-active --require-enrolled
  --require-job voip.softswitch.runtime --require-capability voip.softswitch.manage`.
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

Clone the repository and install:

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

Use this recovery-safe command on every installed server. It first refreshes only the lifecycle
scripts from the reviewed remote `main` branch, so it also works when the local checkout predates
the update scripts. It refuses to overwrite local Git changes, resolves the published `stable`
release, reapplies the installer, and validates the resulting runtime.

```bash
sudo install -d -m 0755 /opt/mnscloud
cd /opt/mnscloud

if [ ! -d mnscloud-kamailio-softswitch/.git ]; then
  gh repo clone manaoscloud/mnscloud-kamailio-softswitch
fi

git -C mnscloud-kamailio-softswitch diff --quiet && \
  git -C mnscloud-kamailio-softswitch diff --cached --quiet || {
  echo 'Local repository changes detected; commit or stash them before updating.' >&2
  exit 1
}

git -C mnscloud-kamailio-softswitch fetch origin main --tags --prune
git -C mnscloud-kamailio-softswitch checkout origin/main -- \
  scripts/update-kamailio-softswitch.sh \
  scripts/update-latest-kamailio-softswitch.sh \
  scripts/validate-kamailio-softswitch.sh
chmod +x mnscloud-kamailio-softswitch/scripts/{update-kamailio-softswitch,update-latest-kamailio-softswitch,validate-kamailio-softswitch}.sh

cd /opt/mnscloud/mnscloud-kamailio-softswitch
sudo bash scripts/update-latest-kamailio-softswitch.sh stable
sudo bash scripts/validate-kamailio-softswitch.sh
```

After this first recovery-safe update, the normal channel update is:

```bash
sudo bash scripts/update-latest-kamailio-softswitch.sh stable
sudo bash scripts/validate-kamailio-softswitch.sh
```

To update to an explicit release, branch, tag, or commit, first run the recovery-safe bootstrap
above and then use:

```bash
sudo bash scripts/update-kamailio-softswitch.sh --ref <git-ref>
sudo bash scripts/validate-kamailio-softswitch.sh
```

Both update flows fetch the repository, checkout the target ref, rerun the installer, and then run
the validator. Existing local state under `/etc/mnscloud/softswitch` is reused. The validator
accepts the supported Kamailio 6.1 `http_client_query` or `http_client_request` call style, but
requires a single consistent style for all three runtime callbacks and quoted writable response
variables.

## Rollback

```bash
sudo bash scripts/rollback-kamailio-softswitch.sh
```

Rollback restores `/etc/kamailio/kamailio.cfg.bkp`, validates the restored config, and restarts
`kamailio.service`. It is a local Kamailio configuration rollback; API/control-plane records and
repository refs are not changed.

See `kamailio.md` and `SECURITY.md` for details.

## Runtime Behavior

- Outbound registration trunks use a single canonical SIP identity: `username`, `password`,
  `host`, optional `realm`, optional `fromDomain`, transport, port and expiration. The generated
  local identity is `username@fromDomain`; when `fromDomain` is empty it is `username@host`.
  AOR, contact user/domain and From User overrides are deliberately unsupported.
- Trunk codecs are owned by the control plane and returned as part of the runtime policy. They are
  combined with the account/subscriber and server codec policies; the connector never accepts an
  arbitrary codec or RTP-engine rule from the server filesystem.
- SIP REGISTER is authorized by the MNSCloud runtime API and then validated with real SIP digest
  authentication before the contact is saved locally.
- Unauthenticated `REGISTER` and `INVITE` bursts are dropped locally by Kamailio `pike` before
  any runtime API callback. Defaults are a 2-second sampling window, density 30, and 120-second
  cleanup; tune only through `MNSCLOUD_KAMAILIO_PIKE_*` environment variables when a measured
  traffic profile requires it.
- Authorization denials are emitted as structured `MNSCloud SIP edge denied` logs. When the host
  is assigned the `softswitch-edge` Cyber Security profile, the Agent forwards those events to
  CrowdSec so repeated source-IP abuse can be blocked by the managed edge policy. A runtime API
  `429` is translated to SIP `503` with `Retry-After`; it is an availability limit, not an
  invalid subscriber credential.
- SIP INVITE from subscribers is also proxy-authenticated before local lookup or outbound routing.
- Local subscriber-to-subscriber calls use Kamailio `usrloc` after authentication.
- Outbound calls use `/api/v1/softswitch/runtime/route`; the API remains responsible for tenant,
  policy, ownership, and route selection.
- Inbound trunk calls use `/api/v1/softswitch/runtime/route` with `direction=inbound`, source IP,
  and DID. The API only returns a route when the source IP matches the trunk `trustedCidrs` contract
  and the DID is active.
- If the API-selected Softswitch server has a media relay, INVITE dialogs with SDP are anchored via
  `mnscloud-media`/`rtpengine`; otherwise RTP remains outside this connector.
