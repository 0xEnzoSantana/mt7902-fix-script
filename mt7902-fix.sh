#!/usr/bin/env bash
set -uo pipefail

RED='\033[38;5;196m'
GREEN='\033[38;5;120m'
YELLOW='\033[38;5;221m'
WHITE='\033[38;5;255m'
GREY='\033[38;5;244m'
BOLD='\033[1m'
RESET='\033[0m'

PCI_ID="14c3:7902"
WORKDIR="/opt/mt7902-fix"
REPO_URL="https://github.com/abdullaabdullazade/mt7902_driver"
INSTALL_MODE="--all"
DIAG_ONLY=0
IFACE=""

ok()   { echo -e "   ${GREEN}[+]${RESET} $1"; }
warn() { echo -e "   ${YELLOW}[!]${RESET} $1"; }
err()  { echo -e "   ${RED}[x]${RESET} $1"; }
info() { echo -e "   ${GREY}[i]${RESET} $1"; }
step() { echo -e "   ${WHITE}[*]${RESET} $1"; }
section() {
    echo
    echo -e "${RED}============================================================${RESET}"
    echo -e "${RED}${BOLD} $1${RESET}"
    echo -e "${RED}============================================================${RESET}"
}

usage() {
    cat <<EOF
Usage: sudo ./mt7902-fix.sh [options]

  --wifi-only     Install WiFi driver only
  --bt-only       Install Bluetooth driver only
  --diag          Skip install, run diagnostics only
  --iface NAME    Interface to test (default: auto-detect wl*)
  -h, --help      Show this help
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --wifi-only) INSTALL_MODE="--wifi" ;;
        --bt-only)   INSTALL_MODE="--bt" ;;
        --diag)      DIAG_ONLY=1 ;;
        --iface)     shift ;;
        --iface=*)   IFACE="${arg#*=}" ;;
        -h|--help)   usage ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    err "run as root: sudo ./mt7902-fix.sh"
    exit 1
fi

echo -e "${RED}${BOLD}"
cat <<'EOF'
============================================================
   MT7902 FIX  ::  MediaTek Filogic 310 WiFi 6E / Bluetooth
============================================================
EOF
echo -e "${RESET}"

KERNEL_REL="$(uname -r)"

section "Diagnostic"

if ! lspci -nn | grep -qi "$PCI_ID"; then
    err "no PCI device ${PCI_ID} found via lspci"
    exit 1
fi
ok "PCI device ${PCI_ID} detected"
step "kernel: ${KERNEL_REL}"

CURRENT_DRIVER="$(lspci -k -d "$PCI_ID" | grep -i 'Kernel driver in use' | awk -F': ' '{print $2}')"
[[ -n "${CURRENT_DRIVER:-}" ]] && info "bound driver: ${CURRENT_DRIVER}" || warn "no driver bound (UNCLAIMED)"

IN_TREE_OK=0
modinfo mt7921e 2>/dev/null | grep -q "7902" && IN_TREE_OK=1

if [[ "$IN_TREE_OK" -eq 1 ]]; then
    ok "mt7921e on this kernel already supports MT7902 natively"
else
    warn "mt7921e does not include ID 7902 (native support requires kernel 7.1+)"
fi

if [[ "$DIAG_ONLY" -eq 0 && "$IN_TREE_OK" -eq 0 ]]; then
    if ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        err "no internet connectivity, required to fetch build deps and driver"
        exit 1
    fi

    section "Build dependencies"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        build-essential dkms git wget zstd \
        "linux-headers-${KERNEL_REL}" firmware-misc-nonfree 2>&1 | tail -15

    if [[ ! -d "/lib/modules/${KERNEL_REL}/build" ]]; then
        err "linux-headers-${KERNEL_REL} not present, cannot build DKMS module"
        exit 1
    fi
    ok "headers present for ${KERNEL_REL}"

    section "Driver build (DKMS)"
    mkdir -p "$WORKDIR"
    if [[ -d "$WORKDIR/mt7902_driver/.git" ]]; then
        git -C "$WORKDIR/mt7902_driver" pull --ff-only
    else
        git clone --depth 1 "$REPO_URL" "$WORKDIR/mt7902_driver"
    fi

    cd "$WORKDIR/mt7902_driver"
    chmod +x install.sh
    ./install.sh $INSTALL_MODE
    BUILD_EXIT=$?
    cd - >/dev/null

    if [[ $BUILD_EXIT -ne 0 ]]; then
        err "install.sh failed (exit ${BUILD_EXIT})"
        err "alternatives: github.com/hmtheboy154/gen4-mt7902, github.com/alphingj/mt7902-linux-wifi"
        exit 1
    fi
    ok "DKMS build complete"

    section "Secure Boot"
    SB_STATE="unknown"
    if command -v mokutil >/dev/null 2>&1; then
        mokutil --sb-state 2>/dev/null | grep -qi enabled && SB_STATE="enabled" || SB_STATE="disabled"
    fi
    if [[ "$SB_STATE" == "enabled" ]]; then
        warn "Secure Boot is ON, unsigned DKMS modules will be rejected at load"
        info "disable Secure Boot in UEFI, or sign the module:"
        info "  dkms mkcert -m mt7902_driver -v 1.0"
        info "  mokutil --import /var/lib/dkms/mt7902_driver/1.0/build/certs/*.der"
    else
        ok "Secure Boot: ${SB_STATE}"
    fi
fi

section "rfkill / NetworkManager"

if command -v rfkill >/dev/null 2>&1; then
    if rfkill list | grep -A2 -i wireless | grep -qi "hard blocked: yes"; then
        err "hardware rfkill block active, check airplane-mode key/switch"
    elif rfkill list | grep -A2 -i wireless | grep -qi "soft blocked: yes"; then
        rfkill unblock all
        ok "soft rfkill block cleared"
    else
        ok "no rfkill block"
    fi
fi

if command -v nmcli >/dev/null 2>&1; then
    [[ "$(nmcli radio wifi)" == "disabled" ]] && nmcli radio wifi on
    systemctl restart NetworkManager 2>/dev/null
fi

section "Reload and verify"

modprobe -r mt7921e >/dev/null 2>&1
sleep 1
modprobe mt7921e
sleep 2

[[ -z "$IFACE" ]] && IFACE="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wl' | head -1)"

if [[ -z "$IFACE" ]]; then
    err "no wl* interface appeared after reload"
    err "check: dmesg | tail -40"
    err "if a stale DKMS module was loaded before this run, REBOOT and re-run"
    exit 1
fi

ok "interface: ${IFACE}"

if command -v nmcli >/dev/null 2>&1; then
    DEV_STATE="$(nmcli -t -f DEVICE,STATE device status | grep "^${IFACE}:" | cut -d: -f2)"
    if [[ "$DEV_STATE" == "unmanaged" ]]; then
        err "interface is unmanaged in NetworkManager"
        if grep -rq "unmanaged-devices" /etc/NetworkManager/ 2>/dev/null; then
            grep -rn "unmanaged-devices" /etc/NetworkManager/ 2>/dev/null
        fi
        info "check /etc/NetworkManager/NetworkManager.conf and /etc/udev/rules.d/ for unmanaged rules"
    else
        ok "NetworkManager state: ${DEV_STATE:-unknown}"
    fi
fi

ip link set "$IFACE" up 2>&1
SCAN_OUT="$(iw dev "$IFACE" scan 2>&1)"
if [[ $? -eq 0 ]]; then
    SSID_COUNT="$(echo "$SCAN_OUT" | grep -c "^BSS ")"
    ok "scan ok, ${SSID_COUNT} networks visible"
else
    err "scan failed:"
    echo "$SCAN_OUT" | tail -5
fi

FW_ERR="$(dmesg | grep -iE "mt7921" | grep -iE "fail|error|timeout" | tail -5)"
[[ -n "$FW_ERR" ]] && { err "driver/firmware errors in dmesg:"; echo "$FW_ERR"; } || ok "no driver errors in dmesg"

section "Summary"
echo -e "   ${WHITE}kernel${RESET}           ${BOLD}${KERNEL_REL}${RESET}"
echo -e "   ${WHITE}in-tree support${RESET}  ${BOLD}$([[ $IN_TREE_OK -eq 1 ]] && echo yes || echo no)${RESET}"
echo -e "   ${WHITE}interface${RESET}        ${BOLD}${IFACE}${RESET}"
echo -e "   ${WHITE}networks seen${RESET}    ${BOLD}${SSID_COUNT:-0}${RESET}"
echo
if [[ "${SSID_COUNT:-0}" -gt 0 ]]; then
    ok "radio working, connect with:"
    echo -e "      ${WHITE}nmcli device wifi connect \"SSID\" --ask${RESET}"
else
    warn "no networks seen, reboot if this was a fresh DKMS install"
fi
echo -e "${RED}============================================================${RESET}"
