#!/usr/bin/env bash
# ADS-B.im Proxmox Helper Script (Whiptail GUI)
# - Blue TUI menus via whiptail (community-helper style)
# - Correct storage detection (pvesm status col 3 == active)
# - Ensures chosen storage allows 'images' (type-aware)
# - Downloads official .tar.xz, extracts QCOW2, imports in one step
# - Defaults: SCSI + virtio-scsi-pci, virtio-net, boot from first disk
# - Proxmox VE 8.x compatible

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
DEF_URL="https://github.com/dirkhh/adsb-feeder-image/releases/download/v3.0.3/adsb-im-x86-64-vm-v3.0.3-proxmox.tar.xz"

# Env/CLI overrides (still supported for headless use)
IMG="${IMG:-}"                   # path to local .qcow2 (optional)
IMG_URL="${IMG_URL:-$DEF_URL}"   # URL to .tar.xz or .qcow2
STORAGE="${STORAGE:-}"           # Proxmox storage ID
STORAGE_PATH="${STORAGE_PATH:-}" # path for new dir storage if created
VMID="${VMID:-}"                 # explicit VMID
VMNAME="${VMNAME:-$DEF_NAME}"
CORES="${CORES:-$DEF_CORES}"
MEM_MB="${MEM_MB:-$DEF_MEM_MB}"
DISK_SIZE="${SIZE:-$DEF_SIZE}"
BRIDGE="${BRIDGE:-$DEF_BRIDGE}"
BUS="${BUS:-$DEF_BUS}"
FIREWALL="${FIREWALL:-$DEF_FW}"
START_AFTER="${START_AFTER:-$DEF_AUTOSTART}"

# ------------------------ UI helpers ------------------------
have_whiptail(){ command -v whiptail >/dev/null 2>&1; }
ui_msg(){ whiptail --title "ADS-B.im installer" --msgbox "$1" "${2:-12}" "${3:-74}" 1>&2; }
ui_yesno(){ whiptail --title "ADS-B.im installer" --yesno "$1" "${2:-12}" "${3:-74}" 1>&2; }
ui_input(){ whiptail --title "ADS-B.im installer" --inputbox "$1" "${3:-10}" "${4:-70}" "$2" 3>&1 1>&2 2>&3; }
ui_menu(){  whiptail --title "ADS-B.im installer" --menu "$1" "${2:-20}" "${3:-74}" "${4:-10}" "${@:5}" 3>&1 1>&2 2>&3; }
ui_radio(){ whiptail --title "ADS-B.im installer" --radiolist "$1" "${2:-18}" "${3:-74}" "${4:-8}" "${@:5}" 3>&1 1>&2 2>&3; }
ui_info(){ whiptail --title "ADS-B.im installer" --infobox "$1" "${2:-10}" "${3:-74}" 1>&2; }
ui_error(){ whiptail --title "ADS-B.im installer" --msgbox "ERROR:\n\n$1" "${2:-12}" "${3:-74}" 1>&2; }

fatal(){ ui_error "$1"; exit 1; }

need_cmds(){
  for c in "${REQUIRED_CMDS[@]}"; do
    command -v "$c" >/dev/null 2>&1 || fatal "Missing command: $c"
  done
}

ensure_whiptail(){
  if have_whiptail; then return 0; fi
  echo "whiptail not found. Attempting to install..." >&2
  if command -v apt >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1 || true
    apt install -y whiptail >/dev/null 2>&1 || true
  fi
  have_whiptail || { echo "Please install whiptail: apt install -y whiptail" >&2; exit 1; }
}

# ------------------------ Proxmox storage helpers ------------------------
# pvesm status columns: 1=Name 2=Type 3=Status 4=Total 5=Used 6=Available 7=%
active_storages(){ pvesm status | awk 'NR>1 && $3=="active"{print $1}'; }
active_storage_count(){ pvesm status | awk 'NR>1 && $3=="active"{c++} END{print c+0}'; }
storage_type(){ pvesm status | awk -v id="$1" 'NR>1 && $1==id{print $2; exit}'; }
storage_available(){ pvesm status | awk -v id="$1" 'NR>1 && $1==id{print $6; exit}'; }

# Returns 0 if storage has 'images' in its content set
storage_allows_images() {
  local want="$1"
  awk -v want="$want" '
    /^[a-z]/ && /: / { split($0,a,":"); id=a[2]; gsub(/^ +| +$/,"",id); cur=(id==want) }
    cur && /^[[:space:]]*content[[:space:]]*:/ {
      line=$0; gsub(/^.*content[[:space:]]*:[[:space:]]*/,"",line)
      gsub(/[[:space:]]/,"",line)
      if (line ~ /(^|,)images(,|$)/) { print "yes"; exit }
    }
  ' /etc/pve/storage.cfg 2>/dev/null | grep -q yes
}

ensure_images_content(){
  local id="$1" type; type="$(storage_type "$id")"
  storage_allows_images "$id" && return 0
  case "$type" in
    dir)      pvesm set "$id" --content images,iso,backup,vztmpl,rootdir,snippets ;;
    zfspool|lvmthin|lvm) pvesm set "$id" --content images,rootdir ;;
    *)        pvesm set "$id" --content images,rootdir ;;
  esac
}

create_dir_storage(){
  local id="$1" path="$2"
  mkdir -p "$path"
  pvesm add dir "$id" --path "$path" --content images,iso,backup,vztmpl,rootdir,snippets
}

# ------------------------ Download / extract helpers ------------------------
# Download returns ONLY the file path (with sensible extension)
dl_any(){
  local url="$1" base="/tmp/adsb-im.$RANDOM" out
  case "$url" in
    *.qcow2) out="${base}.qcow2" ;;
    *.tar.xz|*.txz) out="${base}.tar.xz" ;;
    *) out="${base}.pkg" ;;
  esac
  ui_info "Downloading image...\n\n$url"; sleep 1
  if ! wget -q -O "$out" "$url"; then
    fatal "Download failed:\n$url"
  fi
  echo "$out"
}

# Try tar first; if not, treat as qcow2 (validated with qemu-img)
expand_to_qcow2(){
  local in="$1"
  if tar -tJf "$in" >/dev/null 2>&1; then
    local tmpd; tmpd="$(mktemp -d)"
    ui_info "Extracting image archive...\n\n$(basename "$in")\n\nto: $tmpd"; sleep 1
    if ! tar -xJf "$in" -C "$tmpd"; then
      fatal "Failed to extract archive:\n$in"
    fi
    local qcow; qcow="$(find "$tmpd" -maxdepth 4 -type f -name '*.qcow2' | head -n1)"
    [ -n "$qcow" ] || fatal "No .qcow2 found inside archive."
    echo "$qcow"
  elif qemu-img info "$in" >/dev/null 2>&1; then
    echo "$in"
  else
    fatal "Unsupported image format:\n$in\n\nExpect a .tar.xz with qcow2 inside, or a qcow2 file."
  fi
}

resize_qcow2(){ qemu-img resize -f qcow2 "$1" "$2"; }
gen_mac(){ printf '02:%02x:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }

# ------------------------ CLI (still supported) ------------------------
show_help(){
cat <<HLP
Usage: $(basename "$0") [options]
  -S|--storage <id>      Proxmox storage ID (must be active; if missing, will create dir storage)
  --storage-path <path>  Filesystem path if creating a NEW dir storage named above
  -i <qcow2>             Local .qcow2 (skip download)
  -u <url>               URL to .tar.xz or .qcow2 (default: $DEF_URL)
  -v <vmid>              VMID (default: next free)
  -n <name>              VM name (default: $VMNAME)
  -c <cores>             vCPU cores (default: $CORES)
  -m <MB>                Memory in MB (default: $MEM_MB)
  -b <bridge>            Network bridge (default: $BRIDGE)
  --sata                 Use SATA (default: SCSI)
  --no-firewall          Disable Proxmox firewall flag on the VM
  --no-start             Do not auto-start the VM
  -s <size>              Disk size, e.g. 16G (default: $DISK_SIZE)
  -h|--help              Show help
HLP
}

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -S|--storage) STORAGE="${2:-}"; shift 2;;
    --storage-path) STORAGE_PATH="${2:-}"; shift 2;;
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
[ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }
ensure_whiptail
need_cmds

# ------------------------ Mode ------------------------
MODE=$(ui_radio "Choose mode" 12 70 2 \
  "simple"   "Use sensible defaults" ON \
  "advanced" "Customize all settings" OFF) || exit 1

# ------------------------ Storage (GUI) ------------------------
if [ "$(active_storage_count)" -eq 0 ]; then
  ui_msg "No active storages detected.\n\nI'll create a default directory storage 'local' at /var/lib/vz."
  STORAGE="local"
  create_dir_storage "local" "/var/lib/vz" || fatal "Failed to add dir storage 'local'."
else
  if [ -z "${STORAGE:-}" ]; then
    # Build menu items: <key> <label>
    MENU_ITEMS=()
    while read -r name; do
      avail="$(storage_available "$name")"; typ="$(storage_type "$name")"
      MENU_ITEMS+=("$name" "type: $typ   avail: $avail")
    done < <(active_storages)
    STORAGE=$(ui_menu "Select Proxmox storage for the VM disk" 20 74 10 "${MENU_ITEMS[@]}") || exit 1
  fi
  # If named storage not active, create dir storage path
  if ! active_storages | grep -Fxq "$STORAGE"; then
    local_path="${STORAGE_PATH:-/var/lib/vz/$STORAGE}"
    ui_msg "Storage '$STORAGE' is not active.\n\nI will create a directory storage at:\n$local_path"
    create_dir_storage "$STORAGE" "$local_path" || fatal "Failed to add dir storage '$STORAGE'."
  fi
fi

ensure_images_content "$STORAGE"

# ------------------------ Advanced settings (GUI) ------------------------
if [ "$MODE" = "advanced" ]; then
  VMNAME=$(ui_input "VM name:" "$VMNAME") || exit 1
  CORES=$(ui_input "vCPU cores:" "$CORES") || exit 1
  MEM_MB=$(ui_input "Memory (MB):" "$MEM_MB") || exit 1
  DISK_SIZE=$(ui_input "Disk size (e.g., 16G):" "$DISK_SIZE") || exit 1
  BRIDGE=$(ui_input "Network bridge:" "$BRIDGE") || exit 1
  BUS=$(ui_radio "Disk bus" 14 70 2 \
        "scsi" "virtio-scsi (recommended)" ON \
        "sata" "SATA" OFF) || exit 1
  fwsel=$(ui_radio "Enable Proxmox firewall flag on the VM?" 14 70 2 \
        "1" "On" ON \
        "0" "Off" OFF) || exit 1
  FIREWALL="$fwsel"
  startsel=$(ui_radio "Start VM after creation?" 14 70 2 \
        "yes" "" ON \
        "no"  "" OFF) || exit 1
  START_AFTER="$startsel"
fi

# ------------------------ Download / Image prepare (GUI) ------------------------
if [ -z "${IMG:-}" ]; then
  PKG="$(dl_any "$IMG_URL")"          # prints path only
  IMG="$(expand_to_qcow2 "$PKG")"     # prints path only
fi
[ -f "$IMG" ] || fatal "Image not found:\n$IMG"

ui_info "Resizing image to $DISK_SIZE ..."; sleep 1
resize_qcow2 "$IMG" "$DISK_SIZE"

# ------------------------ VM Create ------------------------
[ -n "${VMID:-}" ] || VMID="$(pvesh get /cluster/nextid)"
MAC="$(gen_mac)"

SUMMARY="Create VM with these settings?

VMID      : $VMID
Name      : $VMNAME
Storage   : $STORAGE
Disk      : $(basename "$IMG") -> $DISK_SIZE ($BUS)
CPU/Mem   : $CORES cores / $MEM_MB MB
Bridge    : $BRIDGE
Firewall  : $FIREWALL
Autostart : $START_AFTER"

ui_yesno "$SUMMARY" 18 70 || exit 0

BOOTDEV=""; DISK_ARG=""; SCSI_OPT=""
if [ "$BUS" = "sata" ]; then
  DISK_ARG="-sata0 ${STORAGE}:0,import-from=${IMG}"
  BOOTDEV="sata0"
else
  SCSI_OPT="--scsihw virtio-scsi-pci"
  DISK_ARG="-scsi0 ${STORAGE}:0,import-from=${IMG}"
  BOOTDEV="scsi0"
fi

ui_info "Creating VM $VMID ($VMNAME)..."; sleep 1
qm create "$VMID" \
  -name "$VMNAME" -ostype l26 \
  -cpu host -balloon 0 \
  -cores "$CORES" -memory "$MEM_MB" \
  -net0 "virtio=${MAC},bridge=${BRIDGE},firewall=${FIREWALL}" \
  $SCSI_OPT \
  $DISK_ARG \
  -boot "order=${BOOTDEV}"

# ------------------------ Start or not ------------------------
if [[ "${START_AFTER,,}" == "yes" ]]; then
  if qm start "$VMID"; then
    ui_msg "VM $VMID created and started.\n\nOpen console:\nqm console $VMID"
  else
    ui_msg "VM $VMID created, but failed to start.\n\nStart manually:\nqm start $VMID"
  fi
else
  ui_msg "VM $VMID created.\n\nStart later with:\nqm start $VMID"
fi
