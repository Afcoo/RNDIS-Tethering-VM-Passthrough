# RNDIS Tethering VM Passthrough

[한국어](./README.md) | [English](./README.en.md)

A Swift app that lets macOS use the RNDIS protocol used by Android devices for USB tethering.

It uses Virtualization framework USB passthrough to connect the RNDIS device to a Linux VM, and macOS connects to the VM with WireGuard to use the tethering network.

## Requirements

- macOS 27 beta 2 or newer.

## Usage

1. Run `make_vm_assets` to create the `script/assets` folder.

```sh
./make_vm_assets
```

2. Run `RTVMP.app`. 

    If macOS blocks launch, run:

```sh
xattr -dr com.apple.quarantine "/Applications/RTVMP.app"
```

3. In the app, open `VM Setup` -> `Load Folder` and select the generated
   `assets` folder.

4. Connect the USB tethering device to the Mac, then select VM to use the device
   <video src="https://github.com/user-attachments/assets/d285ed13-9bf3-4030-ad34-f04cd9de4e34" width="120" controls></video>

6. Press `Start VM` in the top-right corner, then select the passthrough device
   in `USB Devices` and press `Attach`.

7. Copy or save the host `.conf` from `WireGuard`.

8. Install WireGuard tools.

```sh
brew install wireguard-tools wireguard-go
```

8. Configure WireGuard with the `.conf` file saved in the current directory.

```sh
sudo wg-quick up ./rtvmp.conf
sudo wg show
# On exit
sudo wg-quick down ./rtvmp.conf
```

**The official WireGuard app does not work correctly, so `wireguard-go` is recommended.**

## Architecture

```text
macOS host WireGuard client
-> VZNAT UDP/51820
-> Alpine VM wg0
-> nftables masquerade
-> Alpine VM usb0
-> RNDIS USB tethering device
```

- `eth0`: VM VZNAT network used as the host-to-guest WireGuard endpoint path.
- `wg0`: WireGuard overlay. Defaults are guest `10.100.0.1/24` and host
  `10.100.0.2/24`.
- `usb0`: RNDIS tethering interface inside the VM.

The generated client config is an IPv4 full tunnel:

```text
AllowedIPs = 10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1
```

## VM Assets

`VM_Assets.zip` includes Alpine 3.24.1 based files and WireGuard configs.
Extract it and select the extracted folder in `VM Setup`.

- Kernel: `script/assets/Image-lts`
- Initramfs: `script/assets/initramfs-rtpvm-lts`
- Guest config: `script/assets/wireguard/wg-server.conf`
- Host config: `script/assets/wireguard/wg-client.conf`

WireGuard keys are generated fresh for each asset build. Treat
`wireguard/*.conf` as secrets.

## Build

UI and compile check:

```sh
./script/build_and_run.sh
```

To generate VM assets yourself:

```sh
./script/make_vm_assets
```

Runtime signing check:

```sh
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
./script/build_and_run.sh --runtime
```

Put your local `DEVELOPMENT_TEAM` and bundle identifier in
`Configuration/LocalSigning.xcconfig`.

## Layout

- `LinuxVirtualMachine`: SwiftUI app and VM/USB/WireGuard orchestration.
- `script`: asset generation, build/run, and host WireGuard helper.
- `script/initramfs`: guest BusyBox initramfs source.
- `Configuration`: signing configuration template.
