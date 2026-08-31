#!/bin/bash
# tui-lab — a small, reproducible multi-distro lab for the tui-tools family.
#
# It boots stock cloud images headless under QEMU/KVM (Ubuntu, Fedora, Omarchy
# Server), seeds them with cloud-init NoCloud so each one comes up with the
# package manager and the firewall/snapshot backend the tools actually talk to,
# and then builds a tool from its sibling checkout, copies it in and runs its
# smoke test against the real backend.
#
# Usage:
#   lab.sh up <ubuntu|fedora|omarchy> [--mem MB] [--cpus N] [--disk GB] [--selinux]
#   lab.sh down <vm> | status [vm] | ssh <vm> [cmd...] | wait-ssh <vm> [secs]
#   lab.sh snapshot <vm> <tag> | restore <vm> <tag>
#   lab.sh all up | all down | all status
#   lab.sh router [--backend qemu|libvirt] up|down|status|test [--via-tool [PATH]|--traffic]
#   lab.sh test <tool> [vm...] [--bin PATH] [--keep]
#   lab.sh report <tool|all> [vm...] [--bin PATH]
#   lab.sh fetch <vm> | images
#
# Everything it writes lives under out/ (gitignored): the image cache, the
# per-VM disks, the lab ssh key and the test logs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${LAB_OUT:-$here/out}"
images="$out/images"

# The QEMU monitor and the ssh ControlMaster sockets are unix sockets, and a
# socket path is capped at ~108 bytes. A checkout path plus out/vm/<name>/
# already overflows that, so both live in the runtime dir keyed by a hash of
# the VM's own path.
control_dir="${XDG_RUNTIME_DIR:-/tmp}/tui-lab"
ovmf_dir="${OVMF_DIR:-/usr/share/edk2/ovmf}"

# The lab user is the same everywhere: the smoke tests are written against one
# name and escalate with `sudo -n`.
lab_user=lab

# ---------------------------------------------------------------------------
# Backend selection
# ---------------------------------------------------------------------------
# The lab has two ways to run a guest. `qemu` (the default) boots it locally
# with QEMU/KVM and reaches it over a user-mode ssh hostfwd on the loopback —
# no root, no bridges, portable, and capped at two endpoints per socket
# segment. `libvirt` hands the whole thing to a real hypervisor over
# qemu+ssh: KVM domains on the avell notebook, on real virtual networks with
# multiple NICs per guest. The default stays local so day-to-day iteration
# needs nothing but this host.
#
# Selected by `LAB_BACKEND=libvirt` or `--backend libvirt` on the router
# command. Everything below keyed on it lives behind these names so the
# router flow reads the same on either backend.
lab_backend="${LAB_BACKEND:-qemu}"

# The libvirt connection and the ssh jump host that reaches the guests. The
# guests sit on a NAT management network on the hypervisor, unreachable from
# here directly, so every ssh to one is proxied through the hypervisor.
libvirt_uri="${LAB_LIBVIRT_URI:-qemu:///system}"
libvirt_jump="${LAB_LIBVIRT_JUMP:-}"

# The image pool. It MUST live under /home on the avell: / there has ~31G,
# /home has ~125G, and a base image plus overlays does not fit in the former.
libvirt_pool="${LAB_LIBVIRT_POOL:-tuilab}"
libvirt_pool_path="${LAB_LIBVIRT_POOL_PATH:-$HOME/tuilab/images}"

# Every libvirt object this backend creates is namespaced `tuilab-` so it can
# never be confused with the operator's own `zc-lab-*` domains on the same
# hypervisor. The management subnet is picked clear of the host's existing
# `default` (192.168.122.0/24) and `zc-lab` (10.190.0.0/24) networks.
libvirt_mgmt_net="tuilab-mgmt"
libvirt_wan_net="tuilab-wan"
libvirt_lan_net="tuilab-lan"
libvirt_mgmt_subnet="192.168.199"
libvirt_base_vol="tuilab-base-noble.qcow2"

# lv runs one virsh command against the hypervisor. `define`, `net-define`
# and `pool-define` read their XML from a path on THIS host and transmit it,
# so the callers hand it a local temp file.
lv() { virsh -c "$libvirt_uri" "$@"; }

# avell_ssh / avell_scp stage files in the pool on the hypervisor: the base
# image, the per-guest overlays and the cloud-init seed ISOs. The pool
# directory is owned by the login user; libvirt (root) re-owns a disk image
# to the qemu user at domain start and restores it after, so the files can be
# created here without privilege. Never wrapped in `timeout` — the lab rule.
avell_ssh() { ssh "$libvirt_jump" "$@"; }
avell_scp() { scp -q "$1" "$libvirt_jump:$2"; }

# ---------------------------------------------------------------------------
# Image catalogue
# ---------------------------------------------------------------------------
# One entry per distro: the URL to fetch, the file it lands on in the cache and
# the URL of the upstream checksum document. Ubuntu's "current" symlink moves
# with every daily respin, so its digest is verified against the SHA256SUMS
# published beside it rather than pinned here; Fedora and Omarchy are pinned
# releases and their digests are recorded in the README.

fedora_release="44-1.7"
omarchy_release="image-2026-08-29"
omarchy_date="2026-08-29"

image_url() {
  case "$1" in
    ubuntu) echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" ;;
    fedora) echo "https://dl.fedoraproject.org/pub/fedora/linux/releases/${fedora_release%%-*}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${fedora_release}.x86_64.qcow2" ;;
    omarchy) echo "https://github.com/edimarlnx/omarchy-server/releases/download/${omarchy_release}/omarchy-server-${omarchy_date}${omarchy_variant}-x86_64.qcow2" ;;
    *) die "unknown distro: $1" ;;
  esac
}

image_file() { echo "$images/$(basename "$(image_url "$1")")"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "lab: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# The loop variable is local because bash scopes dynamically: without it, a
# `need go` inside a function that has its own `local tool` would overwrite the
# caller's value and the failure would surface far from here.
need() {
  local required
  for required in "$@"; do
    command -v "$required" >/dev/null || die "missing tool: $required"
  done
}

# vm_port derives a stable ssh port from the VM name so several VMs coexist
# without a registry to keep in sync.
vm_port() { echo $(( 2300 + ( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 60 ) )); }

vm_dir() { echo "$out/vm/$1"; }

vm_running() {
  if [[ $lab_backend == libvirt ]]; then
    [[ "$(lv domstate "tuilab-$1" 2>/dev/null)" == running ]]
    return
  fi
  local pidfile; pidfile="$(vm_dir "$1")/pid"
  [[ -f $pidfile ]] && kill -0 "$(<"$pidfile")" 2>/dev/null
}

# lab_key generates the lab-only keypair on first use. It is gitignored and
# never leaves out/: it authenticates nothing but these throwaway VMs.
#
# The generation is serialised behind a mkdir lock because `lab.sh all up`, and
# any two `up` runs started together, both reach this on a cold out/ — and
# ssh-keygen's second copy stops to ask whether to overwrite the first.
lab_key() {
  local key="$out/lab_ed25519" lock="$out/.keylock" i
  if [[ ! -f $key ]]; then
    mkdir -p "$out"
    for ((i = 0; i < 60; i++)); do
      if mkdir "$lock" 2>/dev/null; then
        # Re-check inside the lock: the holder may have created it already.
        [[ -f $key ]] || ssh-keygen -q -t ed25519 -N "" -C "tui-lab" -f "$key"
        rmdir "$lock"
        break
      fi
      sleep 1
    done
    [[ -f $key ]] || die "could not create the lab ssh key (stale lock: $lock)"
  fi
  echo "$key"
}

# ssh_opts builds the argv every ssh call shares. ControlMaster is not an
# optimisation here: the Omarchy profile ships `ufw limit 22/tcp`, which drops
# the seventh connection from one source inside thirty seconds, so a test that
# opens a connection per command rate-limits itself out. Multiplexing turns the
# burst into sessions over a single TCP connection.
# vm_host is where ssh connects for a guest: the loopback with a per-VM
# hostfwd port on the qemu backend, or the guest's fixed management address on
# the libvirt backend, reached through the hypervisor by ProxyJump.
vm_host() {
  if [[ $lab_backend == libvirt ]]; then libvirt_mgmt_ip "$1"; else echo localhost; fi
}

ssh_opts() {
  local name="$1"
  mkdir -p "$control_dir"
  if [[ $lab_backend == libvirt ]]; then
    # Port 22 on the guest's own address, reached through the hypervisor. The
    # guest is on a NAT network this host cannot route to, so every session is
    # proxied through the avell, which this host can already ssh to.
    printf '%s\n' \
      -p 22 \
      -o ProxyJump="$libvirt_jump" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ControlMaster=auto \
      -o ControlPath="$control_dir/%C" \
      -o ControlPersist=120 \
      -i "$(lab_key)" \
      -o IdentitiesOnly=yes
    return
  fi
  local port; port="$(vm_port "$name")"
  printf '%s\n' \
    -p "$port" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ControlMaster=auto \
    -o ControlPath="$control_dir/%C" \
    -o ControlPersist=120 \
    -i "$(lab_key)" \
    -o IdentitiesOnly=yes
}

vm_ssh() {
  local name="$1"; shift
  local opts; mapfile -t opts < <(ssh_opts "$name")
  ssh "${opts[@]}" "$lab_user@$(vm_host "$name")" "$@"
}

vm_scp() {
  local name="$1" src="$2" dst="$3"
  local opts; mapfile -t opts < <(ssh_opts "$name")
  # scp takes -P for the port where ssh takes -p, so the shared list is
  # rewritten rather than reused verbatim.
  opts[0]=-P
  scp "${opts[@]}" "$src" "$lab_user@$(vm_host "$name"):$dst"
}

# vm_wait_ssh polls until the guest answers. It never wraps ssh in `timeout`:
# killing ssh mid-handshake wedges the QEMU user-mode hostfwd listener for the
# rest of the VM's life. ConnectTimeout bounds each attempt instead.
#
# The poll interval is 10s, not 5s, for the same `ufw limit` reason as above: a
# 5s poll sits exactly on the rate limiter's threshold and would lock itself out
# just as the machine became reachable.
vm_wait_ssh() {
  local name="$1" limit="${2:-600}" i
  local opts; mapfile -t opts < <(ssh_opts "$name")
  for ((i = 0; i < limit; i += 10)); do
    if ssh "${opts[@]}" -o ConnectTimeout=5 -o BatchMode=yes \
      "$lab_user@$(vm_host "$name")" true 2>/dev/null; then
      echo "ssh up after ${i}s"
      return 0
    fi
    sleep 10
  done
  echo "ssh not reachable after ${limit}s" >&2
  return 1
}

monitor() {
  local name="$1" cmd="$2"
  printf '%s\n' "$cmd" | socat - "UNIX-CONNECT:$(vm_mon "$name")" | tail -n +2 | sed 's/\r//'
}

vm_mon() {
  mkdir -p "$control_dir"
  echo "$control_dir/$(printf '%s' "$(vm_dir "$1")" | cksum | cut -d' ' -f1).mon"
}

# ---------------------------------------------------------------------------
# fetch: download and verify a cloud image into the cache
# ---------------------------------------------------------------------------
cmd_fetch() {
  local distro="$1"
  need curl
  mkdir -p "$images"
  local url file
  url="$(image_url "$distro")"
  file="$(image_file "$distro")"
  if [[ ! -f $file ]]; then
    log "downloading $(basename "$file")"
    curl -fL --progress-bar -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  verify_image "$distro" "$file"
  echo "$file"
}

# verify_image checks the cached image against the digest the distro publishes
# beside it. A corrupt or truncated download otherwise shows up much later as
# an unbootable VM.
verify_image() {
  local distro="$1" file="$2" want="" have
  case "$distro" in
    ubuntu)
      curl -fsSL "https://cloud-images.ubuntu.com/noble/current/SHA256SUMS" \
        -o "$images/ubuntu-SHA256SUMS" || return 0
      want=$(awk '/noble-server-cloudimg-amd64.img$/ {print $1}' "$images/ubuntu-SHA256SUMS" | head -1)
      ;;
    fedora)
      curl -fsSL "https://dl.fedoraproject.org/pub/fedora/linux/releases/${fedora_release%%-*}/Cloud/x86_64/images/Fedora-Cloud-${fedora_release}-x86_64-CHECKSUM" \
        -o "$images/fedora-CHECKSUM" || return 0
      # The CHECKSUM document is BSD-style: "SHA256 (<file>) = <hash>".
      want=$(awk -v f="($(basename "$file"))" '$1=="SHA256" && $2==f {print $4}' "$images/fedora-CHECKSUM" | head -1)
      ;;
    omarchy)
      curl -fsSL "$(image_url omarchy).sha256" -o "$file.sha256" || return 0
      want=$(awk '{print $1}' "$file.sha256" | head -1)
      ;;
  esac
  [[ -n $want ]] || { echo "lab: no published checksum for $distro, skipping verification" >&2; return 0; }
  have=$(sha256sum "$file" | cut -d' ' -f1)
  [[ $have == "$want" ]] || die "checksum mismatch for $file: got $have, want $want"
  echo "sha256 ok: $have  $(basename "$file")"
}

cmd_images() {
  local distro
  for distro in ubuntu fedora omarchy; do
    local file; file="$(image_file "$distro")"
    if [[ -f $file ]]; then
      printf '%-8s %s  %s\n' "$distro" "$(sha256sum "$file" | cut -d' ' -f1)" "$(basename "$file")"
    else
      printf '%-8s %s\n' "$distro" "(not fetched)"
    fi
  done
}

# ---------------------------------------------------------------------------
# seed: the cloud-init NoCloud ISO
# ---------------------------------------------------------------------------
# Each distro gets the same identity (the lab user, the lab key, NOPASSWD sudo,
# a hostname) plus the package prep that makes the tools' real backends present:
#
#   ubuntu   ufw, enabled with 22 allowed first; snapper + a btrfs data disk,
#            because the Ubuntu cloud image's own root is ext4 and snapper has
#            nothing to snapshot without one.
#   fedora   firewalld is already installed and running; snapper + the same
#            btrfs data disk, mounted with an SELinux context because Fedora
#            Cloud is enforcing out of the box; policycoreutils so the SELinux
#            state is inspectable; cronie, so that one machine in the lab is a
#            `crond.service` machine — the other half of tui-cron's unit-name
#            detection, which nothing here exercised before.
#   omarchy  nothing. The image ships the server profile's firewall already,
#            and installing into it would stop testing the shipped machine.
#
# A fourth argument names a router-topology role (router, lan-client,
# wan-host) and replaces the distro payload with that role's prep: the seed
# then also carries a network-config, because those guests have more than one
# NIC and the addresses on them are the topology.
write_seed() {
  local distro="$1" name="$2" dir="$3" role="${4:-}"
  local key; key="$(cat "$(lab_key).pub")"
  mkdir -p "$dir"

  cat >"$dir/meta-data" <<EOF
instance-id: tui-lab-$name
local-hostname: $name
EOF

  {
    cat <<EOF
#cloud-config
hostname: $name
users:
  - name: $lab_user
    gecos: tui-lab
    groups: [wheel, sudo, adm]
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - $key
ssh_pwauth: false
disable_root: true
EOF
    if [[ -n $role ]]; then
      router_seed_payload "$role"
    else
    case "$distro" in
      ubuntu)
        cat <<'EOF'
package_update: true
packages:
  - ufw
  - snapper
  - btrfs-progs
runcmd:
  # Allow 22 before enabling, or cloud-init locks the lab out of its own VM.
  - [ufw, allow, 22/tcp]
  - [ufw, --force, enable]
  # The Ubuntu cloud image root is ext4, so snapper gets a btrfs volume of its
  # own on the second disk to have something real to snapshot.
  - [bash, -c, "mkfs.btrfs -qf /dev/vdb && mkdir -p /srv/data && mount /dev/vdb /srv/data && echo '/dev/vdb /srv/data btrfs defaults 0 0' >> /etc/fstab"]
  - [bash, -c, "snapper -c data create-config /srv/data || true"]
  - [bash, -c, "touch /run/tui-lab-ready"]
EOF
        ;;
      fedora)
        cat <<'EOF'
package_update: true
packages:
  # firewalld is NOT in the Fedora Cloud Base Generic image: that image is
  # minimised and ships no firewall at all (verified on 44-1.7 — `rpm -q
  # firewalld` reports "not installed"). It has to be installed here for the
  # Fedora VM to exercise tui-firewall's firewalld path at all.
  - firewalld
  - snapper
  - btrfs-progs
  - policycoreutils
  # script(1) is split out of util-linux on Fedora and is not in the Cloud
  # Base image either. The lab renders every --demo frame through it, so
  # without this the frame check fails on Fedora alone.
  - util-linux-script
  # cron is not in the Cloud Base image either, so before this the lab had no
  # machine whose cron daemon is called `crond` — Ubuntu's is `cron.service`
  # and Omarchy has none — and half of tui-cron's unit-name detection was
  # covered only by fixtures. cronie is Fedora's cron, and it brings
  # /etc/cron.d/0hourly and /etc/crontab with it.
  - cronie
runcmd:
  - [bash, -c, "systemctl enable --now firewalld"]
  # cronie's unit is not enabled by the package, and a cron daemon that is
  # installed but stopped is a different machine from the one being tested.
  - [bash, -c, "systemctl enable --now crond"]
  - [bash, -c, "firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload"]
  # Fedora Cloud is SELinux-enforcing, and a fresh filesystem under /srv
  # inherits var_t. snapper then fails every `create` with "IO Error (mkdir
  # failed errno:13 (Permission denied))" — and logs no AVC, because auditd
  # is not running in the Cloud image either, which is what makes this one
  # slow to diagnose. `context=` labels the whole mount at mount time with
  # what the root filesystem's own /.snapshots would carry, which survives a
  # reboot and does not depend on any xattr the volume may or may not keep.
  # A `chcon` on .snapshots alone is not enough: it did not survive here.
  - [bash, -c, "mkfs.btrfs -qf /dev/vdb && mkdir -p /srv/data && mount -o defaults,context=system_u:object_r:snapperd_data_t:s0 /dev/vdb /srv/data && echo '/dev/vdb /srv/data btrfs defaults,context=system_u:object_r:snapperd_data_t:s0 0 0' >> /etc/fstab"]
  - [bash, -c, "snapper -c data create-config /srv/data || true"]
  - [bash, -c, "touch /run/tui-lab-ready"]
EOF
        ;;
      omarchy)
        # Deliberately empty: the point of this VM is the image as shipped.
        cat <<'EOF'
runcmd:
  - [bash, -c, "touch /run/tui-lab-ready"]
EOF
        ;;
    esac
    fi
  } >"$dir/user-data"

  local netcfg=()
  if [[ -n $role ]]; then
    router_net_config "$role" "$name" >"$dir/network-config"
    netcfg=(-N "$dir/network-config")
  fi

  if command -v cloud-localds >/dev/null; then
    cloud-localds "${netcfg[@]}" "$dir/seed.iso" "$dir/user-data" "$dir/meta-data"
  else
    need xorriso
    xorriso -as mkisofs -quiet -V cidata -J -r \
      -o "$dir/seed.iso" "$dir/user-data" "$dir/meta-data" \
      ${netcfg:+"$dir/network-config"} 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# up / down / status
# ---------------------------------------------------------------------------
cmd_up() {
  local distro="$1"; shift
  local mem=2048 cpus=2 disk=20 data_disk=4
  omarchy_variant=""
  while (($#)); do
    case "$1" in
      --mem) mem="$2"; shift 2 ;;
      --cpus) cpus="$2"; shift 2 ;;
      --disk) disk="$2"; shift 2 ;;
      --selinux) omarchy_variant="-selinux"; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ $distro == omarchy ]] || omarchy_variant=""

  need qemu-system-x86_64 qemu-img ssh socat
  local name="$distro"
  local dir; dir="$(vm_dir "$name")"

  if vm_running "$name"; then
    log "$name already running (pid $(<"$dir/pid"))"
    return 0
  fi

  vm_prepare_disks "$name" "$distro" "$dir" "$disk" "$data_disk"
  [[ -f $dir/seed.iso ]] || write_seed "$distro" "$name" "$dir"

  extra_nics=()
  mgmt_mac=""
  vm_launch "$name" "$dir" "$mem" "$cpus"

  vm_wait_ssh "$name" "${WAIT:-900}"
  # cloud-init's runcmd finishes after sshd is up, so the package prep is still
  # running when the first connection succeeds. Waiting for it here is what
  # makes `up` mean "ready to test".
  # `sudo -n`, and not a bare call: on Fedora Cloud /run/cloud-init/cloud.cfg
  # is root-only, so an unprivileged `cloud-init status --wait` dies on a
  # PermissionError inside its own polling loop and never returns — `up` then
  # hangs on a machine that finished minutes ago.
  log "waiting for cloud-init to finish"
  vm_ssh "$name" "sudo -n cloud-init status --wait >/dev/null 2>&1 || true; sudo -n cloud-init status --long 2>&1 | head -3" || true
}

# vm_prepare_disks materialises the per-VM root and data disks and the UEFI
# variable store from the cached image. Split out of cmd_up so the router
# topology, whose guests are named after their role rather than their distro,
# builds its disks through the same code.
vm_prepare_disks() {
  local name="$1" distro="$2" dir="$3" disk="$4" data_disk="$5"
  local image; image="$(cmd_fetch "$distro" | tail -1)"
  mkdir -p "$dir"

  if [[ ! -f $dir/disk.qcow2 ]]; then
    # A full convert rather than a backing file: with a backing file every
    # write in the lab would be a delta against the cached image, and the cache
    # could never be pruned while a VM existed.
    log "creating $name disk (${disk}G) from $(basename "$image")"
    qemu-img convert -O qcow2 "$image" "$dir/disk.qcow2"
    # Grow only. The Omarchy image already declares a virtual size larger than
    # the 20G default, and `qemu-img resize` to a smaller size is a shrink,
    # which it refuses without --shrink and which would truncate the image.
    # Parsed from the human-readable output, not --output=json: the JSON nests
    # a "children" block for the raw file protocol whose own virtual-size (the
    # host file's length) comes first and shadows the qcow2's.
    local current_bytes current_gb
    current_bytes=$(qemu-img info "$dir/disk.qcow2" \
      | sed -n 's/^virtual size: .*(\([0-9]*\) bytes).*/\1/p' | head -1)
    current_gb=$(( ${current_bytes:-0} / 1073741824 ))
    if (( disk > current_gb )); then
      qemu-img resize -q "$dir/disk.qcow2" "${disk}G"
    else
      log "keeping the image's own ${current_gb}G virtual size (larger than --disk ${disk}G)"
    fi
  fi
  # The second, empty disk arrives as /dev/vdb and is where the btrfs volume
  # for snapper goes. Nothing in the image touches it.
  [[ -f $dir/data.qcow2 ]] || qemu-img create -q -f qcow2 "$dir/data.qcow2" "${data_disk}G"
  [[ -f $dir/vars.qcow2 ]] || cp "$ovmf_dir/OVMF_VARS_4M.qcow2" "$dir/vars.qcow2"
}

# vm_launch boots one prepared VM headless and daemonised. Every guest gets the
# management NIC — user-mode networking with an ssh hostfwd, which is how the
# lab talks to it — and anything in the `extra_nics` array is appended after it.
# The router topology uses that array for the WAN and LAN segments; `up` leaves
# it empty and boots exactly the single-NIC machine it always did.
#
# `mgmt_mac` is empty unless the caller sets it, and that is not a detail: a
# guest whose cloud-init has already run carries a netplan file matching the
# management NIC by the MAC it had on first boot, so handing that NIC a new
# address on a later boot leaves the machine with no network at all. Only the
# router guests, whose seed matches the MAC this script chose, set it.
extra_nics=()
mgmt_mac=""
vm_launch() {
  local name="$1" dir="$2" mem="$3" cpus="$4"
  local port; port="$(vm_port "$name")"
  qemu-system-x86_64 \
    -name "$name" -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$mem" \
    -drive if=pflash,format=qcow2,readonly=on,file="$ovmf_dir/OVMF_CODE_4M.qcow2" \
    -drive if=pflash,format=qcow2,file="$dir/vars.qcow2" \
    -drive file="$dir/disk.qcow2",format=qcow2,if=none,id=drive0 \
    -device virtio-blk-pci,drive=drive0,bootindex=1 \
    -drive file="$dir/data.qcow2",format=qcow2,if=none,id=drive1 \
    -device virtio-blk-pci,drive=drive1 \
    -drive file="$dir/seed.iso",media=cdrom,if=none,format=raw,id=cdrom0 \
    -device ide-cd,drive=cdrom0,bus=ide.0 \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$port"-:22 \
    -device "virtio-net-pci,netdev=net0${mgmt_mac:+,mac=$mgmt_mac}" \
    "${extra_nics[@]}" \
    -display none \
    -monitor unix:"$(vm_mon "$name")",server,nowait \
    -serial file:"$dir/serial.log" \
    -rtc base=utc \
    -daemonize -pidfile "$dir/pid"

  log "started $name (ssh port $port, ${mem}M, ${cpus} cpu)"
}

# vm_mac gives every NIC a stable address derived from the VM name and the NIC
# index, inside the 52:54:00 range QEMU uses. Stability is what lets a guest's
# cloud-init network-config match an interface by MAC and rename it, so the
# rules a test writes can say `wan0` and `lan0` instead of guessing at
# enp0sN ordering.
vm_mac() {
  local h; h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '52:54:00:%02x:%02x:%02x\n' $(( (h / 256) % 256 )) $(( h % 256 )) "$2"
}

cmd_down() {
  local name="$1"
  if [[ $lab_backend == libvirt ]]; then
    local dom="tuilab-$name" i
    lv domstate "$dom" >/dev/null 2>&1 || { log "$name not defined"; return 0; }
    vm_running "$name" || { log "$name not running"; return 0; }
    lv shutdown "$dom" >/dev/null 2>&1 || true
    for ((i = 0; i < 40; i++)); do vm_running "$name" || break; sleep 1; done
    vm_running "$name" && lv destroy "$dom" >/dev/null 2>&1 || true
    log "stopped $name"
    return 0
  fi
  vm_running "$name" || { log "$name not running"; return 0; }
  monitor "$name" 'system_powerdown' >/dev/null || true
  local i
  for ((i = 0; i < 40; i++)); do vm_running "$name" || break; sleep 1; done
  vm_running "$name" && kill "$(<"$(vm_dir "$name")/pid")"
  log "stopped $name"
}

cmd_status() {
  local names=("$@")
  ((${#names[@]})) || names=(ubuntu fedora omarchy)
  local name
  for name in "${names[@]}"; do
    if vm_running "$name"; then
      printf '%-8s running  pid %-8s ssh port %s\n' \
        "$name" "$(<"$(vm_dir "$name")/pid")" "$(vm_port "$name")"
    else
      printf '%-8s stopped\n' "$name"
    fi
  done
}

cmd_snapshot() {
  local name="$1" tag="$2"
  vm_running "$name" && die "stop $name first"
  qemu-img snapshot -c "$tag" "$(vm_dir "$name")/disk.qcow2"
  cp "$(vm_dir "$name")/vars.qcow2" "$(vm_dir "$name")/vars.$tag.qcow2"
  log "snapshot $name@$tag"
}

cmd_restore() {
  local name="$1" tag="$2"
  vm_running "$name" && die "stop $name first"
  qemu-img snapshot -a "$tag" "$(vm_dir "$name")/disk.qcow2"
  cp "$(vm_dir "$name")/vars.$tag.qcow2" "$(vm_dir "$name")/vars.qcow2"
  log "restored $name@$tag"
}

# ---------------------------------------------------------------------------
# build: the binary under test
# ---------------------------------------------------------------------------
# build_tool resolves what `test` and `report` are going to ship into the
# guests and leaves it in $tool_bin: the caller's --bin when it passed one,
# otherwise a fresh build from the sibling checkout.
tool_bin=""
build_tool() {
  local tool="$1" bin="${2:-}"
  local repo="$here/../$tool"
  [[ -d $repo ]] || die "no sibling checkout for $tool at $repo"

  if [[ -z $bin ]]; then
    need go
    bin="$out/bin/$tool"
    mkdir -p "$out/bin"
    log "building $tool from $repo"
    # CGO off so one binary runs on every guest regardless of its libc: the
    # lab's Fedora host would otherwise produce something an Ubuntu guest with
    # an older glibc refuses to start.
    ( cd "$repo" && CGO_ENABLED=0 go build -trimpath -o "$bin" "./cmd/$tool" )
  fi
  [[ -x $bin ]] || die "not an executable: $bin"
  tool_bin="$bin"
}

# ---------------------------------------------------------------------------
# test: build a tool, ship it in, run its checks
# ---------------------------------------------------------------------------
# The contract a tool opts into is one file: test/smoke.sh in its repository.
# It runs inside the guest as the lab user, escalates with `sudo -n`, prints a
# short PASS/FAIL table and exits non-zero if anything failed. The lab adds
# three checks of its own around it that need no cooperation from the tool:
# --version, a rendered --demo frame under a pty, and --check against the real
# backend when the tool has one.
cmd_test() {
  local tool="$1"; shift
  local bin="" keep=0 vms=()
  while (($#)); do
    case "$1" in
      --bin) bin="$2"; shift 2 ;;
      --keep) keep=1; shift ;;
      -*) die "unknown option: $1" ;;
      *) vms+=("$1"); shift ;;
    esac
  done
  ((${#vms[@]})) || vms=(ubuntu fedora omarchy)

  build_tool "$tool" "$bin"
  bin="$tool_bin"

  local smoke="$here/../$tool/test/smoke.sh"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local logdir="$out/results/$stamp-$tool"
  mkdir -p "$logdir"

  local name rc=0
  for name in "${vms[@]}"; do
    echo
    log "=== $tool on $name ==="
    if ! vm_running "$name"; then
      echo "SKIP  $name is not running (lab.sh up $name)"
      rc=1
      continue
    fi
    run_on_vm "$tool" "$name" "$bin" "$smoke" "$logdir" || rc=1
  done

  echo
  log "logs: $logdir"
  ((keep)) || true
  return $rc
}

# run_on_vm copies the binary in and runs the three lab checks plus the tool's
# own smoke test, appending everything to a per-VM log.
run_on_vm() {
  local tool="$1" name="$2" bin="$3" smoke="$4" logdir="$5"
  local logfile="$logdir/$name.log" rc=0

  vm_scp "$name" "$bin" "/tmp/$tool" >/dev/null
  vm_ssh "$name" "chmod +x /tmp/$tool"

  {
    echo "### $tool on $name — $(date -Is)"
    vm_ssh "$name" "cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID)=' ; echo root-fs=\$(findmnt -no FSTYPE /) ; echo data-fs=\$(findmnt -no FSTYPE /srv/data 2>/dev/null || echo none)"
  } >>"$logfile" 2>&1

  # 1. --version: the binary starts at all on this guest.
  if vm_ssh "$name" "/tmp/$tool --version" >>"$logfile" 2>&1; then
    echo "PASS  version"
  else
    echo "FAIL  version"; rc=1
  fi

  # 2. A rendered --demo frame, through a pty inside the guest. `script -qec`
  #    is what gives Bubble Tea a terminal; the generous timeout is for the
  #    OSC 11 background-colour query the theme layer sends at startup, which
  #    only resolves when the terminal answers or the probe gives up. 25s, not
  #    15s: the binary has just been copied in, so the very first run pays for
  #    a cold page cache on top of the probe and 15s was observed to lose that
  #    race on a 2-cpu guest.
  if vm_ssh "$name" "TERM=xterm-256color COLUMNS=120 LINES=40 \
      script -qec 'timeout -s TERM 25 /tmp/$tool --demo' /dev/null </dev/null 2>&1 \
      | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' > /tmp/$tool.frame; \
      grep -q 'demo' /tmp/$tool.frame" >>"$logfile" 2>&1; then
    echo "PASS  demo frame"
  else
    echo "FAIL  demo frame"; rc=1
  fi
  vm_ssh "$name" "cat /tmp/$tool.frame 2>/dev/null | head -40" >>"$logfile" 2>&1 || true

  # 3. The tool's own smoke test against the real backend, when it ships one.
  if [[ -f $smoke ]]; then
    vm_scp "$name" "$smoke" "/tmp/$tool-smoke.sh" >/dev/null
    vm_ssh "$name" "chmod +x /tmp/$tool-smoke.sh"
    if vm_ssh "$name" "TUI_LAB_BIN=/tmp/$tool /tmp/$tool-smoke.sh" 2>&1 | tee -a "$logfile"; then
      echo "PASS  smoke"
    else
      echo "FAIL  smoke"; rc=1
    fi
  else
    echo "SKIP  smoke (no test/smoke.sh in the tool's repository)"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# report: the block a bug report carries, checked on every guest
# ---------------------------------------------------------------------------
# Every tool in the family answers `--report` with a plain `key: value` block
# meant to be pasted verbatim into a public issue. That makes it two things at
# once: the first thing a maintainer reads, and a privacy promise. The promise
# is the half a fixture cannot check — it only means anything on a machine that
# has a real host name, a real user and a real home directory, which is exactly
# what a guest is and what the developer's own laptop is too dangerous to be.
#
# So this runs the block on each guest, live and under --demo, prints both and
# asserts four things about each: it exits 0, its first line names the tool,
# nothing in it names this machine, and the demo block says so on the backend
# line. A failed assertion shows the offending line and fails the command.
cmd_report() {
  local target="$1"; shift
  local bin="" vms=()
  while (($#)); do
    case "$1" in
      --bin) bin="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) vms+=("$1"); shift ;;
    esac
  done
  ((${#vms[@]})) || vms=(ubuntu fedora omarchy)

  local tools=()
  if [[ $target == all ]]; then
    [[ -z $bin ]] || die "--bin names one binary, so it cannot be used with all"
    mapfile -t tools < <(sibling_tools)
    ((${#tools[@]})) || die "no sibling tool checkouts next to $here"
  else
    tools=("$target")
  fi

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local logdir="$out/results/$stamp-report"
  mkdir -p "$logdir"

  local rc=0 tool name
  for tool in "${tools[@]}"; do
    build_tool "$tool" "$bin"
    for name in "${vms[@]}"; do
      echo
      log "=== $tool --report on $name ==="
      if ! vm_running "$name"; then
        echo "SKIP  $name is not running (lab.sh up $name)"
        rc=1
        continue
      fi
      report_on_vm "$tool" "$name" "$tool_bin" "$logdir" || rc=1
    done
  done

  echo
  log "logs: $logdir"
  return $rc
}

# sibling_tools lists the tool checkouts next to this one: a tui-* directory
# with a cmd/<name> package in it. tui-kit is a library and tui-lab is this,
# so neither has one and neither is listed.
sibling_tools() {
  local dir name
  for dir in "$here"/../tui-*; do
    name="$(basename "$dir")"
    [[ -d $dir/cmd/$name ]] && echo "$name"
  done
  return 0
}

# report_on_vm ships the binary in the same way `test` does and checks both
# blocks the tool can print on this guest.
report_on_vm() {
  local tool="$1" name="$2" bin="$3" logdir="$4"
  local logfile="$logdir/$name-$tool.log" rc=0 host

  vm_scp "$name" "$bin" "/tmp/$tool" >/dev/null
  vm_ssh "$name" "chmod +x /tmp/$tool"

  # The guest's own idea of its name, asked of the guest rather than taken from
  # the VM name the lab uses. They agree today, and the leak check should not
  # be the thing that quietly stops meaning anything if they ever stop.
  host="$(vm_ssh "$name" "uname -n" | tr -d '\r')"

  check_report "$tool" "$name" "$host" "$logfile" live "/tmp/$tool --report" || rc=1
  check_report "$tool" "$name" "$host" "$logfile" demo "/tmp/$tool --report --demo" || rc=1

  if ((rc)); then
    echo "VERDICT  $tool --report on $name: FAIL"
  else
    echo "VERDICT  $tool --report on $name: PASS"
  fi
  return $rc
}

# check_report runs one block, prints it, and asserts on it.
check_report() {
  local tool="$1" name="$2" host="$3" logfile="$4" mode="$5" cmd="$6"
  local block status=0 rc=0 headline offenders

  if block="$(vm_ssh "$name" "$cmd" 2>&1)"; then status=0; else status=$?; fi

  echo "--- $tool --report ($mode) on $name"
  sed 's/^/    /' <<<"$block"
  {
    echo "### $tool --report ($mode) on $name — $(date -Is)"
    printf '%s\n' "$block"
  } >>"$logfile"

  if ((status == 0)); then
    echo "PASS  $mode exits 0"
  else
    echo "FAIL  $mode exits $status"
    rc=1
  fi

  # The headline is the one line of the block that is not a key/value pair,
  # and it opens with the binary name: a block pasted into the wrong repository
  # should say so in the line the maintainer reads first.
  headline="$(head -1 <<<"$block")"
  if [[ $headline == "$tool "* ]]; then
    echo "PASS  $mode headline names $tool"
  else
    echo "FAIL  $mode headline does not name $tool"
    echo "      | $headline"
    rc=1
  fi

  # The distro and kernel lines are excluded from the host-name search rather
  # than from the promise: they are built from /etc/os-release and from uname's
  # release and machine fields, never from its nodename, and every guest here
  # is named after its distribution, so "fedora" belongs in both of them.
  #
  # The user name is matched on word boundaries, not as a substring: the lab
  # user is called `lab`, and "unavailable" is not a leak.
  offenders="$(grep -vE '^(distro|kernel): ' <<<"$block" \
    | grep -E "/home/|/root/|\b($host|$lab_user)\b" || true)"
  if [[ -z $offenders ]]; then
    echo "PASS  $mode names neither this machine, its user nor a home path"
  else
    echo "FAIL  $mode names this machine, its user or a home path"
    sed 's/^/      | /' <<<"$offenders"
    rc=1
  fi

  # A demo block that does not announce itself is the worst kind of bug report:
  # every number in it is sample data and nothing says so.
  if [[ $mode == demo ]]; then
    if grep -qx 'backend: demo' <<<"$block"; then
      echo "PASS  demo says backend: demo"
    else
      echo "FAIL  demo does not say backend: demo"
      grep -E '^backend: ' <<<"$block" | sed 's/^/      | /' || true
      rc=1
    fi
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# router: the two-network topology for the firewall work
# ---------------------------------------------------------------------------
# Three guests off the same cached cloud image the rest of the lab uses:
#
#   wan-host  ── wan ──  router  ── lan ──  lan-client
#   10.90.0.20        .1 │ │ .1          10.91.0.30
#                        (mgmt NICs, one per guest, carry ssh only)
#
# Each guest keeps the user-mode management NIC every lab VM has, so the lab
# reaches it over the same ssh hostfwd as always and cloud-init can still
# install packages. The topology itself is two more NICs per machine on QEMU
# socket segments: a point-to-point TCP link on the loopback per network, which
# needs no bridge, no tap and no root on the host. Two endpoints per link is
# all the topology has, which is exactly what a socket netdev carries.
#
# The router boots with IP forwarding on, nftables installed and an empty
# ruleset. Every rule in `router test` is written by the test itself: what is
# being proven is that the topology forwards, translates and blocks the way a
# filtering, NAT-ing, port-forwarding router has to, before any tui tool is in
# the picture.

router_wan_net="10.90.0.0/24"
router_lan_net="10.91.0.0/24"
router_wan_ip="10.90.0.1"
router_lan_ip="10.91.0.1"
wan_host_ip="10.90.0.20"
lan_client_ip="10.91.0.30"
wan_host_port=8080
lan_client_port=8081

# The two link sockets. They live on the loopback and are only meaningful while
# the VMs are up; the ports are overridable so a second topology can coexist.
router_wan_link="${LAB_WAN_LINK:-127.0.0.1:12090}"
router_lan_link="${LAB_LAN_LINK:-127.0.0.1:12091}"

# The distro under the three guests. Ubuntu because all three need nothing more
# than nftables, curl and python3, and noble's cloud image has cloud-init's
# netplan renderer, which is what turns the network-config below into named
# `wan0`/`lan0` interfaces.
router_distro="${LAB_ROUTER_DISTRO:-ubuntu}"

# router_net_config renders the guest's cloud-init network-config. Interfaces
# are matched by the MAC vm_launch gave them and renamed, so a rule can name
# wan0 and lan0 and mean it.
router_net_config() {
  local role="$1" name="$2"
  cat <<EOF
version: 2
ethernets:
  mgmt:
    match:
      macaddress: "$(vm_mac "$name" 0)"
    set-name: mgmt
    dhcp4: true
EOF
  case "$role" in
    router)
      cat <<EOF
  wan0:
    match:
      macaddress: "$(vm_mac "$name" 1)"
    set-name: wan0
    dhcp4: false
    addresses: [$router_wan_ip/24]
  lan0:
    match:
      macaddress: "$(vm_mac "$name" 2)"
    set-name: lan0
    dhcp4: false
    addresses: [$router_lan_ip/24]
EOF
      ;;
    wan-host)
      # No route to the LAN on purpose: a reply that comes back from behind the
      # router only ever reaches this machine because the router translated it,
      # which is what makes the NAT check a real one.
      cat <<EOF
  wan0:
    match:
      macaddress: "$(vm_mac "$name" 1)"
    set-name: wan0
    dhcp4: false
    addresses: [$wan_host_ip/24]
EOF
      ;;
    lan-client)
      # The default route is the router's LAN address. The management NIC keeps
      # a default of its own at a worse metric so cloud-init can install
      # packages before the router exists; `router up` deletes it once the
      # guest is provisioned, so the machine the tests see has exactly one.
      cat <<EOF
    dhcp4-overrides:
      route-metric: 200
  lan0:
    match:
      macaddress: "$(vm_mac "$name" 1)"
    set-name: lan0
    dhcp4: false
    addresses: [$lan_client_ip/24]
    routes:
      - to: default
        via: $router_lan_ip
        metric: 100
EOF
      ;;
  esac
}

# router_seed_payload is the cloud-config body for one role, appended to the
# identity block every seed in this lab shares.
router_seed_payload() {
  case "$1" in
    router)
      cat <<'EOF'
package_update: true
packages:
  - nftables
  - conntrack
  - tcpdump
  - curl
  # tmux is the pty `router test --via-tool` drives the real TUI through.
  - tmux
write_files:
  - path: /etc/sysctl.d/99-tui-lab-router.conf
    content: |
      net.ipv4.ip_forward=1
runcmd:
  - [sysctl, --system]
  # ufw ships installed and inactive on the cloud image; making that explicit
  # keeps the ruleset the tests write the only one in the machine.
  - [bash, -c, "ufw disable >/dev/null 2>&1 || true"]
  # nftables.service would restore /etc/nftables.conf at boot. The router is
  # meant to come up with nothing loaded: the tests create every rule.
  - [bash, -c, "systemctl disable --now nftables.service >/dev/null 2>&1 || true"]
  - [bash, -c, "nft flush ruleset"]
  - [bash, -c, "touch /run/tui-lab-ready"]
EOF
      ;;
    wan-host)
      cat <<EOF
package_update: true
packages:
  - curl
  - python3
write_files:
  - path: /srv/wan/index.html
    content: |
      tui-lab wan-host service
  - path: /etc/systemd/system/wan-http.service
    content: |
      [Unit]
      Description=tui-lab wan-host HTTP service
      After=network.target

      [Service]
      # -u, or python block-buffers stderr when it is a file and the access log
      # the NAT check reads stays empty until the process exits.
      ExecStart=/usr/bin/python3 -u -m http.server $wan_host_port --directory /srv/wan
      StandardOutput=append:/var/log/wan-http.log
      StandardError=append:/var/log/wan-http.log
      Restart=always

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [bash, -c, "ufw disable >/dev/null 2>&1 || true"]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, wan-http.service]
  - [bash, -c, "touch /run/tui-lab-ready"]
EOF
      ;;
    lan-client)
      cat <<EOF
package_update: true
packages:
  - curl
  - python3
write_files:
  - path: /srv/lan/index.html
    content: |
      tui-lab lan-client service
  - path: /etc/systemd/system/lan-http.service
    content: |
      [Unit]
      Description=tui-lab lan-client HTTP service
      After=network.target

      [Service]
      ExecStart=/usr/bin/python3 -u -m http.server $lan_client_port --directory /srv/lan
      StandardOutput=append:/var/log/lan-http.log
      StandardError=append:/var/log/lan-http.log
      Restart=always

      [Install]
      WantedBy=multi-user.target
runcmd:
  - [bash, -c, "ufw disable >/dev/null 2>&1 || true"]
  - [systemctl, daemon-reload]
  - [systemctl, enable, --now, lan-http.service]
  - [bash, -c, "touch /run/tui-lab-ready"]
EOF
      ;;
    *) die "unknown router role: $1" ;;
  esac
}

# router_nics fills the extra_nics array for one role: the segments that guest
# sits on. The router listens on both links and the two hosts connect to it, so
# it has to be booted first — which is the order router_up uses.
router_nics() {
  local role="$1"
  extra_nics=()
  case "$role" in
    router)
      extra_nics+=(
        -netdev "socket,id=wan,listen=$router_wan_link"
        -device "virtio-net-pci,netdev=wan,mac=$(vm_mac router 1)"
        -netdev "socket,id=lan,listen=$router_lan_link"
        -device "virtio-net-pci,netdev=lan,mac=$(vm_mac router 2)"
      )
      ;;
    wan-host)
      extra_nics+=(
        -netdev "socket,id=wan,connect=$router_wan_link"
        -device "virtio-net-pci,netdev=wan,mac=$(vm_mac wan-host 1)"
      )
      ;;
    lan-client)
      extra_nics+=(
        -netdev "socket,id=lan,connect=$router_lan_link"
        -device "virtio-net-pci,netdev=lan,mac=$(vm_mac lan-client 1)"
      )
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The libvirt backend for the router topology
# ---------------------------------------------------------------------------
# The same three guests as the qemu backend, but as KVM domains on the avell
# hypervisor over real virtual networks. mgmt is a NAT network with a fixed
# lease per guest, so the lab knows each address before the guest boots and
# reaches it by ssh through the hypervisor. wan and lan are pure isolated
# switches: no host IP, no DHCP, the router owns every address on them. The
# guest cloud-init network-config is the same one the qemu backend renders —
# it matches interfaces by the MAC this script assigns, and those MACs are put
# on the domain's NICs here, so `wan0`/`lan0` name the same links on both.

# libvirt_mgmt_ip is the fixed management address a guest gets from the mgmt
# network's static DHCP lease. It is what ssh connects to (through the jump).
libvirt_mgmt_ip() {
  case "$1" in
    router) echo "$libvirt_mgmt_subnet.2" ;;
    wan-host) echo "$libvirt_mgmt_subnet.20" ;;
    lan-client) echo "$libvirt_mgmt_subnet.30" ;;
    *) die "libvirt backend has no management address for guest: $1" ;;
  esac
}

# libvirt_ensure_networks defines mgmt (NAT, with the three fixed leases) and
# wan/lan (isolated) if they are absent. Every name is `tuilab-*`, and the
# mgmt subnet is clear of the host's own networks.
libvirt_ensure_networks() {
  if ! lv net-info "$libvirt_mgmt_net" >/dev/null 2>&1; then
    log "defining network $libvirt_mgmt_net (NAT $libvirt_mgmt_subnet.0/24)"
    local nx; nx="$(mktemp)"
    cat >"$nx" <<EOF
<network>
  <name>$libvirt_mgmt_net</name>
  <bridge name='tuilabmgmt0'/>
  <forward mode='nat'/>
  <ip address='$libvirt_mgmt_subnet.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$libvirt_mgmt_subnet.100' end='$libvirt_mgmt_subnet.200'/>
      <host mac='$(vm_mac router 0)' name='tuilab-router' ip='$libvirt_mgmt_subnet.2'/>
      <host mac='$(vm_mac wan-host 0)' name='tuilab-wan-host' ip='$libvirt_mgmt_subnet.20'/>
      <host mac='$(vm_mac lan-client 0)' name='tuilab-lan-client' ip='$libvirt_mgmt_subnet.30'/>
    </dhcp>
  </ip>
</network>
EOF
    lv net-define "$nx" >/dev/null
    lv net-start "$libvirt_mgmt_net" >/dev/null
    lv net-autostart "$libvirt_mgmt_net" >/dev/null || true
    rm -f "$nx"
  fi
  # wan and lan carry the topology and nothing else: no forward, no host IP,
  # no DHCP. That is what makes the NAT and forwarding checks mean something —
  # the only way between the segments is through the router.
  local seg name br sx
  for seg in wan lan; do
    name="tuilab-$seg"; br="tuilab${seg}0"
    if ! lv net-info "$name" >/dev/null 2>&1; then
      log "defining isolated network $name"
      sx="$(mktemp)"
      cat >"$sx" <<EOF
<network>
  <name>$name</name>
  <bridge name='$br'/>
</network>
EOF
      lv net-define "$sx" >/dev/null
      lv net-start "$name" >/dev/null
      lv net-autostart "$name" >/dev/null || true
      rm -f "$sx"
    fi
  done
}

# libvirt_ensure_infra makes the pool, the networks and the base image exist.
# The pool directory is owned by the login user so overlays and seeds stage
# without privilege; libvirt re-owns a disk to qemu at start and restores it
# after. The base image is uploaded once and every guest is a thin overlay.
libvirt_ensure_infra() {
  need virsh qemu-img ssh scp
  avell_ssh "mkdir -p '$libvirt_pool_path'"

  if ! lv pool-info "$libvirt_pool" >/dev/null 2>&1; then
    log "defining libvirt pool $libvirt_pool at $libvirt_pool_path"
    local px; px="$(mktemp)"
    cat >"$px" <<EOF
<pool type='dir'>
  <name>$libvirt_pool</name>
  <target><path>$libvirt_pool_path</path></target>
</pool>
EOF
    lv pool-define "$px" >/dev/null
    lv pool-start "$libvirt_pool" >/dev/null || true
    lv pool-autostart "$libvirt_pool" >/dev/null || true
    rm -f "$px"
  fi

  libvirt_ensure_networks

  if ! avell_ssh "test -f '$libvirt_pool_path/$libvirt_base_vol'"; then
    local img; img="$(cmd_fetch "$router_distro" | tail -1)"
    log "uploading base image to the pool, once: $(basename "$img")"
    avell_scp "$img" "$libvirt_pool_path/$libvirt_base_vol"
  fi
}

# libvirt_iface is one <interface> on a network with a fixed MAC.
libvirt_iface() {
  cat <<EOF
    <interface type='network'>
      <source network='$1'/>
      <mac address='$2'/>
      <model type='virtio'/>
    </interface>
EOF
}

# libvirt_domain_xml renders one guest. BIOS boot (no OVMF) keeps the avell
# side simple: the Ubuntu cloud image boots either way. Every guest gets the
# mgmt NIC; the topology NICs are per role, on the isolated segments, with the
# same MACs the cloud-init network-config matches by.
libvirt_domain_xml() {
  local role="$1" mem="$2" cpus="$3" pool="$libvirt_pool_path" topo=""
  case "$role" in
    router)
      topo="$(libvirt_iface "$libvirt_wan_net" "$(vm_mac router 1)")$(libvirt_iface "$libvirt_lan_net" "$(vm_mac router 2)")" ;;
    wan-host)
      topo="$(libvirt_iface "$libvirt_wan_net" "$(vm_mac wan-host 1)")" ;;
    lan-client)
      topo="$(libvirt_iface "$libvirt_lan_net" "$(vm_mac lan-client 1)")" ;;
  esac
  cat <<EOF
<domain type='kvm'>
  <name>tuilab-$role</name>
  <memory unit='MiB'>$mem</memory>
  <vcpu>$cpus</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'/>
  <on_reboot>restart</on_reboot>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$pool/tuilab-$role.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$pool/tuilab-$role-seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='$libvirt_mgmt_net'/>
      <mac address='$(vm_mac "$role" 0)'/>
      <model type='virtio'/>
    </interface>
$topo
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <graphics type='vnc' autoport='yes' listen='127.0.0.1'/>
    <video><model type='virtio'/></video>
    <memballoon model='virtio'/>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
  </devices>
</domain>
EOF
}

# libvirt_boot_guest stages the overlay and seed in the pool and defines and
# starts the domain. A stale domain of the same name is undefined first so its
# XML is always this run's.
libvirt_boot_guest() {
  local role="$1" mem="$2" cpus="$3" disk="$4" pool="$libvirt_pool_path"
  libvirt_ensure_infra
  local dir; dir="$(vm_dir "$role")"
  mkdir -p "$dir"
  [[ -f $dir/seed.iso ]] || write_seed "$router_distro" "$role" "$dir" "$role"

  if lv domstate "tuilab-$role" >/dev/null 2>&1; then
    lv undefine "tuilab-$role" >/dev/null 2>&1 || true
  fi
  avell_ssh "rm -f '$pool/tuilab-$role.qcow2' '$pool/tuilab-$role-seed.iso'"
  log "creating overlay and seed for $role in the pool"
  avell_ssh "qemu-img create -q -f qcow2 -F qcow2 -b '$pool/$libvirt_base_vol' '$pool/tuilab-$role.qcow2' ${disk}G >/dev/null"
  avell_scp "$dir/seed.iso" "$pool/tuilab-$role-seed.iso"

  local dx; dx="$(mktemp)"
  libvirt_domain_xml "$role" "$mem" "$cpus" >"$dx"
  lv define "$dx" >/dev/null
  lv start "tuilab-$role" >/dev/null
  rm -f "$dx"
  log "started tuilab-$role (mgmt $(libvirt_mgmt_ip "$role"), ${mem}M, ${cpus} cpu)"
}

# libvirt_router_teardown removes every tuilab-* domain, its overlay and seed,
# and the three networks. It leaves the pool and the base image in place, so
# the next `router up` is a few seconds of overlay creation, not a re-upload.
# Every object it names is `tuilab-*`; it never touches anything else.
libvirt_router_teardown() {
  local role dom pool="$libvirt_pool_path"
  for role in lan-client wan-host router; do
    dom="tuilab-$role"
    if lv domstate "$dom" >/dev/null 2>&1; then
      [[ "$(lv domstate "$dom")" == running ]] && lv destroy "$dom" >/dev/null 2>&1 || true
      lv undefine "$dom" >/dev/null 2>&1 || true
      log "removed domain $dom"
    fi
    avell_ssh "rm -f '$pool/tuilab-$role.qcow2' '$pool/tuilab-$role-seed.iso' '$pool/tuilab-$role-serial.log'"
  done
  local net
  for net in "$libvirt_wan_net" "$libvirt_lan_net" "$libvirt_mgmt_net"; do
    if lv net-info "$net" >/dev/null 2>&1; then
      lv net-destroy "$net" >/dev/null 2>&1 || true
      lv net-undefine "$net" >/dev/null 2>&1 || true
      log "removed network $net"
    fi
  done
  log "left pool $libvirt_pool and base image $libvirt_base_vol in place for next time"
}

# router_boot_one boots one topology guest on whichever backend is selected,
# then waits for ssh and for cloud-init to finish — the same "ready to test"
# bar `up` means for any other lab VM.
router_boot_one() {
  local role="$1" mem="$2" cpus="$3" disk="$4"
  if [[ $lab_backend == libvirt ]]; then
    libvirt_boot_guest "$role" "$mem" "$cpus" "$disk"
  else
    local dir; dir="$(vm_dir "$role")"
    vm_prepare_disks "$role" "$router_distro" "$dir" "$disk" 1
    [[ -f $dir/seed.iso ]] || write_seed "$router_distro" "$role" "$dir" "$role"
    router_nics "$role"
    mgmt_mac="$(vm_mac "$role" 0)"
    vm_launch "$role" "$dir" "$mem" "$cpus"
  fi
  vm_wait_ssh "$role" "${WAIT:-900}"
  log "waiting for cloud-init to finish on $role"
  vm_ssh "$role" "sudo -n cloud-init status --wait >/dev/null 2>&1 || true; sudo -n cloud-init status --long 2>&1 | head -3" || true
}

cmd_router_up() {
  local mem=1536 cpus=2 disk=12
  while (($#)); do
    case "$1" in
      --mem) mem="$2"; shift 2 ;;
      --cpus) cpus="$2"; shift 2 ;;
      --disk) disk="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  if [[ $lab_backend == libvirt ]]; then
    need virsh qemu-img ssh scp
  else
    need qemu-system-x86_64 qemu-img ssh socat
  fi

  local role
  for role in router wan-host lan-client; do
    if vm_running "$role"; then
      log "$role already running"
      continue
    fi
    router_boot_one "$role" "$mem" "$cpus" "$disk"
  done

  # The management NIC's own default route exists so cloud-init could reach the
  # archive. Now that the guest is provisioned it would be a second way out of
  # the LAN, and the point of the client is that its only way out is the router.
  # The mgmt gateway is QEMU's 10.0.2.2 on the qemu backend and the mgmt
  # network's own address on libvirt.
  local mgmt_gw="10.0.2.2"
  [[ $lab_backend == libvirt ]] && mgmt_gw="$libvirt_mgmt_subnet.1"
  log "pointing lan-client's default route at the router"
  vm_ssh lan-client "sudo -n ip -4 route del default via $mgmt_gw 2>/dev/null || true; ip -4 route show default" || true

  cmd_router_status
}

cmd_router_down() {
  if [[ $lab_backend == libvirt ]]; then libvirt_router_teardown; return; fi
  local role
  for role in lan-client wan-host router; do cmd_down "$role"; done
}

cmd_router_status() {
  local role
  if [[ $lab_backend == libvirt ]]; then
    printf 'backend  libvirt (%s)\n' "$libvirt_uri"
    printf 'nets     %s (%s.0/24 nat)   %s (%s, isolated)   %s (%s, isolated)\n' \
      "$libvirt_mgmt_net" "$libvirt_mgmt_subnet" \
      "$libvirt_wan_net" "$router_wan_net" "$libvirt_lan_net" "$router_lan_net"
    for role in router lan-client wan-host; do
      if vm_running "$role"; then
        printf '%-11s running  mgmt %s\n' "$role" "$(libvirt_mgmt_ip "$role")"
      else
        printf '%-11s stopped\n' "$role"
      fi
    done
  else
    cmd_status router lan-client wan-host
    printf 'links    wan %s (%s)   lan %s (%s)\n' \
      "$router_wan_link" "$router_wan_net" "$router_lan_link" "$router_lan_net"
  fi
  for role in router lan-client wan-host; do
    vm_running "$role" || continue
    printf '%s:\n' "$role"
    vm_ssh "$role" "ip -brief -4 addr show | grep -v '^lo '" 2>/dev/null | sed 's/^/  /' \
      || echo "  (no ssh)"
  done
}

# ---------------------------------------------------------------------------
# router test: the topology proves itself, before any tool touches it
# ---------------------------------------------------------------------------
# Every rule below is hand-written nft, applied over ssh. That is the point:
# these checks are the yardstick a tool that writes the same rules is measured
# against, so they must hold with no tui binary anywhere near the machine.

rt_rc=0
rt_log=""

rt_say() { echo "$*"; printf '%s\n' "$*" >>"$rt_log"; }

# rt_run runs one command in a guest, echoes its output for the caller to test
# and records the command, the output and the exit status as evidence.
rt_run() {
  local vm="$1"; shift
  local body status=0
  body="$(vm_ssh "$vm" "$@" </dev/null 2>&1)" || status=$?
  {
    echo "\$ [$vm] $*"
    printf '%s\n' "$body" | sed 's/^/  /'
    echo "  (exit $status)"
  } >>"$rt_log"
  printf '%s' "$body"
  return $status
}

rt_verdict() {
  local label="$1" ok="$2"
  if ((ok == 0)); then rt_say "PASS  $label"; else rt_say "FAIL  $label"; rt_rc=1; fi
}

# rt_nft replaces the router's whole ruleset with the one it is given, so each
# stage starts from a ruleset the evidence file spells out in full. The text
# goes in over stdin rather than inside the remote command line: a ruleset is
# full of quotes and braces and nothing survives being quoted twice.
rt_nft() {
  local ruleset="$1" body status=0
  body="$(printf '%s\n' "$ruleset" \
    | vm_ssh router "sudo -n nft flush ruleset && sudo -n nft -f -" 2>&1)" || status=$?
  {
    echo "\$ [router] nft -f - <<'EOF'"
    printf '%s\n' "$ruleset" | sed 's/^/  /'
    echo "  EOF"
    [[ -z $body ]] || printf '%s\n' "$body" | sed 's/^/  /'
    echo "  (exit $status)"
  } >>"$rt_log"
  # A ruleset the router refuses is a failure of the run, not a reason to stop
  # it: the checks that follow report what that ruleset was supposed to do.
  if ((status)); then
    rt_say "FAIL  the router refused the ruleset above"
    rt_rc=1
  fi
  return 0
}

rt_curl() { # rt_curl <vm> <url> — short timeout, so a dropped packet fails fast
  rt_run "$1" "curl -sS --max-time 6 '$2'"
}

cmd_router_test() {
  local via_tool=0 traffic=0 bin=""
  while (($#)); do
    case "$1" in
      --via-tool)
        via_tool=1; shift
        # The path is optional: without one the binary is built from the
        # sibling checkout, whatever branch it happens to be on.
        if [[ ${1:-} && ${1:0:1} != - ]]; then bin="$1"; shift; fi
        ;;
      --traffic) traffic=1; shift ;;
      *) die "router test: unknown option: $1" ;;
    esac
  done
  if ((via_tool)); then cmd_router_test_via_tool "$bin"; return; fi
  if ((traffic)); then cmd_router_test_traffic; return; fi

  local role
  for role in router lan-client wan-host; do
    vm_running "$role" || die "$role is not running (lab.sh router up)"
  done

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local logdir="$out/results/$stamp-router"
  mkdir -p "$logdir"
  rt_log="$logdir/topology.log"
  {
    echo "### router topology — $(date -Is)"
    echo "wan $router_wan_net: router $router_wan_ip, wan-host $wan_host_ip:$wan_host_port"
    echo "lan $router_lan_net: router $router_lan_ip, lan-client $lan_client_ip:$lan_client_port"
  } >"$rt_log"

  local body ok

  # -- 1. the router sits on both segments ----------------------------------
  body="$(rt_run router "ip -brief -4 addr show wan0; ip -brief -4 addr show lan0; sysctl -n net.ipv4.ip_forward")" || true
  ok=1
  grep -q "$router_wan_ip/24" <<<"$body" && grep -q "$router_lan_ip/24" <<<"$body" \
    && [[ $(tail -1 <<<"$body") == 1 ]] && ok=0
  rt_verdict "router has wan0 $router_wan_ip, lan0 $router_lan_ip and forwarding on" "$ok"

  ok=0; rt_run router "ping -c2 -W2 $wan_host_ip >/dev/null && ping -c2 -W2 $lan_client_ip >/dev/null" >/dev/null || ok=1
  rt_verdict "router reaches both networks (wan-host and lan-client answer)" "$ok"

  # -- 2. the client's way out is the router --------------------------------
  body="$(rt_run lan-client "ip -4 route show default; echo ---; ip -4 route get $wan_host_ip")" || true
  ok=1
  if [[ $(grep -c '^default' <<<"$body") == 1 ]] \
    && grep -q "^default via $router_lan_ip" <<<"$body" \
    && grep -q "via $router_lan_ip" <<<"$(sed -n '/^---/,$p' <<<"$body")"; then ok=0; fi
  rt_verdict "lan-client has one default route and it is the router" "$ok"

  ok=0; rt_curl router "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "wan-host serves HTTP on the wan segment" "$ok"

  # -- 3. NAT ---------------------------------------------------------------
  # With an empty ruleset the router still forwards, but wan-host has no route
  # back to the LAN, so nothing returns. That is the honest "before" state.
  rt_run router "sudo -n nft flush ruleset" >/dev/null
  ok=1; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "without masquerade lan-client cannot reach wan-host" "$ok"

  rt_run wan-host "sudo -n truncate -s 0 /var/log/wan-http.log" >/dev/null
  rt_nft "table ip lab {
  chain nat_post {
    type nat hook postrouting priority srcnat; policy accept;
    oifname \"wan0\" ip saddr $router_lan_net counter masquerade
  }
}"
  ok=0; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "with masquerade lan-client reaches wan-host" "$ok"

  body="$(rt_run wan-host "sudo -n cat /var/log/wan-http.log")" || true
  ok=1
  grep -q "^$router_wan_ip " <<<"$body" && ! grep -q "$lan_client_ip" <<<"$body" && ok=0
  rt_verdict "wan-host logged the request from the router's wan address, not the client's" "$ok"

  rt_run router "sudo -n nft flush ruleset" >/dev/null
  ok=1; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "with the masquerade rule removed lan-client is cut off again" "$ok"

  # -- 4. forward filtering and its counters --------------------------------
  rt_nft "table ip lab {
  chain nat_post {
    type nat hook postrouting priority srcnat; policy accept;
    oifname \"wan0\" ip saddr $router_lan_net counter masquerade
  }
  chain filter_fwd {
    type filter hook forward priority filter; policy drop;
  }
}"
  ok=1; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "a forward chain with policy drop stops LAN to WAN traffic" "$ok"

  rt_run router "sudo -n nft add rule ip lab filter_fwd ct state established,related counter accept
sudo -n nft add rule ip lab filter_fwd iifname \"lan0\" oifname \"wan0\" counter accept" >/dev/null
  ok=0; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "the forward rule lets LAN to WAN through" "$ok"

  body="$(rt_run router "sudo -n nft list chain ip lab filter_fwd")" || true
  ok=1
  [[ $(grep 'iifname "lan0"' <<<"$body" | sed -n 's/.*counter packets \([0-9]*\).*/\1/p') -gt 0 ]] && ok=0
  rt_verdict "the forward rule's packet counter moved" "$ok"

  # -- 5. an input rule on the router itself --------------------------------
  rt_nft "table ip lab {
  chain filter_in {
    type filter hook input priority filter; policy accept;
    iifname \"wan0\" ip saddr $wan_host_ip icmp type echo-request counter drop
  }
}"
  ok=1; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=0
  rt_verdict "an input rule blocks wan-host from reaching the router" "$ok"

  rt_run router "sudo -n nft flush ruleset" >/dev/null
  ok=0; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=1
  rt_verdict "removing the input rule lets wan-host reach the router again" "$ok"

  # -- 6. an output rule on the router itself -------------------------------
  rt_nft "table ip lab {
  chain filter_out {
    type filter hook output priority filter; policy accept;
    oifname \"wan0\" ip daddr $wan_host_ip tcp dport $wan_host_port counter reject
  }
}"
  ok=1; rt_curl router "http://$wan_host_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "an output rule blocks the router's own traffic to wan-host" "$ok"

  # -- 7. a named set standing in for an alias ------------------------------
  # nft's named sets are the backend an alias has to compile to: one object,
  # referenced by rules, whose membership changes without rewriting the rule.
  rt_nft "table ip lab {
  set hostile {
    type ipv4_addr
    elements = { $wan_host_ip }
  }
  chain filter_in {
    type filter hook input priority filter; policy accept;
    iifname \"wan0\" ip saddr @hostile counter drop
  }
}"
  ok=1; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=0
  rt_verdict "a rule matching a named set blocks the address in it" "$ok"

  rt_run router "sudo -n nft delete element ip lab hostile { $wan_host_ip }" >/dev/null
  ok=0; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=1
  rt_verdict "updating the set propagates to the rule without touching the rule" "$ok"

  # -- 8. DNAT --------------------------------------------------------------
  rt_run router "sudo -n nft flush ruleset" >/dev/null
  ok=1; rt_curl wan-host "http://$router_wan_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "before the port forward the router's wan address serves nothing" "$ok"

  rt_nft "table ip lab {
  chain nat_pre {
    type nat hook prerouting priority dstnat; policy accept;
    iifname \"wan0\" tcp dport $wan_host_port counter dnat to $lan_client_ip:$lan_client_port
  }
  chain nat_post {
    type nat hook postrouting priority srcnat; policy accept;
    oifname \"wan0\" ip saddr $router_lan_net counter masquerade
  }
}"
  ok=0; rt_curl wan-host "http://$router_wan_ip:$wan_host_port/" | grep -q 'lan-client service' || ok=1
  rt_verdict "the port forward exposes the lan-client service on the router's wan address" "$ok"

  rt_run router "sudo -n nft flush ruleset" >/dev/null
  ok=1; rt_curl wan-host "http://$router_wan_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "removing the port forward closes it again" "$ok"

  # -- 10. per-rule logging reaches the real kernel log (router item 10) -----
  # The live firewall-log view reads the kernel log that nftables' `log`
  # statement writes. A rootless netns never delivers those lines to the
  # kernel, so per-rule logging can only be proven on a real machine — which is
  # exactly what the lab twin is for. Build a working masquerade path whose
  # lan0->wan0 accept rule is logged, cause the traffic it matches, and read
  # the line back off the router's own kernel ring.
  rt_nft "table ip lab {
  chain nat_post {
    type nat hook postrouting priority srcnat; policy accept;
    oifname \"wan0\" ip saddr $router_lan_net counter masquerade
  }
  chain filter_fwd {
    type filter hook forward priority filter; policy drop;
    ct state established,related counter accept
    iifname \"lan0\" oifname \"wan0\" log prefix \"tuilab-fwd \" counter accept
  }
}"
  # Clear the router's kernel ring so the assertion only sees traffic we cause.
  rt_run router "sudo -n dmesg -C 2>/dev/null || true" >/dev/null
  ok=0; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "with the logged forward rule, lan-client still reaches wan-host" "$ok"
  body="$(rt_run router "sudo -n dmesg 2>/dev/null | grep 'tuilab-fwd ' | head -3")" || true
  ok=1; grep -q 'tuilab-fwd ' <<<"$body" && ok=0
  rt_verdict "the logged forward rule reaches the router's kernel log, what the live view reads" "$ok"
  ok=1; grep -qE 'OUT=wan0' <<<"$body" && ok=0
  rt_verdict "the logged kernel line shows the packet leaving on wan0" "$ok"
  rt_run router "sudo -n nft flush ruleset" >/dev/null

  # The router is left as `up` handed it over: forwarding on, ruleset empty.
  rt_run router "sudo -n nft list ruleset" >/dev/null

  echo
  if ((rt_rc)); then rt_say "VERDICT  router topology: FAIL"; else rt_say "VERDICT  router topology: PASS"; fi
  log "evidence: $rt_log"
  return $rt_rc
}

# ---------------------------------------------------------------------------
# The TUI driver: keys in, panes out
# ---------------------------------------------------------------------------
# `router test --via-tool` proves the same things the hand-written rulesets
# above prove, except that every rule is written by a human-shaped sequence of
# key presses into the real tui-firewall running on the router. There is no
# batch or apply flag anywhere in the family, on purpose: a non-interactive
# mutation path would go around the preview-and-confirm dialog that is the
# whole point of these tools. So the lab drives the terminal.
#
# tmux is the pty. The tool runs in a detached session on the guest,
# `send-keys` types into it and `capture-pane` reads the screen back as plain
# text, which is both what the driver makes decisions on and what the run
# records as evidence.
#
# Two details cost time to find:
#
#   * The tools query the terminal for its background colour (OSC 11) at
#     startup and only draw once it has answered or the probe gives up, which
#     is what render-screenshots.py in the kit answers by hand. tmux answers
#     it, so the frame arrives in about a second — but keys sent before it
#     are swallowed by the reader waiting for that answer. Every step here
#     waits for the screen it expects before typing into it, starting with
#     the first frame.
#   * A tmux server started from an ssh command lives inside that login
#     session's scope, and logind takes the scope down when the connection
#     closes. `loginctl enable-linger` is what keeps the server alive between
#     the driver's ssh calls.
tui_vm=""
tui_session="tui-drive"
# Where the binary under test lands in the guest.
tui_bin_path="/tmp/tui-firewall-drive"
tui_shots=""
tui_shot_n=0

# tui_wait_ready waits for the tool to reach its LOADED first frame, not just
# any frame. The footer hint "x actions" is drawn during the loading state too
# (body: "reading the firewall…"), so waiting on it alone fires the first key
# into the OSC-11/loading window, where the reader eats it. Wait for the
# loading body to clear, then let the first real frame settle.
tui_wait_ready() {
  local limit="${1:-45}"
  tui_wait_for "x actions" "$limit" || return 1
  tui_wait_gone "reading the firewall" "$limit"
  sleep 0.5
}

# tui_start launches the tool in a detached tmux session and waits for the
# first drawn frame. The pane is 160x45: the confirm dialog holds a whole nft
# command line and the evidence is worth nothing if the command is truncated.
tui_start() {
  tui_vm="$1"; shift
  local cmd="$*"
  vm_ssh "$tui_vm" "command -v tmux >/dev/null 2>&1 || { sudo -n apt-get update -qq >/dev/null 2>&1; sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux >/dev/null 2>&1; }"
  vm_ssh "$tui_vm" "command -v tmux >/dev/null" || die "tmux could not be installed on $tui_vm"
  vm_ssh "$tui_vm" "sudo -n loginctl enable-linger $lab_user >/dev/null 2>&1 || true"
  vm_ssh "$tui_vm" "tmux kill-session -t $tui_session 2>/dev/null; sleep 1; tmux new-session -d -s $tui_session -x 160 -y 45 '$cmd'; sleep 1; tmux ls" >/dev/null \
    || die "could not start tmux on $tui_vm"
  printf '\n$ [%s] tmux new-session %s\n' "$tui_vm" "$cmd" >>"$rt_log"
}

# tui_stop quits the tool the way a user does and tears the session down.
tui_stop() {
  [[ -n $tui_vm ]] || return 0
  vm_ssh "$tui_vm" "tmux send-keys -t $tui_session q 2>/dev/null; sleep 1; tmux kill-session -t $tui_session 2>/dev/null; true" >/dev/null 2>&1 || true
}

# tui_pane returns what is on the screen right now, as plain text.
tui_pane() {
  vm_ssh "$tui_vm" "tmux capture-pane -p -t $tui_session" 2>/dev/null
}

# tui_shot records the screen as a numbered file under the evidence directory
# and names it in the log. Every confirm dialog goes through here before the
# key that accepts it: the preview is the evidence.
tui_shot() {
  local name="$1" file
  tui_shot_n=$((tui_shot_n + 1))
  file="$(printf '%s/%02d-%s.txt' "$tui_shots" "$tui_shot_n" "$name")"
  tui_pane >"$file"
  {
    echo "--- pane: $name ($(basename "$file"))"
    sed 's/^/  /' "$file"
  } >>"$rt_log"
}

# tui_wait_for polls the pane until it shows a string, and fails the run with
# the screen it was looking at when it does not.
tui_wait_for() {
  local needle="$1" limit="${2:-30}" i pane
  for ((i = 0; i < limit * 2; i++)); do
    pane="$(tui_pane)"
    if [[ $pane == *"$needle"* ]]; then return 0; fi
    sleep 0.5
  done
  tui_shot "stuck-waiting-for-${needle//[^A-Za-z0-9]/-}"
  rt_say "FAIL  the TUI never showed \"$needle\" (pane captured above)"
  rt_rc=1
  return 1
}

# tui_wait_gone is the other half: poll until a string leaves the screen. It
# is how the driver knows a confirmed command finished, because the status
# line says "running …" until it has.
tui_wait_gone() {
  local needle="$1" limit="${2:-30}" i
  for ((i = 0; i < limit * 2; i++)); do
    [[ $(tui_pane) == *"$needle"* ]] || return 0
    sleep 0.5
  done
  return 0
}

# tui_keys sends named keys, one at a time with a beat between them, in one
# round trip. Bubble Tea reads a burst of keys as a burst, and a form that
# moves the cursor on every one of them needs them separated.
tui_keys() {
  vm_ssh "$tui_vm" "for k in $*; do tmux send-keys -t $tui_session \"\$k\"; sleep 0.25; done" >/dev/null
  printf '  keys: %s\n' "$*" >>"$rt_log"
}

# tui_type types literal text. The values this lab types are addresses,
# interface names and alias names; anything with a quote in it would have to
# survive two shells and a tmux argument, and refusing it here is better than
# discovering it in a rule.
tui_type() {
  local text="$1"
  [[ $text =~ ^[A-Za-z0-9@._:/,\ -]*$ ]] || die "tui_type: refusing to type $text"
  vm_ssh "$tui_vm" "tmux send-keys -t $tui_session -l -- '$text'; sleep 0.4" >/dev/null
  printf '  type: %s\n' "$text" >>"$rt_log"
}

# tui_pick chooses an entry in an open picker by its label: home, then down
# until the highlight marker sits on it. Counting key presses would work until
# the day the backend adds an action, and then it would work wrongly.
tui_pick() {
  local label="$1" i pane
  tui_wait_for "$label" 20 || return 1
  tui_keys Home
  for ((i = 0; i < 30; i++)); do
    pane="$(tui_pane)"
    if [[ $pane == *"> $label"* ]]; then
      tui_keys Enter
      return 0
    fi
    tui_keys Down
  done
  tui_shot "stuck-picking-${label//[^A-Za-z0-9]/-}"
  rt_say "FAIL  could not put the picker on \"$label\" (pane captured above)"
  rt_rc=1
  return 1
}

# tui_focus moves the add-rule form to a field by its label, the same way.
tui_focus() {
  local label="$1" i pane
  for ((i = 0; i < 16; i++)); do
    pane="$(tui_pane)"
    if [[ $pane == *"> $label"* ]]; then return 0; fi
    tui_keys Tab
  done
  tui_shot "stuck-on-field-${label//[^A-Za-z0-9]/-}"
  rt_say "FAIL  the form never focused \"$label\" (pane captured above)"
  rt_rc=1
  return 1
}

# tui_confirm captures the confirm dialog, checks that it really is showing a
# command, accepts it and waits for the tool to come back to the table with
# the change applied.
tui_confirm() {
  local name="$1" pane
  tui_wait_for "Command to run:" 20 || return 1
  tui_shot "$name-preview"
  pane="$(tui_pane)"
  tui_keys y
  tui_wait_ready 30 || return 1
  # The status line says "running …" until the command comes back, and the
  # table behind it is only the new one after the reload that follows.
  tui_wait_gone "running " 60
  sleep 1
  tui_shot "$name-after"
  return 0
}

# ---------------------------------------------------------------------------
# router test --via-tool: the proofs, mirrored through the TUI
# ---------------------------------------------------------------------------
# Every network probe below is the one the hand-written run already uses. What
# changes is who wrote the rule: there, a heredoc of nft; here, the add-rule
# form, the actions menu and the policy picker of the real tool.

# rtt_nft reads the tool's own table back, as the check that the keys landed.
rtt_nft() { rt_run router "sudo -n nft list ruleset"; }

cmd_router_test_via_tool() {
  local bin="$1"
  local role
  for role in router lan-client wan-host; do
    vm_running "$role" || die "$role is not running (lab.sh router up)"
  done
  build_tool tui-firewall "$bin"
  bin="$tool_bin"

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local logdir="$out/results/$stamp-router-via-tool"
  tui_shots="$logdir/panes"
  mkdir -p "$tui_shots"
  rt_log="$logdir/via-tool.log"
  rt_rc=0
  {
    echo "### router topology, driven through tui-firewall — $(date -Is)"
    echo "wan $router_wan_net: router $router_wan_ip, wan-host $wan_host_ip:$wan_host_port"
    echo "lan $router_lan_net: router $router_lan_ip, lan-client $lan_client_ip:$lan_client_port"
    echo "binary: $bin"
  } >"$rt_log"

  log "shipping $bin to the router"
  # A path of its own, and unlinked before it is written: `lab.sh test` ships
  # a tui-firewall of its own into this guest, and a binary that is currently
  # running cannot be overwritten in place (ETXTBSY) — but it can be replaced.
  vm_ssh router "rm -f $tui_bin_path"
  vm_scp router "$bin" "$tui_bin_path" >/dev/null
  vm_ssh router "chmod +x $tui_bin_path"
  rt_run router "$tui_bin_path --version" >/dev/null

  # The run starts from the machine `up` hands over: forwarding on, nothing
  # loaded. Everything after this line is written by the TUI.
  rt_run router "sudo -n nft flush ruleset" >/dev/null

  local body ok
  tui_start router "TERM=xterm-256color $tui_bin_path --backend nftables"
  tui_wait_ready 45 || { tui_stop; return 1; }
  tui_shot "01-first-frame"

  # -- 1. the tool builds its own table ------------------------------------
  # An nftables backend that wrote into somebody else's table would be lost at
  # the next reload of whatever owns it, so the tool owns one and creates it
  # from the actions menu. Which makes this the first mutation to mirror.
  tui_keys x
  tui_pick "Create inet tui, the table this tool owns" && tui_confirm "create-table"
  tui_keys x
  tui_pick "Create the input, forward and output chains" && tui_confirm "create-filter-chains"
  tui_keys x
  tui_pick "Create the prerouting and postrouting NAT chains" && tui_confirm "create-nat-chains"

  body="$(rtt_nft)" || true
  ok=1
  grep -q "table inet tui" <<<"$body" \
    && grep -q "hook input" <<<"$body" && grep -q "hook forward" <<<"$body" \
    && grep -q "hook output" <<<"$body" && grep -q "hook prerouting" <<<"$body" \
    && grep -q "hook postrouting" <<<"$body" && ok=0
  rt_verdict "the TUI created table inet tui with its five chains" "$ok"

  # -- 2. an input rule, added and deleted in the TUI (mirrors 12 and 13) ---
  ok=0; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=1
  rt_verdict "before the rule, wan-host reaches the router" "$ok"

  tui_keys v; tui_pick "inet tui / input" || true
  tui_keys a
  tui_wait_for "Add rule" 20 || true
  # Phase 2 gives the form an interface field, so "block wan-host" is scoped
  # to the interface it arrives on — iifname "wan0" ip saddr … drop — the
  # shape a real firewall rule has, not "everything from that address".
  tui_focus "Action" && tui_keys Enter && tui_pick "DENY"
  tui_focus "In iface" && tui_type "wan0"
  tui_focus "From" && tui_type "$wan_host_ip"
  tui_focus "Comment" && tui_type "lab: input proof"
  tui_shot "input-rule-form"
  tui_keys Enter
  tui_confirm "input-rule-add"

  body="$(rtt_nft)" || true
  ok=1; grep -qE "iifname \"wan0\" ip saddr $wan_host_ip .*drop" <<<"$body" && ok=0
  rt_verdict "the rule the form wrote is scoped to wan0, a drop on wan-host's address" "$ok"

  ok=1; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=0
  rt_verdict "a rule added in the TUI blocks wan-host from reaching the router" "$ok"

  tui_keys d
  tui_confirm "input-rule-delete"
  ok=0; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=1
  rt_verdict "deleting that rule in the TUI lets wan-host reach the router again" "$ok"

  # -- 3. an output rule on the router itself (mirrors 14) -----------------
  ok=0; rt_curl router "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "before the rule, the router reaches the service on wan-host" "$ok"

  tui_keys v; tui_pick "inet tui / output" || true
  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "REJECT"
  tui_focus "Out iface" && tui_type "wan0"
  tui_focus "Port(s)" && tui_type "$wan_host_port"
  tui_focus "Protocol" && tui_keys Enter && tui_pick "tcp"
  tui_focus "To" && tui_type "$wan_host_ip"
  tui_focus "Comment" && tui_type "lab: output proof"
  tui_shot "output-rule-form"
  tui_keys Enter
  tui_confirm "output-rule-add"

  body="$(rtt_nft)" || true
  ok=1; grep -qE "oifname \"wan0\" ip daddr $wan_host_ip .*reject" <<<"$body" && ok=0
  rt_verdict "the output rule the form wrote is scoped to wan0, to wan-host's address" "$ok"

  ok=1; rt_curl router "http://$wan_host_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "an output rule added in the TUI blocks the router's own traffic to wan-host" "$ok"

  tui_keys d
  tui_confirm "output-rule-delete"
  ok=0; rt_curl router "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "deleting it lets the router out again" "$ok"

  # -- 3b. an ICMP rule: drop wan-host's pings, added and deleted in the TUI-
  # Phase 1 could not write "stop this host pinging me": the protocol field
  # was tcp or udp only, so the rule had to be "stop this host". Phase 2 adds
  # icmp and an ICMP-type field, so the rule is exactly the ping, scoped to
  # the interface it arrives on, and nothing else the host sends is touched.
  ok=0; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=1
  rt_verdict "before the ICMP rule, wan-host can ping the router" "$ok"

  tui_keys v; tui_pick "inet tui / input" || true
  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "DENY"
  tui_focus "Protocol" && tui_keys Enter && tui_pick "icmp"
  tui_focus "ICMP type" && tui_type "echo-request"
  tui_focus "In iface" && tui_type "wan0"
  tui_focus "From" && tui_type "$wan_host_ip"
  tui_focus "Comment" && tui_type "lab: icmp proof"
  tui_shot "icmp-rule-form"
  tui_keys Enter
  tui_confirm "icmp-rule-add"

  body="$(rtt_nft)" || true
  ok=1; grep -qE "iifname \"wan0\" ip saddr $wan_host_ip .*icmp type echo-request .*drop" <<<"$body" && ok=0
  rt_verdict "the ICMP rule the form wrote drops echo-request from wan-host on wan0" "$ok"

  ok=1; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=0
  rt_verdict "the ICMP rule blocks wan-host's ping to the router" "$ok"

  tui_keys d
  tui_confirm "icmp-rule-delete"
  ok=0; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=1
  rt_verdict "deleting the ICMP rule lets wan-host ping the router again" "$ok"

  # -- 4. masquerade from the actions menu (mirrors 5, 6 and 7) -------------
  ok=1; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "before the masquerade, lan-client cannot reach wan-host" "$ok"

  rt_run wan-host "sudo -n truncate -s 0 /var/log/wan-http.log" >/dev/null
  # Phase 2's masquerade action takes an optional source network, so the rule
  # is scoped to the LAN behind the router — ip saddr <lan> oifname "wan0"
  # masquerade — not "everything leaving the interface".
  tui_keys x
  tui_pick "Masquerade an interface (optionally one source network)" || true
  tui_wait_for "Outgoing interface" 20 && tui_type "wan0" && tui_keys Enter
  tui_wait_for "Source network" 20 && tui_type "$router_lan_net" && tui_keys Enter
  tui_confirm "masquerade"

  body="$(rtt_nft)" || true
  ok=1; grep -qE "ip saddr $router_lan_net oifname \"wan0\" .*masquerade" <<<"$body" && ok=0
  rt_verdict "the masquerade the TUI wrote is scoped to the lan source leaving wan0" "$ok"

  ok=0; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "with the source-scoped masquerade the TUI wrote, lan-client reaches wan-host" "$ok"

  body="$(rt_run wan-host "sudo -n cat /var/log/wan-http.log")" || true
  ok=1
  grep -q "^$router_wan_ip " <<<"$body" && ! grep -q "$lan_client_ip" <<<"$body" && ok=0
  rt_verdict "wan-host logged the router's wan address, not the client's" "$ok"

  # -- 5. forward policy and a forward rule (mirrors 9, 10 and 11) ----------
  tui_keys v; tui_pick "inet tui / forward" || true
  tui_keys p
  tui_pick "routed" || true
  tui_pick "deny" || true
  tui_confirm "forward-policy-drop"

  ok=1; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "the forward policy the TUI set to deny stops LAN to WAN traffic" "$ok"

  # The stateful pair a real router forwards with, which phase 2's conntrack
  # and interface fields finally let the form write: one rule accepts the
  # return traffic of any tracked connection (ct state established,related),
  # and one accepts new connections leaving lan0 for wan0. Not the two
  # stateless address rules phase 1 had to settle for.
  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "ALLOW"
  tui_focus "Conn. state" && tui_keys Enter && tui_pick "established,related"
  tui_focus "Comment" && tui_type "lab: established back"
  tui_shot "forward-rule-stateful-form"
  tui_keys Enter
  tui_confirm "forward-rule-established"

  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "ALLOW"
  tui_focus "In iface" && tui_type "lan0"
  tui_focus "Out iface" && tui_type "wan0"
  tui_focus "Comment" && tui_type "lab: lan new out"
  tui_keys Enter
  tui_confirm "forward-rule-new"

  body="$(rtt_nft)" || true
  ok=1
  grep -q "ct state established,related" <<<"$body" \
    && grep -qE "iifname \"lan0\" oifname \"wan0\" .*accept" <<<"$body" && ok=0
  rt_verdict "the forward rules the TUI wrote are the stateful pair, not two stateless rules" "$ok"

  ok=0; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "the stateful forward rules the TUI wrote let LAN to WAN through" "$ok"

  body="$(rt_run router "sudo -n nft list chain inet tui forward")" || true
  ok=1
  [[ $(grep 'iifname "lan0" oifname "wan0"' <<<"$body" | sed -n 's/.*counter packets \([0-9]*\).*/\1/p') -gt 0 ]] && ok=0
  rt_verdict "the new-connection forward rule's packet counter moved" "$ok"

  tui_keys p
  tui_pick "routed" || true
  tui_pick "allow" || true
  tui_confirm "forward-policy-accept"

  # -- 6. a port forward, added and deleted in the NAT view (mirrors 17-19) -
  ok=1; rt_curl wan-host "http://$router_wan_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "before the port forward, the router's wan address serves nothing" "$ok"

  tui_keys v; tui_pick "NAT" || true
  tui_keys x
  tui_pick "Forward a port to a host behind the router" || true
  tui_wait_for "Incoming interface" 20 && tui_type "wan0" && tui_keys Enter
  tui_pick "tcp" || true
  tui_wait_for "Port on this machine" 20 && tui_type "$wan_host_port" && tui_keys Enter
  tui_wait_for "Host to forward to" 20 && tui_type "$lan_client_ip" && tui_keys Enter
  tui_wait_for "Port on that host" 20 && tui_type "$lan_client_port" && tui_keys Enter
  tui_confirm "port-forward"

  ok=0
  rt_curl wan-host "http://$router_wan_ip:$wan_host_port/" | grep -q 'lan-client service' || ok=1
  rt_verdict "the port forward the TUI wrote exposes lan-client on the router's wan address" "$ok"

  # The NAT view holds the masquerade as well, so the row to delete is picked
  # the way a user picks it: filter down to the forward, then d.
  tui_keys "/"
  tui_type "$lan_client_ip"
  tui_keys Enter
  tui_shot "port-forward-filtered"
  tui_keys d
  tui_confirm "port-forward-delete"
  tui_keys "/" Escape

  ok=1; rt_curl wan-host "http://$router_wan_ip:$wan_host_port/" >/dev/null || ok=0
  rt_verdict "deleting it in the TUI closes the port forward again" "$ok"

  # -- 7. an alias, round trip (mirrors 15 and 16) -------------------------
  tui_keys x
  tui_pick "Create an alias (a named set)" || true
  tui_wait_for "Alias name" 20 && tui_type "hostile" && tui_keys Enter
  tui_pick "ipv4_addr" || true
  tui_pick "yes" || true
  tui_wait_for "Comment" 20 && tui_type "lab: alias proof" && tui_keys Enter
  tui_confirm "alias-create"

  tui_keys x
  tui_pick "Add a member to an alias" || true
  tui_pick "hostile" || true
  tui_wait_for "Member" 20 && tui_type "$wan_host_ip" && tui_keys Enter
  tui_confirm "alias-add-member"

  tui_keys v; tui_pick "inet tui / input" || true
  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "DENY"
  tui_focus "Alias (source)" && tui_keys Enter && tui_pick "@hostile"
  # An inet table holds both address families, so a rule whose only match is
  # an alias has to say which one it means; the form has the field.
  tui_focus "Family" && tui_keys Enter && tui_pick "v4"
  tui_focus "Comment" && tui_type "lab: alias rule"
  tui_shot "alias-rule-form"
  tui_keys Enter
  tui_confirm "alias-rule-add"

  body="$(rtt_nft)" || true
  ok=1; grep -q "@hostile" <<<"$body" && ok=0
  rt_verdict "the rule the TUI wrote matches the alias by name" "$ok"

  ok=1; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=0
  rt_verdict "a rule matching the alias blocks the address in it" "$ok"

  tui_keys x
  tui_pick "Remove a member from an alias" || true
  tui_pick "hostile" || true
  tui_wait_for "Member" 20 && tui_type "$wan_host_ip" && tui_keys Enter
  tui_confirm "alias-remove-member"

  ok=0; rt_run wan-host "ping -c2 -W2 $router_wan_ip" >/dev/null || ok=1
  rt_verdict "emptying the alias in the TUI propagates, without touching the rule" "$ok"

  body="$(rtt_nft)" || true
  ok=1; grep -q "@hostile" <<<"$body" && ok=0
  rt_verdict "the rule that used the alias is still there" "$ok"

  # -- 8. item 16, scenario 1: a staged, atomic, connectivity-safe apply ---
  # Rule by rule, a forward policy of drop set before the accept rules that
  # keep the LAN alive cuts the LAN off in the gap between them. Phase 2 stages
  # the whole set instead: changes are collected, reviewed as one, and applied
  # as a single nft transaction — all of them or none. Start from an empty
  # forward chain with policy accept, so the batch is the only thing that acts.
  tui_keys v; tui_pick "inet tui / forward" || true
  tui_keys d; tui_confirm "forward-clear-1"
  tui_keys d; tui_confirm "forward-clear-2"

  ok=0; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "with the forward chain cleared and policy accept, the LAN still flows" "$ok"

  tui_keys s
  tui_wait_for "staging" 10
  tui_shot "staging-on"

  # A forward policy of drop — staged, not applied.
  tui_keys p
  tui_pick "routed" || true
  tui_pick "deny" || true

  # The accept rules that keep the LAN (and any tracked session) alive — staged.
  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "ALLOW"
  tui_focus "Conn. state" && tui_keys Enter && tui_pick "established,related"
  tui_focus "Comment" && tui_type "lab: staged back"
  tui_keys Enter

  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "ALLOW"
  tui_focus "In iface" && tui_type "lan0"
  tui_focus "Out iface" && tui_type "wan0"
  tui_focus "Comment" && tui_type "lab: staged new out"
  tui_keys Enter

  # Nothing is applied yet: the ruleset still has policy accept and no staged rule.
  body="$(rt_run router "sudo -n nft list chain inet tui forward")" || true
  ok=0
  grep -q "lab: staged" <<<"$body" && ok=1
  grep -q "policy drop" <<<"$body" && ok=1
  rt_verdict "the staged batch is pending, not yet in the ruleset" "$ok"

  # Review the staged set, then apply it atomically. The confirm shows the
  # whole nft transaction — every line that goes to nft's stdin — before the
  # single y that commits it, which is the batch's own preview-and-confirm.
  tui_keys S
  tui_wait_for "Apply" 15
  tui_shot "staging-review"
  tui_keys Enter
  tui_confirm "staged-apply"

  # After the atomic apply the batch awaits a keep; k confirms access is intact.
  tui_wait_for "keep" 15
  tui_shot "staging-awaiting-keep"
  tui_keys k
  tui_wait_gone "awaiting keep" 15
  tui_shot "staging-kept"
  # Let the tool's own reload settle before the next scenario reads the model:
  # a mutation triggers a background `nft` reload, and stepping on it while it
  # runs is what makes the next frame briefly show a stale, empty model.
  sleep 3

  # No half-applied state: the drop policy AND both accept rules are all there.
  body="$(rt_run router "sudo -n nft list chain inet tui forward")" || true
  ok=1
  grep -q "policy drop" <<<"$body" \
    && grep -q "ct state established,related" <<<"$body" \
    && grep -qE "iifname \"lan0\" oifname \"wan0\" .*accept" <<<"$body" && ok=0
  rt_verdict "the batch applied atomically: forward policy drop and both accept rules all landed" "$ok"

  ok=0; rt_curl lan-client "http://$wan_host_ip:$wan_host_port/" | grep -q 'wan-host service' || ok=1
  rt_verdict "traffic still flows after the atomic apply: the keep rules kept the LAN alive" "$ok"

  # -- 9. item 16, scenario 2: apply, never keep, auto-rollback ------------
  # The lockout case: the operator applies a batch and then loses access before
  # confirming. With no keep inside the window, the snapshot taken before the
  # apply is restored on its own — the connectivity-safe half of an OPNsense
  # apply. A visible probe rule is staged so the rollback has something to undo.
  tui_keys v; tui_pick "inet tui / input" || true
  tui_keys R; tui_wait_for "inet tui" 15; sleep 2
  tui_keys s
  tui_wait_for "staging" 10

  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "DENY"
  tui_focus "In iface" && tui_type "wan0"
  tui_focus "From" && tui_type "$wan_host_ip"
  tui_focus "Comment" && tui_type "lab: rollback probe"
  tui_keys Enter

  # The pre-apply ruleset, captured here so the rollback can be checked against
  # exactly what was on the machine the moment before the apply.
  local presnap; presnap="$(rt_run router "sudo -n nft list ruleset")" || true

  tui_keys S
  tui_wait_for "Apply" 15
  tui_shot "rollback-review"
  tui_keys Enter
  tui_confirm "rollback-apply"

  # The change is live while the keep window is open.
  body="$(rtt_nft)" || true
  ok=1; grep -q "lab: rollback probe" <<<"$body" && ok=0
  rt_verdict "the applied batch is live while it waits for a keep" "$ok"
  tui_shot "rollback-awaiting-keep"

  # Do NOT press k. Wait the keep window out and let it revert by itself. The
  # default keep timeout is 60s; poll the ruleset — never wrapping ssh in
  # timeout — until the probe is gone.
  ok=1
  for _ in $(seq 1 40); do
    body="$(rt_run router "sudo -n nft list ruleset")" || true
    grep -q "lab: rollback probe" <<<"$body" || { ok=0; break; }
    sleep 3
  done
  rt_verdict "with no keep in the window, the ruleset auto-rolled back to the snapshot" "$ok"
  tui_shot "rollback-restored"

  # The rollback is a whole-ruleset restore, not a flush to empty: the table and
  # its pre-apply forward rules are back, and only the probe is gone. Compared
  # against the snapshot captured just before the apply.
  body="$(rt_run router "sudo -n nft list ruleset")" || true
  ok=1
  if grep -q "table inet tui" <<<"$body" \
    && grep -q "policy drop" <<<"$body" \
    && grep -qE "iifname \"lan0\" oifname \"wan0\" .*accept" <<<"$body" \
    && ! grep -q "lab: rollback probe" <<<"$body"; then ok=0; fi
  # Corroborate against the captured pre-apply snapshot: the forward rules the
  # snapshot had are the forward rules the restore brought back.
  grep -q "iifname \"lan0\" oifname \"wan0\"" <<<"$presnap" || ok=1
  rt_verdict "the restored snapshot is the pre-apply ruleset, not an empty or half state" "$ok"

  # -- per-rule logging and the live view, through the TUI (router item 10) --
  # The form writes a forward rule, `l` marks it logged, `w` opens the live
  # view. That view reads the kernel log — an nftables feature a real machine
  # has and a rootless demo does not — so this leg is a lab-twin proof. The
  # deterministic end-to-end evidence (a logged packet reaching the kernel log)
  # is the direct phase's item-10 case; here we prove the two TUI surfaces.
  tui_keys v; tui_pick "inet tui / forward" || true
  tui_keys a
  tui_wait_for "Add rule" 20 || true
  tui_focus "Action" && tui_keys Enter && tui_pick "ALLOW"
  tui_focus "In iface" && tui_type "lan0"
  tui_focus "Out iface" && tui_type "wan0"
  tui_focus "Comment" && tui_type "lab: logged forward"
  tui_shot "log-rule-form"
  tui_keys Enter
  tui_confirm "log-rule-add"
  # The just-added rule is selected; `l` toggles per-rule logging on it.
  tui_keys l
  tui_confirm "log-rule-toggle-on"
  body="$(rtt_nft)" || true
  ok=1; grep -qE "iifname \"lan0\" oifname \"wan0\".*log" <<<"$body" && ok=0
  rt_verdict "the TUI's log toggle wrote a log statement onto the forward rule" "$ok"
  # `w` opens the live firewall-log view. The footer is its stable marker; the
  # status line ("live firewall log — …") is transient and an event overwrites
  # it, so key off the footer the view always draws.
  tui_keys w
  ok=1; tui_wait_for "pause/resume" 15 && ok=0
  tui_shot "live-view-open"
  rt_verdict "the TUI opened the live firewall-log view" "$ok"

  # The stream must stay attached to journald, not die on a bad invocation. A
  # rootless demo cannot reach the kernel log, so this only means something on
  # the lab twin: it is the real-machine regression guard for the live view's
  # journalctl call. Give the process a moment to fail if it is going to.
  sleep 2
  pane="$(tui_pane)"
  ok=0
  grep -qE "the live log ended|exit status|unrecognized option" <<<"$pane" && ok=1
  tui_shot "live-view-stream-health"
  rt_verdict "the live firewall-log stream stayed healthy (journalctl attached, no error)" "$ok"

  # Evidence only — whether an event lands in the pane depends on rule order in
  # this chain, so it is a captured pane, not a verdict; the deterministic
  # end-to-end proof (a logged packet reaching the kernel log) is the direct
  # phase's item-10 case.
  rt_run lan-client "for i in \$(seq 1 6); do curl -s -m2 http://$wan_host_ip:$wan_host_port/ >/dev/null 2>&1; sleep 0.3; done" >/dev/null 2>&1 &
  sleep 3
  tui_shot "live-view-after-traffic"
  tui_keys q

  # -- done: leave the machine as `up` handed it over ----------------------
  tui_stop
  rt_run router "sudo -n nft flush ruleset" >/dev/null

  echo
  if ((rt_rc)); then
    rt_say "VERDICT  router topology through the TUI: FAIL"
  else
    rt_say "VERDICT  router topology through the TUI: PASS"
  fi
  log "evidence: $rt_log"
  log "panes: $tui_shots"
  return $rt_rc
}

# ---------------------------------------------------------------------------
# router test --traffic: item 11, read the router's own traffic on real NICs
# ---------------------------------------------------------------------------
# tui-traffic reads /proc/net/dev for per-interface byte rates and conntrack for
# the flows. Both are real-machine facts a rootless demo cannot produce, so this
# is a lab twin: put real forwarded traffic through the router and read it back
# with the tool's own --check JSON.
cmd_router_test_traffic() {
  local role
  for role in router lan-client wan-host; do
    vm_running "$role" || die "$role is not running (lab.sh router up)"
  done
  need go python3

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local logdir="$out/results/$stamp-router-traffic"
  mkdir -p "$logdir"
  rt_log="$logdir/traffic.log"
  rt_rc=0
  { echo "### router traffic on real interfaces — $(date -Is)"; } >"$rt_log"

  build_tool tui-traffic
  local traf_bin="$tool_bin"
  log "shipping tui-traffic to the router"
  vm_ssh router "rm -f /tmp/tui-traffic"
  vm_scp router "$traf_bin" "/tmp/tui-traffic" >/dev/null
  vm_ssh router "chmod +x /tmp/tui-traffic"
  rt_run router "/tmp/tui-traffic --version" >/dev/null

  # A working masquerade path, so lan->wan traffic is actually forwarded and
  # both NICs carry it.
  rt_nft "table ip lab {
  chain nat_post {
    type nat hook postrouting priority srcnat; policy accept;
    oifname \"wan0\" ip saddr $router_lan_net counter masquerade
  }
  chain filter_fwd {
    type filter hook forward priority filter; policy drop;
    ct state established,related counter accept
    iifname \"lan0\" oifname \"wan0\" counter accept
  }
}"
  # tui-traffic reads flows from the conntrack table; without the conntrack
  # userspace tool it falls back to the socket tables, which carry no bytes.
  # Install it and turn on per-connection byte accounting (off by default) —
  # both are the setup a router operator does to get per-flow byte stats, and
  # what the tool's "byte accounting: off" header is telling you to do.
  rt_run router "command -v conntrack >/dev/null 2>&1 || { sudo -n apt-get update -qq >/dev/null 2>&1; sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq conntrack >/dev/null 2>&1; }" >/dev/null || true
  rt_run router "sudo -n sysctl -w net.netfilter.nf_conntrack_acct=1" >/dev/null

  # Sustained lan->wan traffic for a fixed window, so both of --check's samples
  # fall inside active traffic: a burst that finishes before the window reads as
  # a zero rate. Start it, let it ramp, then sample over a 2s window.
  rt_run lan-client "end=\$((SECONDS+16)); while [ \$SECONDS -lt \$end ]; do curl -s -m2 http://$wan_host_ip:$wan_host_port/ >/dev/null 2>&1; done" >/dev/null 2>&1 &
  local loadpid=$!
  sleep 3

  local check ok
  check="$(rt_run router "sudo -n /tmp/tui-traffic --check --interval 2s 2>/dev/null")" || true
  {
    echo "--- tui-traffic --check (truncated) ---"
    printf '%s\n' "$check" | head -60 | sed 's/^/  /'
  } >>"$rt_log"

  ok=1
  grep -q '"name": "wan0"' <<<"$check" && grep -q '"name": "lan0"' <<<"$check" && ok=0
  rt_verdict "tui-traffic --check reports the router's wan0 and lan0 interfaces" "$ok"

  ok="$(printf '%s' "$check" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(1); sys.exit()
rates={x.get("name"):x.get("rxBytesPerSecond",0)+x.get("txBytesPerSecond",0) for x in d.get("interfaces",[])}
print(0 if rates.get("wan0",0)>0 and rates.get("lan0",0)>0 else 1)' 2>/dev/null || echo 1)"
  rt_verdict "tui-traffic measured nonzero byte rates on wan0 and lan0 under load" "$ok"

  # The flow view needs a conntrack read path: the conntrack userspace tool or
  # /proc/net/nf_conntrack. The kernel tracks the flows regardless, but this
  # minimal cloud image ships neither reader unless conntrack-tools is present,
  # and its apt install depends on the boot having had internet. When the path
  # is here, prove the tool reads flows with byte accounting; when it is not,
  # say so and stand on the interface-rate proof rather than failing on a
  # provisioning gap the router profile — not the tool — should close.
  local have_ct
  have_ct="$(rt_run router "command -v conntrack >/dev/null 2>&1 && echo yes || { [ -r /proc/net/nf_conntrack ] && echo yes || echo no; }" 2>/dev/null)"
  if [[ $have_ct == *yes* ]]; then
    ok="$(printf '%s' "$check" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print(1); sys.exit()
c=d.get("connections",{})
print(0 if c.get("source")=="conntrack" and c.get("accounting")=="on" and c.get("total",0)>0 else 1)' 2>/dev/null || echo 1)"
    rt_verdict "tui-traffic reads the flows from conntrack with byte accounting on" "$ok"
  else
    rt_say "SKIP  no conntrack read path on this image (install conntrack-tools); the flow view falls back to socket counts. Interface-rate proof above stands."
  fi

  wait "$loadpid" 2>/dev/null || true
  rt_run router "sudo -n nft flush ruleset" >/dev/null

  echo
  if ((rt_rc)); then rt_say "VERDICT  router traffic on real interfaces: FAIL"; else rt_say "VERDICT  router traffic on real interfaces: PASS"; fi
  log "evidence: $rt_log"
  return $rt_rc
}

cmd_router() {
  # --backend selects qemu (default) or libvirt for the whole router command,
  # wherever it appears; the rest is the subcommand and its own options.
  local sub="" rest=()
  while (($#)); do
    case "$1" in
      --backend) lab_backend="${2:?--backend needs qemu or libvirt}"; shift 2 ;;
      *) if [[ -z $sub ]]; then sub="$1"; else rest+=("$1"); fi; shift ;;
    esac
  done
  [[ $lab_backend == qemu || $lab_backend == libvirt ]] || die "unknown backend: $lab_backend"
  [[ -n $sub ]] || die "router: expected up, down, status or test"
  case "$sub" in
    up) cmd_router_up "${rest[@]}" ;;
    down) cmd_router_down ;;
    status) cmd_router_status ;;
    test) cmd_router_test "${rest[@]}" ;;
    *) die "router: expected up, down, status or test" ;;
  esac
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
# The header block above is the usage text: printed from line 2 until the
# first line that is not a comment, so adding a command to it is enough.
usage() { sed -n '2,${/^#/!q;s/^# \?//;p;}' "${BASH_SOURCE[0]}"; }

omarchy_variant=""
cmd="${1:-}"; shift || true
case "$cmd" in
  up) cmd_up "${1:?distro}" "${@:2}" ;;
  down) cmd_down "${1:?vm}" ;;
  status) cmd_status "$@" ;;
  ssh) name="${1:?vm}"; shift; vm_ssh "$name" "$@" ;;
  wait-ssh) vm_wait_ssh "${1:?vm}" "${2:-600}" ;;
  snapshot) cmd_snapshot "${1:?vm}" "${2:?tag}" ;;
  restore) cmd_restore "${1:?vm}" "${2:?tag}" ;;
  fetch) cmd_fetch "${1:?distro}" ;;
  images) cmd_images ;;
  test) cmd_test "${1:?tool}" "${@:2}" ;;
  report) cmd_report "${1:?tool|all}" "${@:2}" ;;
  router) cmd_router "$@" ;;
  all)
    sub="${1:?up|down|status}"; shift
    case "$sub" in
      up) for d in ubuntu fedora omarchy; do cmd_up "$d" "$@"; done ;;
      down) for d in ubuntu fedora omarchy; do cmd_down "$d"; done ;;
      status) cmd_status ;;
      *) die "all: expected up, down or status" ;;
    esac
    ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
