# mt7902-fix

WiFi/Bluetooth fix for the MediaTek MT7902 (Filogic 310) on Linux.

## Problem

`lspci` shows the device, no driver binds to it:

```
0000:02:00.0 Network controller: MEDIATEK Corp. MT7902 802.11ax PCIe Wireless Network Adapter [Filogic 310]
```

Native support (`mt7921e` with PCI ID `14c3:7902`) landed upstream in kernel 7.1. Distributions on older kernels have no driver for this chip out of the box.

## What it does

- Detects whether the running kernel already supports the device natively
- If not, builds and installs an out-of-tree driver via DKMS
- Checks Secure Boot state (unsigned DKMS modules are rejected when enabled)
- Clears rfkill blocks, fixes NetworkManager unmanaged state
- Reloads the module and runs a raw `iw scan` to confirm the radio works
- Reports kernel version, driver status, interface name, and networks visible

## Requirements

- Debian/Ubuntu-based distribution (Kali, Ubuntu, Debian, Mint)
- Root access
- Internet connectivity through another interface (Ethernet, USB tethering) during install

## Usage

```
sudo ./mt7902-fix.sh
```

Install WiFi only:

```
sudo ./mt7902-fix.sh --wifi-only
```

Install Bluetooth only:

```
sudo ./mt7902-fix.sh --bt-only
```

Skip install, run diagnostics on an already-installed driver:

```
sudo ./mt7902-fix.sh --diag
```

Test a specific interface name:

```
sudo ./mt7902-fix.sh --diag --iface=wlp2s0
```

## After running

```
nmcli device wifi connect "SSID" --ask
```

If the interface doesn't appear after a fresh install, reboot once and re-run with `--diag`.

## Secure Boot

If enabled, either disable it in UEFI or sign the module:

```
dkms mkcert -m mt7902_driver -v 1.0
mokutil --import /var/lib/dkms/mt7902_driver/1.0/build/certs/*.der
```

Reboot and enroll the key in the MOK Manager prompt.

## Credits

Driver build handled by [abdullaabdullazade/mt7902_driver](https://github.com/abdullaabdullazade/mt7902_driver). This script automates detection, install, and post-install network fixes around it.

## License

MIT
