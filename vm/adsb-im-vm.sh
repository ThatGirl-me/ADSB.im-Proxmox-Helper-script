#!/usr/bin/env bash
# ADS-B.im Proxmox Helper Script
# - Downloads the official VM package (.tar.xz), extracts QCOW2, and creates a VM
# - Interactive storage picker (whiptail if available; text fallback)
# - Defaults: SCSI + virtio-scsi-pci, virtio-net, boot from first disk
# - Inspired by community helper scripts: https://community-scripts.github.io/ProxmoxVE/

set -euo pipefail

# ------------------------ Defaults ------------------------
REQUIRED_CMDS=(qm pvesh pvesm qemu-img awk sed grep wget tar)
DEF_NAME="adsb-im"
DEF_CORES="2"
DEF_MEM_MB="1024"
DEF_SIZE="16G"
DEF_BRIDGE="vmbr0"
DEF_BUS="scsi"      # scsi|sata
DEF_FW="1"          # 1=on, 0=off
DEF_AUTOSTART="yes"
DEF_IMAGE_GLOB="adsb-im*.qcow2"
# Official release package (.tar.xz) containing the QCOW2
DEF_URL="https://github.com/dirkhh/adsb-feeder-image/releases/download/v2.2.6/adsb-im-x86-64-vm-v2.2.6-proxmox.tar.xz"

# Env/CLI overrides
IMG="${IMG:-}"                 # path to local .qcow2 (if you already have it)
IMG_URL="${IMG_URL:-$DEF_URL}" # URL to .tar.xz or .qcow2
STORAGE="${STORAGE:-}"         # Proxmox storage ID
VMID="${VMID:-}"               # explicit VMID
VMNAME="${VMNAME:-$DEF_NAME}"
CORES="${CORES:-$DEF_CORES}"
MEM_MB="${MEM_MB:-$DEF_MEM_MB}"
DISK_SIZE="${SIZE:-$DEF_SIZE}"
BRIDGE="${BRIDGE:-$DEF_BRIDGE}"
BUS="${BUS:-$DEF_BUS}"
FIREWALL="${FIREWALL:-$DEF_FW}"
START_AFTER="${START_AFTER:-$DEF_AUTOSTART}"

# ------------------------ Utils ------------------------
fatal(){ echo -e "ERROR: $*" >&2; exit 1; }
warn(){  echo -e "WARN : $*" >&2; }
info(){  echo -e "INFO : $*"; }

need_cmds(){ for c in "${REQUIRED_CMDS[@]}"; do command -v "$c" >/dev/null 2>&1 || fatal "Missing command: $c"; done; }
is_pve8(){ pveversion | grep -Eq '^pve-manager/8\.'; }
have_whiptail(){ command -v whiptail >/dev/null 2>&1; }

active_storages(){ pvesm status | awk 'NR>1 && $2=="active"{print $1}'; }

storage_allows_images(){
  local id="$1"
  awk -v want="$id" '
    /^[a-z]/ && /: / { split($0,a,":"); gsub(/^ +| +$/,"",a[2]); id=a[2] }
    /^[[:space:]]*content/ && $0 ~ /images/ && id==want { print "yes" }
  ' /etc/pve/storage.cfg 2>/dev/null | grep -q yes
}

list_image_storages(){
  while read -r s; do
    [[ -n "$s" ]] || continue
    storage_allows_images "$s" && echo "$s"
  done < <(active_storages)
}

enable_images_content(){
  local id="$1"
  warn "Storage '$id' does not allow 'images'. Attempting to enable it…"
  pvesm set "$id" --content images,rootdir,iso,backup,vztmpl,snippets || fatal "Failed to set content=images on $id"
}

pick_storage_interactive(){
  mapfile -t cands < <(list_image_storages)
  if [[ ${#cands[@]} -eq 0 ]]; then
    warn "No storages marked with 'images'. Falling back to ALL active storages."
    mapfile -t cands < <(active_storages)
    [[ ${#cands[@]} -gt 0 ]] || fatal "No active storages found (see 'pvesm status')."
  fi

  if have_whiptail; then
    local items=() i=1 choice
    for s in "${cands[@]}"; do
      local avail; avail=$(pvesm status | awk -v id="$s" '$1==id{print $6}')
      items+=("$i" "$s (avail: ${avail:-?})")
      i=$((i+1))
    done
    choice=$(whiptail --title "Select Storage" --menu "Choose Proxmox storage for the VM disk" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3) || exit 1
    STORAGE="${cands[$((choice-1))]}"
  else
    echo "Storages:"
    local i=1
    for s in "${cands[@]}"; do echo "  [$i] $s"; i=$((i+1)); done
    read -rp "Enter number [1-${#cands[@]}]: " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=${#cands[@]} )) || fatal "Invalid selection"
    STORAGE="${cands[$((pick-1))]}"
  fi
  info "Using storage: $STORAGE"

  # Ensure chosen storage allows images
  storage_allows_images "$STORAGE" || enable_images_content "$STORAGE"
}

# Download (.tar.xz or .qcow2) into /tmp and return the file path
dl_any(){
  local url="$1"
  local out="${2:-/tmp/adsb-im-download.$RANDOM}"
  info "Downloading: $url"
  wget -q -O "$out" "$url" || fatal "Download failed: $url"
  echo "$out"
}

# If .tar.xz: extract and return first .qcow2 path; if .qcow2: return it as is
expand_to_qcow2(){
  local in="$1"
  if [[ "$in" =~ \.qcow2$ ]]; then
    echo "$in"; return 0
  fi
  if [[ "$in" =~ \.tar\.xz$ ]] || [[ "$in" =~ \.txz$ ]]; then
    local tmpd; tmpd="$(mktemp -d)"
    info "Extracting $(basename "$in") to $tmpd"
    tar -xJf "$in" -C "$tmpd" || fatal "Failed to extract archive"
    local qcow
    qcow="$(find "$tmpd" -maxdepth 2 -type f -name '*.qcow2' | head -n1)"
    [[ -n "$qcow" ]] || fatal "No .qcow2 found inside archive"
    echo "$qcow"
    return 0
  fi
  fatal "Unsupported image format: $in (expected .qcow2 or .tar.xz)"
}

resize_qcow2(){ qemu-img resize -f qcow2 "$1" "$2"; }

gen_mac(){ printf '02:%02x:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }

# ------------------------ CLI ------------------------
show_help(){
cat <<EOF
Usage: $(basename "$0") [options]
  -S|--storage <id>   Proxmox storage ID (must be active)
  -i <qcow2>          Local .qcow2 (skips download)
  -u <url>            URL to .tar.xz or .qcow2 (default: $DEF_URL)
  -v <vmid>           VMID (default: next free)
  -n <name>           VM name (default: $VMNAME)
  -c <cores>          vCPU cores (default: $CORES)
  -m <MB>             Memory in MB (default: $MEM_MB)
  -b <bridge>         Network bridge (default: $BRIDGE)
  --sata              Use SATA (default: SCSI)
  --no-firewall       Disable the Proxmox firewall flag on the VM
  --no-start          Do not auto-start the VM after creation
  -s <size>           Disk size, e.g. 16G (default: $DISK_SIZE)
  -h|--help           Show help
Environment variables also supported: IMG, IMG_URL, STORAGE, VMID, VMNAME, CORES, MEM_MB, SIZE, BRIDGE, BUS, FIREWALL, START_AFTER
EOF
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S|--storage) STORAGE="${2:-}"; shift 2;;
    -i) IMG="${2:-}"; shift 2;;
    -u) IMG_URL="${2:-}"; shift 2;;
    -v) VMID="${2:-}"; shift 2;;
    -n) VMNAME="${2:-}"; shift 2;;
    -c) CORES="${2:-}"; shift 2;;
    -m) MEM_MB="${2:-}"; shift 2;;
    -b) BRIDGE="${2:-}"; shift 2;;
    --sata) BUS="sata"; shift;;
    --no-firewall) FIREWALL="0"; shift;;
    --no-start) START_AFTER="no"; shift;;
    -s) DISK_SIZE="${2:-}"; shift 2;;
    -h|--help) show_help; exit 0;;
    *) ARGS+=("$1"); shift;;
  esac
done
set -- "${ARGS[@]}"

# ------------------------ Preflight ------------------------
[[ $EUID -eq 0 ]] || fatal "Run as root"
need_cmds
is_pve8 || warn "Script tested on Proxmox VE 8.x; continuing…"

# ------------------------ Setup (Simple/Advanced) ------------------------
if have_whiptail; then
  sel=$(whiptail --title "ADS-B.im VM Installer" --radiolist "Choose mode" 12 60 2 \
    "simple"   "Use sensible defaults" ON \
    "advanced" "Customize all settings" OFF 3>&1 1>&2 2>&3) || exit 1
else
  read -rp "Mode: [S]imple/[A]dvanced? " sel
  [[ "${sel,,}" =~ ^a ]] && sel="advanced" || sel="simple"
fi

if [[ "$sel" == "advanced" ]]; then
  if have_whiptail; then
    VMNAME=$(whiptail --inputbox "VM name:" 10 60 "$VMNAME" 3>&1 1>&2 2>&3) || exit 1
    CORES=$(whiptail --inputbox "vCPU cores:" 10 60 "$CORES" 3>&1 1>&2 2>&3) || exit 1
    MEM_MB=$(whiptail --inputbox "Memory (MB):" 10 60 "$MEM_MB" 3>&1 1>&2 2>&3) || exit 1
    DISK_SIZE=$(whiptail --inputbox "Disk size (e.g. 16G):" 10 60 "$DISK_SIZE" 3>&1 1>&2 2>&3) || exit 1
    BRIDGE=$(whiptail --inputbox "Bridge:" 10 60 "$BRIDGE" 3>&1 1>&2 2>&3) || exit 1
    BUS=$(whiptail --radiolist "Disk bus:" 12 60 2 \
      "scsi" "virtio-scsi (recommended)" ON \
      "sata" "SATA" OFF 3>&1 1>&2 2>&3) || exit 1
    START_AFTER=$(whiptail --radiolist "Start VM after creation?" 12 60 2 "yes" "" ON "no" "" OFF 3>&1 1>&2 2>&3) || exit 1
    fw=$(whiptail --radiolist "Enable Proxmox firewall flag?" 12 60 2 "1" "On" ON "0" "Off" OFF 3>&1 1>&2 2>&3) || exit 1
    FIREWALL="$fw"
  else
    read -rp "VM name [$VMNAME]: " t; VMNAME="${t:-$VMNAME}"
    read -rp "vCPU cores [$CORES]: " t; CORES="${t:-$CORES}"
    read -rp "Memory MB [$MEM_MB]: " t; MEM_MB="${t:-$MEM_MB}"
    read -rp "Disk size [$DISK_SIZE]: " t; DISK_SIZE="${t:-$DISK_SIZE}"
    read -rp "Bridge [$BRIDGE]: " t; BRIDGE="${t:-$BRIDGE}"
    read -rp "Disk bus [scsi|sata] [$BUS]: " t; BUS="${t:-$BUS}"
    read -rp "Start after create? [yes/no] [$START_AFTER]: " t; START_AFTER="${t:-$START_AFTER}"
    read -rp "Firewall flag [1/0] [$FIREWALL]: " t; FIREWALL="${t:-$FIREWALL}"
  fi
fi

# ------------------------ Storage ------------------------
if [[ -z "$STORAGE" ]]; then
  pick_storage_interactive
else
  active_storages | grep -Fxq "$STORAGE" || fatal "Storage '$STORAGE' is not active (see 'pvesm status')"
  storage_allows_images "$STORAGE" || enable_images_content "$STORAGE"
fi

# ------------------------ Image Source ------------------------
if [[ -z "${IMG:-}" ]]; then
  # Download the default URL (tar.xz) and expand to qcow2
  PKG="$(dl_any "$IMG_URL" "/tmp/adsb-im.$RANDOM.pkg")"
  IMG="$(expand_to_qcow2 "$PKG")"
fi
[[ -f "$IMG" ]] || fatal "Image not found: $IMG"

# Safe resize (no-op if already >= requested size)
resize_qcow2 "$IMG" "$DISK_SIZE"

# ------------------------ VM create ------------------------
[[ -n "${VMID:-}" ]] || VMID="$(pvesh get /cluster/nextid)"
MAC="$(gen_mac)"

echo "==> Creating VM $VMID ($VMNAME)"
echo "    Storage  : $STORAGE"
echo "    Disk     : $IMG  -> $DISK_SIZE  ($BUS)"
echo "    CPU/Mem  : $CORES cores / $MEM_MB MB"
echo "    Bridge   : $BRIDGE"
echo "    Firewall : $FIREWALL"

BUS_OPTS=(); BOOTDEV=""; DISK_ARG=""
if [[ "$BUS" == "sata" ]]; then
  DISK_ARG="-sata0 ${STORAGE}:0,import-from=${PWD}/${IMG}"
  BOOTDEV="sata0"
else
  BUS_OPTS+=(--scsihw virtio-scsi-pci)
  DISK_ARG="-scsi0 ${STORAGE}:0,import-from=${PWD}/${IMG}"
  BOOTDEV="scsi0"
fi

# Create VM and import disk in one step
qm create "$VMID" \
  -name "$VMNAME" \
  -ostype l26 \
  -cpu host -balloon 0 \
  -cores "$CORES" -memory "$MEM_MB" \
  -net0 "virtio=${MAC},bridge=${BRIDGE},firewall=${FIREWALL}" \
  ${BUS_OPTS[@]+"${BUS_OPTS[@]}"} \
  ${DISK_ARG} \
  -boot "order=${BOOTDEV}"

echo "==> VM $VMID has been created."
if [[ "${START_AFTER,,}" == "yes" ]]; then
  qm start "$VMID" || warn "Failed to start VM $VMID"
  echo "Console: qm console $VMID   (CTRL+] to exit)"
else
  echo "You can start it later with: qm start $VMID"
fi
