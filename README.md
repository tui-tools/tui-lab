<!-- markdownlint-disable MD013 -->
# tui-lab

A small, reproducible multi-distro lab for the [tui-tools](https://github.com/tui-tools) family.

The tools in this family drive real system backends: `ufw`, `firewalld`, `systemctl`, `journalctl`, `snapper`. Unit tests cover the parsers against captured output, and `--demo` covers the UI against a fake. Neither answers the question that actually breaks in the field: **does the tool read this machine correctly?**

`tui-lab` answers it. It boots stock cloud images headless under QEMU/KVM, seeds them with cloud-init so each one has the package manager and the backend a real user would have, builds a tool from its sibling checkout, copies the binary in, and runs the tool's own smoke test against the live backend.

It is glue, so it is one bash script.

## The three machines

| VM | Image | Firewall | Snapshots | Notes |
|----|-------|----------|-----------|-------|
| `ubuntu` | Ubuntu 24.04 LTS cloud image | `ufw`, enabled with 22 allowed | `snapper` on a btrfs data disk | **Root is ext4**, so snapper gets `/dev/vdb` |
| `fedora` | Fedora Cloud Base Generic 44 | `firewalld`, installed by the seed | `snapper` on a btrfs data disk, mounted with an SELinux `context=` | **Root is btrfs**; SELinux **enforcing** |
| `omarchy` | [Omarchy Server](https://github.com/edimarlnx/omarchy-server) cloud image | `ufw`, already `limit 22/tcp` | `snapper` ships in the image | Root is btrfs; seeded with **nothing** |

The Omarchy VM installs no packages on purpose. The point of that machine is the image exactly as shipped; adding to it would stop testing the artifact.

### Image facts recorded from the run below

| Distro | File | Root filesystem | SHA-256 |
|--------|------|-----------------|---------|
| Ubuntu 24.04.4 LTS | `noble-server-cloudimg-amd64.img` | **ext4** | `d0fe84bb5f80853425fa6be28e2c106f30104c3cfe8611933f2e65c9b63f0e30` |
| Fedora Linux 44 (Cloud Edition) | `Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2` | **btrfs** | `28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f` |
| Omarchy Server 4.0.1 | `omarchy-server-2026-08-29-x86_64.qcow2` | **btrfs** | `a2748ecc069ee328f56c30a8b813913d259332a181fe7aa3a8138b1b1bffc186` |

Each digest was checked against the checksum document the distro publishes beside the image, which `lab.sh fetch` does on every download. Ubuntu's `noble/current/` symlink moves with each daily respin, so its digest is verified against the `SHA256SUMS` published next to it rather than pinned in the script; Fedora and Omarchy are pinned releases.

Two things worth knowing before you assume otherwise, both found by building this lab:

- **Fedora Cloud Base Generic ships no firewall.** `rpm -q firewalld` reports "not installed" on 44-1.7. The seed installs it.
- **Fedora Cloud Base Generic ships no `script(1)`.** It is split into `util-linux-script`, which the minimised image leaves out. The seed installs it, because the lab renders every TUI frame through a pty.
- **A btrfs volume made under `/srv` inherits `var_t`, and snapper cannot write to it.** Every `snapper create` fails with `IO Error (mkdir failed errno:13 (Permission denied))` and *no AVC is logged*, because auditd is not running in the Cloud image either. The seed mounts the data disk with `context=system_u:object_r:snapperd_data_t:s0` — the label the root filesystem's own `/.snapshots` carries. A `chcon` on `.snapshots` alone did not survive.
- **`cloud-init status --wait` must be run with `sudo`.** `/run/cloud-init/cloud.cfg` is root-only on Fedora Cloud, and the unprivileged call dies on a `PermissionError` inside its own polling loop rather than returning, so `up` hangs on a machine that finished minutes ago.

## Requirements

QEMU/KVM, OVMF, `cloud-localds` or `xorriso`, `socat`, `curl`, `ssh`, and Go for the build step.

```bash
# Fedora
sudo dnf install qemu-kvm edk2-ovmf cloud-utils xorriso socat golang
# Debian / Ubuntu
sudo apt install qemu-system-x86 ovmf cloud-image-utils xorriso socat golang
```

### Resource footprint

Each VM defaults to **2 GB RAM, 2 vCPUs, a 20 GB thin disk and a 4 GB data disk**. All three together need about **6 GB of RAM** while running. On disk after a full run: **4.5 GB of VM state** (ubuntu 2.3 GB, omarchy 1.4 GB, fedora 0.9 GB — thin qcow2, so far below the 20 GB they advertise) plus a **2.3 GB image cache** (Ubuntu 0.6 GB, Fedora 0.6 GB, Omarchy 1.2 GB). Call it **7 GB and 6 GB of RAM** for the full lab.

The Omarchy image declares a virtual size larger than the 20 GB default, so `--disk` only ever grows a disk and leaves that one at its own size.

A first `lab.sh all up` on a cold cache takes a few minutes, most of it downloading. Afterwards a VM boots and finishes cloud-init in well under two minutes.

## Using it

```bash
./lab.sh all up                  # fetch, create and boot all three
./lab.sh up fedora --mem 4096    # one VM, more memory
./lab.sh up omarchy --selinux    # the SELinux variant of the Omarchy image
./lab.sh status
./lab.sh ssh ubuntu              # interactive shell
./lab.sh ssh ubuntu 'ufw status' # one command
./lab.sh test tui-firewall       # build, ship and test on all three
./lab.sh test tui-systemd fedora # one VM
./lab.sh test tui-snapper --bin /path/to/binary   # skip the build
./lab.sh snapshot ubuntu clean   # qcow2 snapshot (VM must be stopped)
./lab.sh restore ubuntu clean
./lab.sh all down
./lab.sh images                  # what is in the cache, with digests
```

`lab.sh test <tool>` looks for the tool's checkout as a **sibling directory** of `tui-lab` and runs `go build ./cmd/<tool>` with `CGO_ENABLED=0`, so one static binary runs on every guest regardless of its libc. Everything the lab writes — the image cache, the VM disks, the lab-only ssh key, the test logs — lives under `out/`, which is gitignored.

### Two things not to change

The lab inherits two hard-won rules from the Omarchy lab it grew out of:

- **ssh is never wrapped in `timeout`.** Killing ssh mid-handshake wedges QEMU's user-mode `hostfwd` listener for the rest of the VM's life. `wait-ssh` polls with `ConnectTimeout` instead.
- **ssh uses `ControlMaster` multiplexing, and `wait-ssh` polls every 10 seconds.** The Omarchy profile ships `ufw limit 22/tcp`, which drops the seventh connection from one source inside thirty seconds. A test that opens a connection per command rate-limits itself out, and a 5-second poll sits exactly on the threshold — the machine comes up and the poll locks itself out just as it does.

## How a tool joins the lab

Add one executable file to the tool's repository:

```text
<tool-repo>/test/smoke.sh
```

The contract:

- It runs **inside the guest**, as the unprivileged `lab` user.
- The binary under test is at **`$TUI_LAB_BIN`** (fall back to the tool's name on `PATH`).
- It escalates with **`sudo -n`** only. It never prompts.
- It prints a short **`PASS`/`FAIL` table** on stdout.
- It **exits non-zero** if anything failed.
- It tests the **real backend**, not the demo. The lab already covers the demo.

Around it, the lab runs three checks that need no cooperation from the tool:

1. `--version` — the binary starts on this guest at all.
2. A rendered `--demo` frame, driven through a pty with `script -qec`. The 25-second budget is for the OSC 11 background-colour query the theme layer sends at startup, which only resolves when the terminal answers or the probe gives up — plus a cold page cache on the just-copied binary.
3. The tool's `test/smoke.sh`, when it ships one.

A tool with no `test/smoke.sh` still gets checks 1 and 2, reported as `SKIP smoke`.

### Compatibility results come back in the log

A smoke test may also print one line per run behind a `compat-result:` prefix:

```text
compat-result: {"backend":"ufw","date":"2026-08-30","distro":"ubuntu-24.04","result":"pass","suite":"smoke","tool":"tui-firewall","version":"0.36.2"}
```

The version in it is the one the **tool itself probed** on that guest, not one the tester assumed, and the distro is `$(. /etc/os-release; echo $ID-$VERSION_ID)`. The lab needs to know nothing about this: the line rides out in the per-VM log under `out/results/`, and back in the tool's repository `make compat` harvests those logs into `compat/results.jsonl` and regenerates the tested-version list in `tool.json`. That is where a tool's compatibility claims come from — a run on a real machine, not an assertion in a README. See [tui-kit/docs/compatibility.md](https://github.com/tui-tools/tui-kit/blob/main/docs/compatibility.md).

### `--check`, the non-interactive read path

A TUI has nothing a test can assert on. `tui-firewall`, `tui-systemd` and `tui-snapper` therefore grew a `--check` flag: it runs the backend's **real read path**, prints the parsed model as JSON, and exits 0 or 1. It never builds and never runs a mutation, so it is safe anywhere.

```console
$ tui-systemd --check | head -8
{
  "tool": "tui-systemd",
  "version": "dev",
  "backend": "systemd",
  "describe": "systemctl via /usr/bin/sudo -n",
  "units": 543,
  "active": 272,
  "failed": 0,
```

That is what makes assertions like "the tool's active-unit count equals `systemctl`'s" possible — which is the assertion that actually catches a parser regression, because a tool that fetched the output but failed to parse it reports zero.

## Results from a real run

Fedora host, KVM, three VMs at the defaults, `2026-08-29`.

```bash
./lab.sh all up
./lab.sh test tui-firewall
./lab.sh test tui-systemd
./lab.sh test tui-snapper
./lab.sh all down
```

| Tool | ubuntu | fedora | omarchy |
|------|--------|--------|---------|
| **tui-firewall** | version, demo frame, smoke **5/5** | version, demo frame, smoke **3/3** | version, demo frame, smoke **5/5** |
| **tui-systemd** | version, demo frame, smoke **9/9** | version, demo frame, smoke **9/9** | version, demo frame, smoke **9/9** |
| **tui-snapper** | version, demo frame, smoke **15/15** | version, demo frame, smoke **15/15** | version, demo frame, smoke **17/17** |

Backend coverage behind those numbers:

| | ubuntu | fedora | omarchy |
|---|---|---|---|
| tui-firewall backend | `ufw` (real) | `firewalld` (**stub**) | `ufw` (real) |
| rules parsed | 2, matching `ufw status numbered` | — | 2, matching `ufw status numbered` |
| tui-firewall backend version | `ufw 0.36.2` | — | `ufw 0.36.2` |
| tui-systemd backend version | `systemd 255` | `systemd 259` | `systemd 261` |
| tui-systemd units parsed | 543 | 497 | 478 |
| active units | 271, matching `systemctl` | 217, matching `systemctl` | 203, matching `systemctl` |
| journal read | `ModemManager.service` | `NetworkManager-wait-online.service` | `cloud-config.service` |
| tui-snapper config | `data` on `/srv/data` | `data` on `/srv/data` | `root` on `/` |
| rollback mechanism | `unsupported` (not the root fs) | `unsupported` (not the root fs) | `boot-menu`, from `/boot/limine.conf` |
| boot entries parsed | — | — | 5, matching the `///` nodes in `limine.conf` |

### Omarchy and `tui-snapper`

The Omarchy VM is the only machine in the lab that rolls back from the boot menu, so it is the only one where the limine half of `tui-snapper` is exercised at all. The smoke test creates a snapshot with `snapper`, runs `limine-snapper-sync`, and then asserts that the tool's boot-entry count equals the number of snapshot nodes in the generated `/boot/limine.conf` and that the new snapshot's number is among them.

That run found a real bug on the first attempt. `/boot` is the mounted ESP, **mode 0700 and owned by root**, so an unprivileged `tui-snapper` could not open `limine.conf` at all: it reported a machine with a full boot menu as having none, and named the wrong rollback mechanism as a result. Every unit test had passed, because a fixture on disk is readable. The tool now escalates that read the same way it escalates its snapper calls.

The same run also corrected the tool's fixtures. `limine-snapper-sync` on Omarchy Server 4.0.1 titles its entries `4 │ 2026-08-29 21:27:27` — the snapshot number, a U+2502 separator, then the timestamp — where the reconstruction had assumed the timestamp alone. The captured file now lives in `tui-snapper/internal/snapper/testdata/limine-omarchy-server.conf`.

### Fedora and `tui-firewall`

`tui-firewall`'s `firewalld` backend is a documented stub today: `internal/firewalld` satisfies the interface and every operation returns `ErrNotImplemented`. On the Fedora VM the smoke test therefore asserts the **failure**, in three parts:

1. `--backend firewalld --check` exits non-zero and says "not implemented yet".
2. Auto-detection finds firewalld and surfaces the same stub error, rather than claiming the machine has no firewall.
3. `firewalld` really is `active` on that machine — so the stub is the tool's limitation, not an absent backend.

The day someone implements the backend, that test turns red and gets rewritten. That is the point: the gap is asserted, not skipped.

## License

MIT. See [LICENSE](LICENSE).
