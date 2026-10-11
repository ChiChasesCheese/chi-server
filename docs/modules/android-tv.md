# Android TV: manage a TV box over adb

`chi tv` manages an Android TV / Google TV box (or any Android-based TV or projector) from the Mac over the
network with adb: sideload apps, set the system proxy, keep a VPN app always on, without clicking through menus
with a remote.

It installs `android-platform-tools` (adb) with Homebrew on first use.

## Prepare the box

1. Settings -> System -> About -> press **Android TV OS build** (or Build number) seven times to enable
   Developer options.
2. Developer options -> enable **USB debugging** (some models call it Network debugging or Wireless debugging).
3. Find the box's IP: Settings -> Network -> current network. Reserve it in your router.

Run `chi tv` without arguments to print these steps.

## Commands

A bare IP gets port `:5555` appended; pass `ip:port` to override.

| Command | Action |
|---|---|
| `chi tv connect <ip>` | Connect. The first time, choose **Always allow** on the TV. |
| `chi tv install <file.apk>` | Sideload an APK. |
| `chi tv proxy <ip> on` | Set the box's global HTTP proxy to `<mac-lan-ip>:CLASH_PORT` (the [split-routing proxy](split-routing.md)). |
| `chi tv proxy <ip> off` | Clear the proxy. |
| `chi tv vpn <ip> <package>` | Make a VPN app always-on so it reconnects after reboots (lockdown off). |
| `chi tv vpn <ip> off` | Clear the always-on VPN. |
| `chi tv apps` | List third-party packages (to find package names). |
| `chi tv shell` | Open an adb shell. |

`apps`, `shell` and `install` use the currently connected device; run `chi tv connect <ip>` first.

```bash
chi tv connect 192.168.1.50
chi tv apps
chi tv install ~/Downloads/app.apk
chi tv proxy 192.168.1.50 on
chi tv vpn 192.168.1.50 com.example.vpn
```

## How install works

Large installs over Wi-Fi often drop the adb connection, so `chi tv install` pushes the APK to
`/data/local/tmp/` and runs `pm install` in the background on the box, then polls the result for up to 90
seconds. It passes `--bypass-low-target-sdk-block` because Android 14 refuses apps that target old Android
versions (common for TV clients distributed as APKs).

If Google Play Protect blocks the app, the TV shows a prompt: choose **More details -> Install anyway**.

Sideloaded apps do not update automatically. Download the new APK and run `chi tv install` again from time to
time.

## Proxy vs VPN app

| | `chi tv proxy` | `chi tv vpn` |
|---|---|---|
| Traffic path | Through mihomo on the Mac | Through the VPN app on the box |
| Configuration | Subscription and rules live on the Mac | Configured in the app |
| Apps that ignore the system proxy | Not covered | Covered (VPN interface) |
| When the Mac is down | The box loses internet; turn the proxy off | Unaffected |

With `vpn`, lockdown is deliberately off: if the VPN app fails, the box still has direct internet, and only
region-locked content stops working. The command also whitelists the app from battery optimisation (device
idle) so it is not killed.

## Troubleshoot

| Symptom | Check |
|---|---|
| `failed to authenticate` / connection keeps resetting | Accept the prompt on the TV. `chi tv` sets `ADB_MDNS=0` because adb's mDNS discovery can crash the adb server on recent macOS; if you run adb yourself, set it too. |
| `install` times out after 90 s | A Play Protect prompt is waiting on the TV. |
| `install` fails with a target SDK error | The app is too old even with the bypass flag; find a newer build. |
| The box lost internet | The proxy points at the Mac and mihomo is down: `chi tv proxy <ip> off`. |
| An app ignores the proxy | Use an on-device VPN or Clash client with `chi tv vpn`. |

Find the Play Store vs regional versions of apps carefully: an international app with the same brand may have a
completely different catalogue from the regional TV client you want.
