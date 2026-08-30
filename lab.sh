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
#   lab.sh test <tool> [vm...] [--bin PATH] [--keep]
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
ssh_opts() {
  local name="$1" port; port="$(vm_port "$name")"
  mkdir -p "$control_dir"
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
  ssh "${opts[@]}" "$lab_user@localhost" "$@"
}

vm_scp() {
  local name="$1" src="$2" dst="$3"
  local opts; mapfile -t opts < <(ssh_opts "$name")
  # scp takes -P for the port where ssh takes -p, so the shared list is
  # rewritten rather than reused verbatim.
  opts[0]=-P
  scp "${opts[@]}" "$src" "$lab_user@localhost:$dst"
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
      "$lab_user@localhost" true 2>/dev/null; then
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
#            btrfs data disk; policycoreutils so the SELinux state is
#            inspectable (Fedora Cloud is enforcing out of the box).
#   omarchy  nothing. The image ships the server profile's firewall already,
#            and installing into it would stop testing the shipped machine.
write_seed() {
  local distro="$1" name="$2" dir="$3"
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
runcmd:
  - [bash, -c, "systemctl enable --now firewalld"]
  - [bash, -c, "firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload"]
  - [bash, -c, "mkfs.btrfs -qf /dev/vdb && mkdir -p /srv/data && mount /dev/vdb /srv/data && echo '/dev/vdb /srv/data btrfs defaults 0 0' >> /etc/fstab"]
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
  } >"$dir/user-data"

  if command -v cloud-localds >/dev/null; then
    cloud-localds "$dir/seed.iso" "$dir/user-data" "$dir/meta-data"
  else
    need xorriso
    xorriso -as mkisofs -quiet -V cidata -J -r \
      -o "$dir/seed.iso" "$dir/user-data" "$dir/meta-data" 2>/dev/null
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
  [[ -f $dir/seed.iso ]] || write_seed "$distro" "$name" "$dir"

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
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -monitor unix:"$(vm_mon "$name")",server,nowait \
    -serial file:"$dir/serial.log" \
    -rtc base=utc \
    -daemonize -pidfile "$dir/pid"

  log "started $name (ssh port $port, ${mem}M, ${cpus} cpu)"
  vm_wait_ssh "$name" "${WAIT:-900}"
  # cloud-init's runcmd finishes after sshd is up, so the package prep is still
  # running when the first connection succeeds. Waiting for it here is what
  # makes `up` mean "ready to test".
  log "waiting for cloud-init to finish"
  vm_ssh "$name" "cloud-init status --wait >/dev/null 2>&1 || true; cloud-init status --long 2>&1 | head -3" || true
}

cmd_down() {
  local name="$1"
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

  local smoke="$repo/test/smoke.sh"
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
# dispatch
# ---------------------------------------------------------------------------
usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; }

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
