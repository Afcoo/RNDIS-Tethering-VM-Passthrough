# AGENTS.md

This repository is a macOS 27+ USB RNDIS tethering VM project. Future agents
should read this file before the README and treat the current
WireGuard-over-VZNAT architecture as the baseline.

## Project Shape

- The app is a SwiftUI Dock app, not a CLI `main.swift` entrypoint.
- The Xcode project is `RNDIS Tethering VM Passthrough.xcodeproj`.
- The main app target is `RTPVM` and builds a macOS app bundle.
- There is no host packet-tunnel extension target. The app does not create a
  host VPN, and does not inspect or forward packet payloads.
- Linux assets are not bundled. Users load the generated asset folder or select
  the kernel, initramfs, and raw disk image from the app UI.

## Architecture

- `TetheringStore` owns app state, VM lifecycle, USB accessory selection,
  WireGuard configuration state, and the console/event logs.
- `WireGuardConfigurationLoader` loads generated `wg-server.conf` and
  `wg-client.conf` files from the selected asset tree for preview/export.
  It must not hard-code WireGuard key material.
- `VMConfigurationFactory` builds the Linux VM configuration. The current
  baseline uses `VZLinuxBootLoader`, raw disk attachment, an XHCI USB
  controller, and `VZNATNetworkDeviceAttachment`.
- USB passthrough must stay on the public API path that passes an
  AccessoryAccess `AAUSBAccessory` into
  `VZUSBPassthroughDeviceConfiguration(device:)`.
- The guest owns packet forwarding by running a normal WireGuard peer on the
  Virtualization NAT private network and masquerading WireGuard client traffic
  out the USB RNDIS interface.
- The host side is intentionally manual: users configure the host WireGuard
  client from the generated client `.conf`. The official WireGuard macOS client
  currently has a connection bring-up issue in this validation flow; recommend
  `wireguard-go` for macOS validation. This app must not start, stop, or manage
  the host WireGuard tunnel.

## Data Path

The current baseline data path is:

```text
macOS WireGuard client
-> VZNAT guest endpoint UDP/51820
-> guest wg0
-> guest nftables masquerade
-> USB RNDIS upstream
```

- The current manual WireGuard test addresses are guest `10.100.0.1/24` and
  macOS host tunnel `10.100.0.2/24`; the guest peer should allow
  `10.100.0.2/32`.
  This is the WireGuard overlay address, not the guest `usb0` RNDIS DHCP
  address.
- The guest WireGuard server listens on UDP port `51820`.
- The app parses `RTPVM_WG_ENDPOINT=<guest-nat-ip>:51820` from serial console
  output. The BusyBox init network one-shot prints that marker after VZNAT
  `eth0` DHCP succeeds.
- `script/make_vm_assets` uses the host `wg` CLI from Homebrew's
  `wireguard-tools` to generate fresh WireGuard server/client keypairs, writes
  `script/assets/wireguard/wg-server.conf` and
  `script/assets/wireguard/wg-client.conf`, then builds the initramfs.
  The server config is copied into the RAM-backed guest as
  `/etc/wireguard/wg0.conf`.
- The generated initramfs runs BusyBox `init` as PID 1. Its `once` network
  action runs `wg-quick up wg0` after the VZNAT `eth0` DHCP step, then waits
  for fixed `usb0` RNDIS DHCP, source policy routing from `10.100.0.0/24` to
  the RNDIS default gateway, IPv4 forwarding, and scoped nftables masquerade
  from `wg0` to `usb0`.
- The generated client `.conf` acts as a WireGuard client and uses
  `<RTPVM_WG_ENDPOINT>` as a placeholder for the discovered guest VZNAT address.
  The client `.conf` uses IPv4 full-tunnel routing with
  `AllowedIPs = 10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1`. Keep the explicit
  overlay route so `10.100.0.1` remains reachable, and prefer split internet
  routes over `0.0.0.0/0` on macOS to avoid a bad `wg-quick` direct route over
  the VZNAT endpoint. IPv6 tunneling remains out of scope until RNDIS IPv6 is
  tested.
- The BusyBox init network one-shot brings up the VZNAT NIC `eth0` and runs
  `udhcpc` so the guest has an IPv4 endpoint address during early boot.
- The guest RNDIS interface is fixed to `usb0`. The app supports one
  passthrough RNDIS accessory per VM session; if that accessory detaches, the
  app restarts the VM instead of attaching a replacement into the same
  guest session.
- Guest NAT is based on `nftables` masquerade from `wg0` traffic to `usb0`.
- The setup NAT NIC provides the private host-to-guest network used for the
  WireGuard endpoint. Do not
  replace it with vmnet, bridged networking, route-command UI, or a host-side
  packet-tunnel provider.

## Directory Guide

- `RTPVM/App`: SwiftUI app entrypoint and top-level commands.
- `RTPVM/Views`: setup, USB, console, and WireGuard views.
- `RTPVM/Stores`: `TetheringStore` orchestration and
  `WireGuardConfigurationLoader` key/config loading and host config rendering.
- `RTPVM/Services`: AccessoryAccess monitor, VM configuration
  factory, and VM delegate glue.
- `RTPVM/Support`: file picker, clipboard, and runtime entitlement
  reader helpers.
- `RTPVM/GuestScripts`: currently empty. The generated RTPVM
  initramfs includes a server WireGuard config but still does not install or
  start a guest WireGuard setup script.
- `RTPVM/Models`: sidebar sections, USB accessory records, VM
  state, and WireGuard settings.
- `script`: local build/run/debug/verify entrypoints and Alpine asset
  generation.
- `script/initramfs`: source files copied into the generated initramfs for
  BusyBox init: `rcS`, `init-network`, and `init-console`.

## Build And Run

- Local compile/UI iteration should not treat signing as the default blocker.
- Default run:

```sh
./script/build_and_run.sh
```

- The default script builds the `RNDIS Tethering VM Passthrough` scheme,
  `Debug` configuration, with `CODE_SIGNING_ALLOWED=NO`, then opens the app.
- For direct builds, prefer the Xcode beta `xcodebuild`:

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project "RNDIS Tethering VM Passthrough.xcodeproj" \
  -scheme "RNDIS Tethering VM Passthrough" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/RTPVM-DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

- Runtime signing checks are meaningful only after the required entitlements are
  included in the provisioning profile.

```sh
./script/build_and_run.sh --runtime
```

- `--runtime` uses the `RNDIS Tethering VM Passthrough Runtime` scheme and
  the `RuntimeDebug` configuration, and does not disable signing.

## Signing And Entitlements

- The current baseline is WireGuard-over-VZNAT. Do not reintroduce host
  packet-tunnel extension code, app-local packet relays, virtio-socket packet
  bridges, vmnet, `VZVmnetNetworkDeviceAttachment`, or
  `VZBridgedNetworkDeviceAttachment`.
- Checked-in signing defaults live in `Configuration/BuildSettings.xcconfig`.
  This file intentionally uses placeholder bundle identifiers and no
  development team.
- For local runtime signing, copy
  `Configuration/LocalSigning.xcconfig.example` to
  `Configuration/LocalSigning.xcconfig` and set the local `DEVELOPMENT_TEAM` and
  app bundle identifier there. The local file is intentionally ignored by Git.
- Do not hard-code a personal development team ID, provisioning profile, or local
  bundle identifier into the Xcode project file.
- `RTPVM.entitlements` is the main app entitlement file used by
  the standard app target configurations and includes:
  - `com.apple.developer.accessory-access.usb`
  - `com.apple.security.virtualization`
- `Runtime.entitlements` mirrors the same runtime entitlement set for
  `RuntimeDebug` validation and includes:
  - `com.apple.developer.accessory-access.usb`
  - `com.apple.security.virtualization`
- If restricted entitlements are missing from the provisioning profile, the
  runtime path fails. Do not use ad hoc signing as a substitute for restricted
  entitlement runtime validation.

## Development Notes

- The host WireGuard client is user-managed outside this app. The app may
  generate/copy/save `.conf` files but must not install or activate host VPN
  configurations. For macOS validation, prefer `wireguard-go` over the official
  WireGuard macOS GUI client until the current bring-up issue is understood.
- WireGuard private/public keys are generated by `script/make_vm_assets` at
  asset build time using `wg genkey` and `wg pubkey`. Require
  `brew install wireguard-tools` or `WG_BIN=/path/to/wg`; do not restore
  hardcoded server or client keys in Swift, shell scripts, README examples, or
  AGENTS guidance.
- BusyBox `init` is the generated initramfs PID 1. Its `sysinit` action mounts
  the early filesystems and only prepares the console-side early boot path. Its
  network `once` action loads the VZNAT, WireGuard, RNDIS, and netfilter
  modules it needs, configures the VZNAT setup NIC by bringing up `eth0` and
  running `udhcpc` for IPv4, then starts `wg0` with `wg-quick up wg0`, waits
  briefly for fixed RNDIS `usb0`, runs DHCP on `usb0`, installs source policy
  routing for `10.100.0.0/24` via the RNDIS default gateway, enables IPv4
  forwarding, and installs narrow nftables masquerade from `wg0` to `usb0`.
- If the app-generated or asset-generated client `.conf` should use the
  discovered VZNAT endpoint, use the generated console marker
  `RTPVM_WG_ENDPOINT=<guest-nat-ip>:51820` so the app can parse it or the client
  config placeholder can be replaced.
- `make_vm_assets` includes `iproute2`, `nftables`,
  `wireguard-tools-wg-quick`, `tcpdump`, RNDIS module files, WireGuard module
  files and their dependencies, a `udhcpc` default script, and netfilter/NAT
  module files in the initramfs. It writes the VM-selectable kernel image,
  custom RTPVM initramfs, and generated WireGuard configs under `script/assets`;
  ISO extraction, base initramfs files, and APKs stay under `script/assets/.cache`.
  Do not restore runtime guest `apk add`, and keep
  automatic forwarding scoped to IPv4 `wg0` traffic leaving through fixed RNDIS
  `usb0`.
- Real USB/WireGuard runtime validation requires macOS 27 beta, an approved
  provisioning profile for USB/Virtualization, a real RNDIS USB device, and a
  host WireGuard client.
- Signing/provisioning failures should not block compile builds, UI work, or
  documentation work.
- After code changes, the minimum verification is a
  `CODE_SIGNING_ALLOWED=NO` Xcode build. If app launch verification is needed,
  use `DERIVED_DATA=/tmp/RTPVM-Check ./script/build_and_run.sh --verify`.
