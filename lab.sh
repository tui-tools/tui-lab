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
#            btrfs data disk, mounted with an SELinux context because Fedora
#            Cloud is enforcing out of the box; policycoreutils so the SELinux
#            state is inspectable; cronie, so that one machine in the lab is a
#            `crond.service` machine — the other half of tui-cron's unit-name
#            detection, which nothing here exercised before.
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
  # `sudo -n`, and not a bare call: on Fedora Cloud /run/cloud-init/cloud.cfg
  # is root-only, so an unprivileged `cloud-init status --wait` dies on a
  # PermissionError inside its own polling loop and never returns — `up` then
  # hangs on a machine that finished minutes ago.
  log "waiting for cloud-init to finish"
  vm_ssh "$name" "sudo -n cloud-init status --wait >/dev/null 2>&1 || true; sudo -n cloud-init status --long 2>&1 | head -3" || true
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
