# RTVMP: RNDIS Tethering VM Passthrough

[한국어](./README.md) | [English](./README.en.md)

안드로이드 장치에서 USB테더링에 사용되는 RNDIS 프로토콜을 macOS에서도 사용할 수 있게 해주는 Swift 앱입니다.

Virtualization 프레임워크의 USB passthrough 기능을 사용해 Linux VM에 RNDIS 장치를 연결하고, macOS는 WireGuard로 VM에 연결해 테더링 네트워크를 사용할 수 있습니다.


## 요구 사항

- macOS 27 beta 2 이상.

## 사용법

1. 압축 해제한 `script` 폴더에서 `make_vm_assets`를 실행해 vm asset을 생성합니다.

```sh
./make_vm_assets
```

2. `RTVMP.app`을 실행합니다.

    macOS가 경고로 실행을 막으면 다음 명령을 실행하세요.

```sh
sudo xattr -dr com.apple.quarantine "/Applications/RTVMP.app"
```

3. 앱에서 `VM Setup` -> `Load Folder`를 눌러 생성된 `assets` 폴더를 선택합니다.

4. USB 테더링 장치를 Mac에 연결하고, 메뉴바에서 VM이 장치를 사용하도록 선택합니다.

   <video src="https://github.com/user-attachments/assets/d285ed13-9bf3-4030-ad34-f04cd9de4e34" width="120" controls></video>


6. 우측 상단의 `Start VM`을 누른 뒤 `USB Devices`에서 passthrough된 장치를 선택하고 `Attach`를 누릅니다.
   
   <video src="https://github.com/user-attachments/assets/4d10e732-7510-4555-84c5-1f16ef412a00" width="120" controls></video>

8. `WireGuard` 화면에서 host `.conf`를 복사하거나 저장합니다.

9. WireGuard 도구를 설치합니다.

```sh
brew install wireguard-tools wireguard-go
```

8. 현재 디렉터리에 저장한 `.conf` 파일로 WireGuard를 설정합니다.

```sh
sudo wg-quick up ./rtvmp.conf
sudo wg show
# 종료 시
sudo wg-quick down ./rtvmp.conf
```
*공식 WireGuard 앱에서는 작동하지 않으므로 `wireguard-go`를 사용하는 것을 권장합니다.*

## 구조

```text
macOS host WireGuard client
-> VZNAT UDP/51820
-> Alpine VM wg0
-> nftables masquerade
-> Alpine VM usb0
-> RNDIS USB tethering device
```

- `eth0`: VM의 VZNAT network. host가 WireGuard endpoint로 접속하는 통로입니다.
- `wg0`: WireGuard overlay. 기본 주소는 guest `10.100.0.1/24`, host `10.100.0.2/24`입니다.
- `usb0`: VM 안의 RNDIS tethering interface입니다.

생성된 client config는 IPv4 full tunnel용입니다.

```text
AllowedIPs = 10.100.0.0/24, 0.0.0.0/1, 128.0.0.0/1
```

## VM Assets

`VM_Assets.zip`에는 Alpine 3.24.1 기반 파일과 WireGuard config가 포함됩니다.
압축 해제한 폴더를 앱의 `VM Setup`에서 선택합니다.

- Kernel: `script/assets/Image-lts`
- Initramfs: `script/assets/initramfs-rtpvm-lts`
- Guest config: `script/assets/wireguard/wg-server.conf`
- Host config: `script/assets/wireguard/wg-client.conf`

WireGuard key는 asset 생성 시 새로 만들어집니다. `wireguard/*.conf`는 secret으로 취급하세요.

## 빌드 방법

일반 UI/컴파일 확인:

```sh
./script/build_and_run.sh
```

VM assets를 직접 생성하려면:

```sh
./script/make_vm_assets
```

runtime signing 확인:

```sh
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
./script/build_and_run.sh --runtime
```

`Configuration/LocalSigning.xcconfig`에 로컬 `DEVELOPMENT_TEAM`과 bundle identifier를 넣습니다.

## 디렉터리

- `RTPVM`: SwiftUI app, VM/USB/WireGuard orchestration.
- `script`: asset 생성, build/run, host WireGuard helper.
- `script/initramfs`: guest BusyBox initramfs source.
- `Configuration`: signing 설정 template.
