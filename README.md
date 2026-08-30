<!-- markdownlint-disable MD013 -->
# tui-lab

A small, reproducible multi-distro lab for the [tui-tools](https://github.com/tui-tools) family.

The tools in this family drive real system backends: `ufw`, `firewalld`, `systemctl`, `journalctl`, `snapper`, `networkctl`. Unit tests cover the parsers against captured output, and `--demo` covers the UI against a fake. Neither answers the question that actually breaks in the field: **does the tool read this machine correctly?**

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
./lab.sh test tui-network
./lab.sh test tui-secure
./lab.sh test tui-users
./lab.sh test tui-ssh
./lab.sh test tui-disk
./lab.sh test tui-update
./lab.sh all down
```

| Tool | ubuntu | fedora | omarchy |
|------|--------|--------|---------|
| **tui-firewall** | version, demo frame, smoke **5/5** | version, demo frame, smoke **3/3** | version, demo frame, smoke **5/5** |
| **tui-systemd** | version, demo frame, smoke **9/9** | version, demo frame, smoke **9/9** | version, demo frame, smoke **9/9** |
| **tui-snapper** | version, demo frame, smoke **15/15** | version, demo frame, smoke **15/15** | version, demo frame, smoke **17/17** |
| **tui-network** | version, demo frame, smoke **10/10** | version, demo frame, smoke **10/10** | version, demo frame, smoke **10/10** |
| **tui-secure** | version, demo frame, smoke **21/21** | version, demo frame, smoke **21/21** | version, demo frame, smoke **22/22** |
| **tui-users** | version, demo frame, smoke **21/21** | version, demo frame, smoke **21/21** | version, demo frame, smoke **21/21** |
| **tui-ssh** | version, demo frame, smoke **12/12** | version, demo frame, smoke **12/12** | version, demo frame, smoke **12/12** |
| **tui-disk** | version, demo frame, smoke **13/13** | version, demo frame, smoke **12/12** | version, demo frame, smoke **12/12** |
| **tui-update** | version, demo frame, smoke **11/11** | version, demo frame, smoke **10/10** | version, demo frame, smoke **2/12** — see below |

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
| tui-network manager | `systemd-networkd` | **NetworkManager** | `systemd-networkd` |
| tui-network backend version | `systemd 255` | `systemd 259` | `systemd 261` |
| links parsed | 2, matching `networkctl list` | 2, matching `networkctl list` | 2, matching `networkctl list` |
| routes parsed | 4, matching `ip -j route` | 2, matching `ip -j route` | 4, matching `ip -j route` |
| managed links | 1 | **0**, every link read-only | 1 |
| `.network` file of the managed link | `/run/systemd/network/10-netplan-enp0s4.network` | — | `/etc/systemd/network/20-wired.network` |
| tui-secure MAC layer | AppArmor | SELinux | none (probe answers `unknown`) |
| tui-secure firewall / updates | `ufw` / `debian` | `firewalld` / `fedora` | `ufw` / `arch` |
| tui-secure backend versions | ufw 0.36.2, OpenSSH 9.6, systemd 255 | firewalld 2.4.4, OpenSSH 10.2, systemd 259 | ufw 0.36.2, OpenSSH 10.5, systemd 261 |
| tui-users accounts / groups | 33 / 62, matching `getent` | 26 / 47, matching `getent` | 20 / 53, matching `getent` |
| `ALL` lines in `/etc/sudoers` | 3 | 3 | 1 |
| tui-users key read | fingerprint matches `ssh-keygen -lf`, through `sudo -n` | same | same |
| tui-ssh unit | `ssh` | `sshd` | `sshd` |
| `sshd -T` casing | lower (`permitrootlogin`) | lower (`permitrootlogin`) | **canonical** (`PermitRootLogin`) |
| `PermitRootLogin`, matching `sshd -T` | `without-password` | `prohibit-password` | `no` |
| tui-disk root filesystem | **ext4** | btrfs | btrfs |
| btrfs section covers | `/srv/data`, **not** the root | `/` | `/` |
| devices parsed | 7, matching `lsblk` | 7, matching `lsblk` | 6, matching `lsblk` |
| tui-disk backend versions | util-linux 2.39.3, btrfs-progs 6.6.3 | util-linux 2.41.5, btrfs-progs 6.19.1 | util-linux 2.42.2, btrfs-progs 7.1 |
| SMART | none: virtio disks carry none, and no guest has smartmontools | same | same |

### Omarchy and `tui-snapper`

The Omarchy VM is the only machine in the lab that rolls back from the boot menu, so it is the only one where the limine half of `tui-snapper` is exercised at all. The smoke test creates a snapshot with `snapper`, runs `limine-snapper-sync`, and then asserts that the tool's boot-entry count equals the number of snapshot nodes in the generated `/boot/limine.conf` and that the new snapshot's number is among them.

That run found a real bug on the first attempt. `/boot` is the mounted ESP, **mode 0700 and owned by root**, so an unprivileged `tui-snapper` could not open `limine.conf` at all: it reported a machine with a full boot menu as having none, and named the wrong rollback mechanism as a result. Every unit test had passed, because a fixture on disk is readable. The tool now escalates that read the same way it escalates its snapper calls.

The same run also corrected the tool's fixtures. `limine-snapper-sync` on Omarchy Server 4.0.1 titles its entries `4 │ 2026-08-29 21:27:27` — the snapshot number, a U+2502 separator, then the timestamp — where the reconstruction had assumed the timestamp alone. The captured file now lives in `tui-snapper/internal/snapper/testdata/limine-omarchy-server.conf`.

### Ubuntu and `tui-network`

The Ubuntu VM is the only machine in the lab configured by **netplan**, and that is what made it worth running. netplan does not write `.network` files where a user would; it renders them into `/run/systemd/network` as **mode 0640, owned `root:systemd-network`**. So the one file that configures the machine's only managed link is the one file an unprivileged `tui-network` cannot open.

The tool listed the seven world-readable templates systemd ships in `/usr/lib/systemd/network` and silently dropped that one — a non-zero count of `.network` files, none of them the file the editor exists to edit. The first smoke test passed anyway, because it only asked whether *a* file was found. It now asks `networkctl` which file configures the managed link and demands that exact path back, plus its contents; and the tool escalates the read with `sudo -n cat` when the plain read hits `EACCES`, the same fallback `tui-snapper` grew for `/boot`.

The run also gave the tool its first fixtures captured from real machines, one per systemd generation, with QEMU's addresses rewritten into the documentation ranges. They are not the same shape: **systemd 261** adds a top-level `Routes` array, an `AddressString`/`DestinationString` rendering beside every byte array, and a fully decoded DHCP `Message` inside the lease, where **systemd 255** has none of them. Both now live in `tui-network/internal/networkd/testdata/networkctl-{list,status}-systemd{255,261}.json`.

### Fedora and `tui-firewall`

`tui-firewall`'s `firewalld` backend is a documented stub today: `internal/firewalld` satisfies the interface and every operation returns `ErrNotImplemented`. On the Fedora VM the smoke test therefore asserts the **failure**, in three parts:

1. `--backend firewalld --check` exits non-zero and says "not implemented yet".
2. Auto-detection finds firewalld and surfaces the same stub error, rather than claiming the machine has no firewall.
3. `firewalld` really is `active` on that machine — so the stub is the tool's limitation, not an absent backend.

The day someone implements the backend, that test turns red and gets rewritten. That is the point: the gap is asserted, not skipped.

### The privileged reads, run for real for the first time

`tui-secure`, `tui-users`, `tui-ssh` and `tui-disk` joined the lab together, and they are the first tools whose escalated branches — `sshd -T`, `getent shadow`, `sudo -l`, another account's `authorized_keys` — had ever run against a live backend rather than a fixture. Every guest gives `lab` passwordless `sudo -n`, so all of them executed.

`tui-secure` passed on all three machines unchanged: every one of its eight probes answered, the MAC layer came back as AppArmor on Ubuntu and SELinux on Fedora, and on Omarchy — which ships neither — the probe reported `unknown` rather than a silent ok. No password hash reached the report on any of them.

The other three each had a bug, and in all three cases the bug was in the **test**, which is its own lesson: a smoke test that has only ever been read is as unproven as the code it covers.

- **`tui-users`** wrote an invented ed25519 blob into `authorized_keys` and asked `ssh-keygen` to fingerprint the file. `ssh-keygen` refuses a file containing a key it cannot decode, so the check failed on all three guests and told us nothing about the tool. Worse, it had been aimed at `ssh-keygen` rather than at `tui-users`, and could not have been aimed at the tool: authorized keys, sudo rules and aging are read by the backend's *detail* path, which only the UI ever called. `--check` grew a `--user <name>` flag, and the test now demands back the exact fingerprint `ssh-keygen` computes for a real key it just generated — which proves the escalated read of a mode 600 file inside somebody else's mode 700 directory, and the parse.

- **`tui-ssh`** met a change in `sshd` itself. **OpenSSH 10.5** prints `sshd -T` in the canonical spelling — `PermitRootLogin no` — where **9.6 and 10.2** lower-case every keyword. The tool canonicalises and parsed all three correctly; the smoke test's `sed` on a lowercase keyword found nothing on Omarchy, so it *skipped* its own strongest assertion on the one machine in the lab that keeps root out entirely, and reported a pass. A real `sshd -T` from 10.5 is now a fixture in `tui-ssh/internal/openssh/testdata/sshd-T-openssh105.txt`.

- **`tui-disk`** had a whole branch that had never executed. Ubuntu is the only guest whose root is **ext4** with btrfs mounted somewhere else, which is exactly the case that proves the btrfs section follows the filesystem and not the root — and the branch for it looked for that filesystem at `/mnt/btrfs`, which nothing mounts. The lab puts the data disk on `/srv/data`. The test now asks `findmnt` where btrfs is, and Ubuntu went from 8 checks to 13.

### Omarchy and `tui-update`

`tui-update` is the one tool the lab currently fails, and it fails on the machine it most needs to work on. Omarchy Server 4.0.1 ships `checkupdates` — it comes with `pacman-contrib` — but **not `fakeroot`**, which `checkupdates` needs to build its temporary database. So:

```console
$ tui-update --check
tui-update: pacman read failed: `/usr/bin/sudo -n checkupdates` failed:
==> ERROR: Cannot find the fakeroot binary
```

`--check` exits 1 and the whole report is empty, which takes ten of the twelve assertions down with it — the pending count, the restart class, the snapshot support the machine really does have, the pacman log. Only `--version` and the `--demo` frame pass.

Nothing about that is the lab's doing: it is the shipped image, unmodified, which is the entire point of the Omarchy VM. Either `checkupdates` needs a fallback for a machine without `fakeroot`, or the read needs to degrade to a reported reason instead of failing the whole model — a machine whose update count cannot be determined still has a snapshot configuration, a timer and a history worth showing. That is `tui-update`'s call to make; the lab's job was to find it, and the result is recorded here rather than smoothed over.

Ubuntu (apt 2.8.3) and Fedora (dnf 5.4.1) pass 11/11 and 10/10. Fedora skips one: `needs-restarting` lives in `dnf-plugins-core`, which the Cloud image leaves out.

One gap the lab cannot close: **no guest has SMART**. Every disk is virtio, none of the three images ships `smartmontools`, so `tui-disk`'s health read is asserted only in its absence — each drive must come back `unknown` *with a reason*, which is at least distinguishable from a read the tool forgot to make.

## License

MIT. See [LICENSE](LICENSE).
