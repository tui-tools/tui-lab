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
| `fedora` | Fedora Cloud Base Generic 44 | `firewalld`, installed by the seed | `snapper` on a btrfs data disk, mounted with an SELinux `context=` | **Root is btrfs**; SELinux **enforcing**; `cronie`, so the lab has one `crond.service` machine |
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
- **Fedora Cloud Base Generic ships no cron**, neither `cron` nor `cronie`. That left the lab with no machine whose cron daemon is called `crond` — Ubuntu's is `cron.service` and Omarchy has none — so half of `tui-cron`'s unit-name detection was covered only by fixtures. The seed installs `cronie` and enables `crond`, which the package does not do for you.
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
./lab.sh report tui-firewall     # check the --report block on all three
./lab.sh report tui-secure fedora # one VM
./lab.sh report all              # every sibling tool checkout
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

### `lab.sh report`, the block checked where it has something to leak

Every tool answers `--report` with the plain `key: value` block a bug report is pasted from. That makes it two things at once: the first thing a maintainer reads, and a privacy promise — the block goes into a public issue, so a home path, a user name or the machine's own host name appearing in it is a bug rather than a cosmetic detail.

The promise is the half a unit test cannot check. A fixture has no host name to leak. A guest does, and it is a guest, so `report` runs the real block on each of the three:

```console
$ ./lab.sh report tui-firewall omarchy

==> === tui-firewall --report on omarchy ===
--- tui-firewall --report (live) on omarchy
    tui-firewall dev (kit v0.2.9)
    backend: ufw 0.36.2
    mode: live
    distro: omarchy-server 4.0.1 (Omarchy Server 4.0.1)
    kernel: 7.1.11-arch1-1
    ...
PASS  live exits 0
PASS  live headline names tui-firewall
PASS  live names neither this machine, its user nor a home path
...
VERDICT  tui-firewall --report on omarchy: PASS
```

It builds and ships the binary exactly the way `test` does, prints both blocks the tool can produce — live and under `--demo` — and asserts four things about each:

1. It **exits 0**.
2. Its **first line names the tool**. A block pasted into the wrong repository should say so in the line the maintainer reads first.
3. It **names nothing about this machine**: not the guest's host name, not a path under `/home` or `/root`, not the lab user's name. The `distro` and `kernel` lines are excluded from the host-name search rather than from the promise — they are built from `/etc/os-release` and from `uname`'s release and machine fields, never from its nodename, and every guest here is named after its distribution, so `fedora` belongs in both of them.
4. The `--demo` block says **`backend: demo`**. A demo block that does not announce itself is the worst kind of bug report: every number in it is sample data and nothing says so.

A failed assertion shows the offending line and fails the command, so it fits a pre-release check. `report all` does the same for every sibling checkout that has a `cmd/<name>` package.

## Results from a real run

Fedora host, KVM, three VMs at the defaults. **Every Fedora figure below was taken on `2026-08-30`**, in one sweep of all fourteen tools against the VM rebuilt from the seed with `cronie` — the caveat that used to sit here, about Fedora numbers measured before that rebuild and never re-taken, is gone. `tui-firewall`, `tui-samba` and `tui-containers` were run on all three guests the same day; the ubuntu and omarchy columns for the other eleven are from `2026-08-29` and are unchanged.

Two packages were installed on the Fedora guest by hand for this sweep, `samba` and nothing else — `podman` was already there — so that `tui-samba`'s present branch would run against a real `smbd` once rather than never. That is why Fedora's group count moved from 47 to 48. The VM is disposable and was left as it is.

```bash
./lab.sh all up
./lab.sh test tui-firewall
./lab.sh test tui-samba
./lab.sh test tui-containers
for tool in tui-systemd tui-snapper tui-network tui-secure tui-users \
            tui-ssh tui-disk tui-update tui-logs tui-cron tui-cert; do
  ./lab.sh test "$tool" fedora
done
./lab.sh all down
```

| Tool | ubuntu | fedora | omarchy |
|------|--------|--------|---------|
| **tui-firewall** | version, demo frame, smoke **5/5** | version, demo frame, smoke **14/14** — see below | version, demo frame, smoke **5/5** |
| **tui-systemd** | version, demo frame, smoke **9/9** | version, demo frame, smoke **9/9** | version, demo frame, smoke **9/9** |
| **tui-snapper** | version, demo frame, smoke **15/15** | version, demo frame, smoke **16/16** | version, demo frame, smoke **17/17** |
| **tui-network** | version, demo frame, smoke **10/10** | version, demo frame, smoke **10/10** | version, demo frame, smoke **10/10** |
| **tui-secure** | version, demo frame, smoke **21/21** | version, demo frame, smoke **21/21** | version, demo frame, smoke **22/22** |
| **tui-users** | version, demo frame, smoke **21/21** | version, demo frame, smoke **21/21** | version, demo frame, smoke **21/21** |
| **tui-ssh** | version, demo frame, smoke **12/12** | version, demo frame, smoke **12/12** | version, demo frame, smoke **12/12** |
| **tui-disk** | version, demo frame, smoke **13/13** | version, demo frame, smoke **12/12** | version, demo frame, smoke **12/12** |
| **tui-update** | version, demo frame, smoke **12/12** | version, demo frame, smoke **11/11** | version, demo frame, smoke **13/13** — see below |
| **tui-logs** | version, demo frame, smoke **14/14** | version, demo frame, smoke **14/14** | version, demo frame, smoke **14/14** |
| **tui-cron** | version, demo frame, smoke **18/18** | version, demo frame, smoke **18/18** | version, demo frame, smoke **19/19** — see below |
| **tui-cert** | version, demo frame, smoke **22/22** | version, demo frame, smoke **22/22** | version, demo frame, smoke **22/22** |
| **tui-samba** | version, demo frame, smoke **18/18** | version, demo frame, smoke **21/21** — see below | version, demo frame, smoke **18/18** |
| **tui-containers** | version, demo frame, smoke **15/15** | version, demo frame, smoke **13/13** | version, demo frame, smoke **15/15** — see below |

Backend coverage behind those numbers:

| | ubuntu | fedora | omarchy |
|---|---|---|---|
| tui-firewall backend | `ufw` (real) | `firewalld` (**real**) | `ufw` (real) |
| rules parsed | 2, matching `ufw status numbered` | `public` zone: `ssh` service, `target: default` | 2, matching `ufw status numbered` |
| tui-firewall backend version | `ufw 0.36.2` | `firewalld 2.4.4` | `ufw 0.36.2` |
| tui-firewall mutation exercised | — | `65530/tcp` added and removed through the tool, runtime only | — |
| tui-systemd backend version | `systemd 255` | `systemd 259` | `systemd 261` |
| tui-systemd units parsed | 543 | 505 | 478 |
| active units | 271, matching `systemctl` | 215, matching `systemctl` | 203, matching `systemctl` |
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
| tui-users accounts / groups | 33 / 62, matching `getent` | 26 / 48, matching `getent` | 20 / 53, matching `getent` |
| `ALL` lines in `/etc/sudoers` | 3 | 3 | 1 |
| tui-users key read | fingerprint matches `ssh-keygen -lf`, through `sudo -n` | same | same |
| tui-ssh unit | `ssh` | `sshd` | `sshd` |
| `sshd -T` casing | lower (`permitrootlogin`) | lower (`permitrootlogin`) | **canonical** (`PermitRootLogin`) |
| `PermitRootLogin`, matching `sshd -T` | `without-password` | `prohibit-password` | `no` |
| tui-disk root filesystem | **ext4** | btrfs | btrfs |
| btrfs section covers | `/srv/data`, **not** the root | `/` | `/` |
| devices parsed | 7, matching `lsblk` | 7, matching `lsblk` | 6, matching `lsblk` |
| tui-disk backend versions | util-linux 2.39.3, btrfs-progs 6.6.3 | util-linux 2.41.5, btrfs-progs 6.19.1 | util-linux 2.42.2, btrfs-progs 7.1 |
| tui-update manager | `apt` | `dnf` | `pacman` |
| tui-update backend version | apt 2.8.3 | dnf 5.4.1 | pacman 7.1.0 |
| pending list read with | `apt list --upgradable` | `dnf check-update` | **`pacman -Qu`** (no `fakeroot`) |
| pending count | 12, matching apt | 181, matching dnf | 0, matching pacman |
| restart classifier | `needrestart` | `needs-restarting` (**absent**) | `omarchy-server-update-restart` |
| snapshot before upgrade | none (no snapper root config) | none (no snapper root config) | `snapper` config `root` |
| unattended-update unit | `apt-daily-upgrade.timer`, enabled | `dnf-automatic.timer`, **not-found** | `omarchy-server-update.timer`, disabled |
| SMART | none: virtio disks carry none, and no guest has smartmontools | same | same |
| tui-logs backend version | `systemd 255` | `systemd 259` | `systemd 261` |
| system journal opened as `lab` | yes, through `wheel`/`adm` | yes | yes |
| boots parsed | 8, matching `--list-boots` | 2, matching `--list-boots` | 8, matching `--list-boots` |
| `--list-boots -o json` shape | identical on all three: `index`, `boot_id`, `first_entry`, `last_entry` | same | same |
| journal storage | persistent (`/var/log/journal`) | persistent | persistent |
| errors in the last hour | 0, matching `journalctl -p err` | 21, matching | 4, matching |
| tui-cron backend version | `systemd 255` | `systemd 259` | `systemd 261` |
| timers parsed | 20, matching `systemctl list-units` | 6, matching | 4, matching |
| cron | **`cron`**, unit `cron.service`, running | **`cronie` 1.7.2**, unit `crond.service`, running | **absent**: no `crontab`, no `/etc/crontab` |
| `/etc/crontab` + `/etc/cron.d` job lines | 8, matching the tables | 1, `/etc/cron.d/0hourly` | 0 |
| this account's `crontab -l` | empty, and read as empty rather than as a failed read | same, from cronie's exit 1 | — |
| run-parts scripts | 7, matching the `cron.*` directories | 1, `cron.hourly/0anacron` | 1, `cron.hourly/snapper`, **listed as unrunnable** |
| jobs across the five kinds | 36 | 10 | 5 |
| tui-cert backend version | openssl 3.0.13 | openssl 3.5.5 | openssl 3.6.4 |
| ACME client | **none**: no `certbot`, no `acme.sh` | same | same |
| certificates found | 0 — no guest ships one | 0 | 0 |
| `/etc/letsencrypt/live` | reported as searched, `skipped: no such file or directory` | same | same |
| certificate of known contents | generated with `openssl`, read back: subject, 29 days left, key matched, mode 644 raised as a finding | same | same |
| tui-samba server | **absent**: no `smbd` | **Samba 4.24.6**, installed by hand for this sweep | **absent**: no `smbd` |
| shares parsed | — | 3 from the shipped `smb.conf`; `[homes]` and `[printers]` come back marked as Samba's own sections | — |
| `smbclient` | — | **absent**: Fedora splits it into its own package, and `smbd` alone is what makes a file server | — |
| accounts read with `pdbedit` | — | through `sudo -n`; the database is root-only | — |
| tui-containers engines | **none**: no docker, no podman | **podman 5.8.1**, rootless and — through `sudo -n` — root's scope: 2 of 2 expected | **none** |
| container store | — | empty, and parsed as empty rather than skipped: no image is ever pulled | — |
| docker | absent on every guest; no image in the lab ships it | same | same |

### Omarchy and `tui-snapper`

The Omarchy VM is the only machine in the lab that rolls back from the boot menu, so it is the only one where the limine half of `tui-snapper` is exercised at all. The smoke test creates a snapshot with `snapper`, runs `limine-snapper-sync`, and then asserts that the tool's boot-entry count equals the number of snapshot nodes in the generated `/boot/limine.conf` and that the new snapshot's number is among them.

That run found a real bug on the first attempt. `/boot` is the mounted ESP, **mode 0700 and owned by root**, so an unprivileged `tui-snapper` could not open `limine.conf` at all: it reported a machine with a full boot menu as having none, and named the wrong rollback mechanism as a result. Every unit test had passed, because a fixture on disk is readable. The tool now escalates that read the same way it escalates its snapper calls.

The same run also corrected the tool's fixtures. `limine-snapper-sync` on Omarchy Server 4.0.1 titles its entries `4 │ 2026-08-29 21:27:27` — the snapshot number, a U+2502 separator, then the timestamp — where the reconstruction had assumed the timestamp alone. The captured file now lives in `tui-snapper/internal/snapper/testdata/limine-omarchy-server.conf`.

### Ubuntu and `tui-network`

The Ubuntu VM is the only machine in the lab configured by **netplan**, and that is what made it worth running. netplan does not write `.network` files where a user would; it renders them into `/run/systemd/network` as **mode 0640, owned `root:systemd-network`**. So the one file that configures the machine's only managed link is the one file an unprivileged `tui-network` cannot open.

The tool listed the seven world-readable templates systemd ships in `/usr/lib/systemd/network` and silently dropped that one — a non-zero count of `.network` files, none of them the file the editor exists to edit. The first smoke test passed anyway, because it only asked whether *a* file was found. It now asks `networkctl` which file configures the managed link and demands that exact path back, plus its contents; and the tool escalates the read with `sudo -n cat` when the plain read hits `EACCES`, the same fallback `tui-snapper` grew for `/boot`.

The run also gave the tool its first fixtures captured from real machines, one per systemd generation, with QEMU's addresses rewritten into the documentation ranges. They are not the same shape: **systemd 261** adds a top-level `Routes` array, an `AddressString`/`DestinationString` rendering beside every byte array, and a fully decoded DHCP `Message` inside the lease, where **systemd 255** has none of them. Both now live in `tui-network/internal/networkd/testdata/networkctl-{list,status}-systemd{255,261}.json`.

### Fedora and `tui-firewall`

The `firewalld` backend used to be a documented stub, and the smoke test asserted the **failure**: `--backend firewalld --check` exited non-zero, auto-detection surfaced the stub error rather than claiming the machine had no firewall, and `firewalld` really was active — so the gap was asserted rather than skipped, with a note that the day someone implemented the backend the test would turn red and get rewritten.

That day came. The backend is real, the test was rewritten, and Fedora went from 3 assertions to **14**. It is now the only machine in the lab where the tool's write path is exercised at all, because it is the only one where a rule can be added and taken away again without changing how the guest behaves afterwards:

1. The default zone (`public`) is the first group, marked as the default, with its target and its `ssh` service parsed.
2. `65530/tcp` is added **through the tool's own command path**, and `firewall-cmd --query-port` agrees it is there.
3. The tool marks it as runtime only, and `--permanent --list-ports` confirms it never reached the permanent configuration — so a reboot undoes what the test did even if the test dies halfway.
4. It is removed again, and both the tool and `--list-ports` agree it is gone.

The other thing that run settled is a version question. The `internal/firewalld` fixtures were captured from firewall-cmd **2.3.2** on Fedora 42, and this guest runs **2.4.4**. Nothing was assumed about the two minor versions in between: the zone listing and the active-zone listing were captured verbatim from the guest and are now fixtures beside the older pair, with a unit test asserting both releases parse to the same key set. They do — `ingress-priority`, `egress-priority`, the tab-indented rich-rule continuation, all identical. The parser needed no change, and now there is a test that says so rather than a hope.

### Fedora, and the two tools that had never met their backend

`tui-samba` and `tui-containers` joined on the same sweep, and both were in the position `tui-cron` was in before `cronie`: the branch that matters had only ever run against fixtures.

`tui-samba` found nothing wrong. Installing `samba` on the Fedora guest for one run put the present branch through a real `smbd` for the first time — the version probe answering 4.24.6, the shipped `smb.conf`, `[homes]` and `[printers]` coming back as Samba's own sections rather than as directories somebody exported, `security = USER`, and the root-only account database read through `sudo -n`. A share created by hand in a `mktemp -d`, validated with `testparm`, came back with its name, path and comment intact, and flipping `read only` moved the writable count. Twenty-one assertions, no change to the parser.

`tui-containers` failed on two guests out of three, 15 assertions to 1, and the failure was worth the whole exercise. Neither Ubuntu nor Omarchy ships docker or podman, and the tool treated a machine with neither as an error: `NewReal` refused to build, `--check` exited 1 before it could report anything, and the fifteen assertions about the empty case all died on the same non-zero exit. The smoke test had documented the opposite contract since the day it was written — *a server that runs no containers is a normal server, the report is an empty engine list, the exit is 0* — and every screen below the front door was already written for it.

`Load` had the same mistake one layer down, with a worse consequence: when an engine is installed and answers nothing, it threw away the model it had just built and with it each engine's reason for staying silent — the one fact that explains the empty screen. Nothing in the lab has a dead daemon, so that path had never run either, and the smoke test's docker branch asserts a reason it could not have received. Both return the model now. Fedora, which already had podman 5.8.1, exercised the present branch in the same run: both scopes answered, rootless with no privileges at all and root's through `sudo -n`, and an empty store was parsed as empty rather than skipped.

### The privileged reads, run for real for the first time

`tui-secure`, `tui-users`, `tui-ssh` and `tui-disk` joined the lab together, and they are the first tools whose escalated branches — `sshd -T`, `getent shadow`, `sudo -l`, another account's `authorized_keys` — had ever run against a live backend rather than a fixture. Every guest gives `lab` passwordless `sudo -n`, so all of them executed.

`tui-secure` passed on all three machines unchanged: every one of its eight probes answered, the MAC layer came back as AppArmor on Ubuntu and SELinux on Fedora, and on Omarchy — which ships neither — the probe reported `unknown` rather than a silent ok. No password hash reached the report on any of them.

The other three each had a bug, and in all three cases the bug was in the **test**, which is its own lesson: a smoke test that has only ever been read is as unproven as the code it covers.

- **`tui-users`** wrote an invented ed25519 blob into `authorized_keys` and asked `ssh-keygen` to fingerprint the file. `ssh-keygen` refuses a file containing a key it cannot decode, so the check failed on all three guests and told us nothing about the tool. Worse, it had been aimed at `ssh-keygen` rather than at `tui-users`, and could not have been aimed at the tool: authorized keys, sudo rules and aging are read by the backend's *detail* path, which only the UI ever called. `--check` grew a `--user <name>` flag, and the test now demands back the exact fingerprint `ssh-keygen` computes for a real key it just generated — which proves the escalated read of a mode 600 file inside somebody else's mode 700 directory, and the parse.

- **`tui-ssh`** met a change in `sshd` itself. **OpenSSH 10.5** prints `sshd -T` in the canonical spelling — `PermitRootLogin no` — where **9.6 and 10.2** lower-case every keyword. The tool canonicalises and parsed all three correctly; the smoke test's `sed` on a lowercase keyword found nothing on Omarchy, so it *skipped* its own strongest assertion on the one machine in the lab that keeps root out entirely, and reported a pass. A real `sshd -T` from 10.5 is now a fixture in `tui-ssh/internal/openssh/testdata/sshd-T-openssh105.txt`.

- **`tui-disk`** had a whole branch that had never executed. Ubuntu is the only guest whose root is **ext4** with btrfs mounted somewhere else, which is exactly the case that proves the btrfs section follows the filesystem and not the root — and the branch for it looked for that filesystem at `/mnt/btrfs`, which nothing mounts. The lab puts the data disk on `/srv/data`. The test now asks `findmnt` where btrfs is, and Ubuntu went from 8 checks to 13.

### Omarchy and `tui-update`

`tui-update` was the one tool the lab failed, and it failed on the machine it most needs to work on. Omarchy Server 4.0.1 ships `checkupdates` — it comes with `pacman-contrib` — but **not `fakeroot`**, which `checkupdates` needs to build its temporary database. So:

```console
$ tui-update --check
tui-update: pacman read failed: `/usr/bin/sudo -n checkupdates` failed:
==> ERROR: Cannot find the fakeroot binary
```

`--check` exited 1 and the whole report was empty, which took ten of the twelve assertions down with it — the pending count, the restart class, the snapshot support the machine really does have, the pacman log. Only `--version` and the `--demo` frame passed.

Nothing about that was the lab's doing: it is the shipped image, unmodified, which is the entire point of the Omarchy VM. The fix took both of the routes the failure suggested. `checkupdates` is now chosen only when `fakeroot` is on `PATH`, and the pending list falls back to `pacman -Qu` with a note saying why it may be stale; and the pending list is a *section* of the model rather than its precondition, so a machine whose update count cannot be read still shows its snapshot configuration, its timer and its history, with the reason in place of the count. `--check` grew a `pendingError` field so the difference between "nothing pending" and "could not tell" is machine-readable, and the smoke test asserts it is absent.

Two more things only the real image would have shown, both fixed with fixtures captured from it:

- **`pacman -Qu` exits non-zero when nothing is upgradable**, and on a machine that has never run a `pacman -Sy` it prints a warning per repository instead of a package list. Empty output was already treated as "up to date"; five warning lines and exit 1 were not, so the fallback failed exactly where it was needed.
- **A pacman history is a log of invocations, not of transactions.** One `omarchy-server-update run` runs pacman three times — a bare `-Sy`, a keyring refresh, then the upgrade — so two of every three rows on the history screen had an empty detail column. Runs that changed no package are now dropped, which is what apt and dnf list anyway.

Omarchy now passes **13/13**, skipping one: a cloud image built by installing into a chroot has no `/var/log/pacman.log` until its first upgrade. Running a real `omarchy-server-update run --no-reboot` on the guest gives it one, and the suite is 14/14 from there. Ubuntu (apt 2.8.3) and Fedora (dnf 5.4.1) pass 12/12 and 11/11; Fedora skips one, because `needs-restarting` lives in `dnf-plugins-core`, which the Cloud image leaves out.

One gap the lab cannot close: **no guest has SMART**. Every disk is virtio, none of the three images ships `smartmontools`, so `tui-disk`'s health read is asserted only in its absence — each drive must come back `unknown` *with a reason*, which is at least distinguishable from a read the tool forgot to make.

### The three schedulers-and-secrets tools, and what a real box changed

`tui-logs`, `tui-cron` and `tui-cert` joined together. All three passed their backend assertions on the first run — the parsers were right — and all three had a bug somewhere else, which is becoming the pattern: **the read path is the part that gets unit tests, so it is not the part the lab finds things in.**

- **`tui-logs` rendered a demo indistinguishable from a real machine.** It was the only tool in the family whose header subtitle carried the filter instead of `backend.Describe()`, so `--demo` drew a full screen of fabricated entries under a header that said nothing about where they came from. The lab caught it because its `--demo` check greps the rendered frame for the word `demo` and found none — the one lab assertion that needs no cooperation from the tool, failing on all three guests at once. For a log viewer this is the worst possible class of bug: every other tool's demo is obviously a sample, and this one looked like your journal. The subtitle now leads with the backend and appends the filter, which is what the rest of the family does.

- **`tui-logs` also had a compatibility test that could only ever pass while it was vacuous.** `TestTestedVersionsAreBackedByEvidence` looked for `"version":"255"` in `compat/results.jsonl`, and the generator writes `"version": "255"` with a space. It was green for as long as the tested list was empty — which it was, because the tool had never been run against a real machine. The first lab run filled the list in and the test failed on three versions that are in the file. It decodes the JSONL now.

- **`tui-cron`'s smoke test needed `bc`.** Ubuntu ships it; Fedora Cloud Base and Omarchy Server do not. `paste -sd+ | bc` printed `command not found`, the sum came back empty, and the "jobs are accounted for across the five kinds" assertion failed on two of three machines for a reason with nothing to do with the tool. It adds the counts in `awk` now.

- **`tui-cert`'s absent-client path was the one that always ran, and the only one nobody asserted.** No image in the lab ships `certbot` or `acme.sh`, so the smoke test's certbot block was dead code on every guest while the branch that really executed went unchecked. The tool's behaviour turned out to be right — `{"name":"certbot","present":false,"purpose":…}`, an empty `acme` list, no invented `timerActive`, and `/etc/letsencrypt/live` still reported as searched with `skipped: no such file or directory` — but "right and unasserted" is how it stays right by luck. The absent branch is now four assertions, and tui-cert went from 18 checks to 22.

Two facts the run established that were previously assumed:

- **`journalctl --list-boots -o json` is the same shape on systemd 255, 259 and 261** — `index`, `boot_id`, `first_entry`, `last_entry`, no additions. That is the one read in `tui-logs` gated on a version, and the gate is at 252, so the whole tested range is above it and the table fallback never ran here. Both ends are now fixtures captured from the guests (`list-boots-json-systemd{255,261}.txt`), so a future release that changes the shape fails a unit test rather than a screen.
- **Fedora Cloud Base ships neither `cron` nor `cronie`**, so two of the three guests exercised `tui-cron`'s cron-absent branch and only Ubuntu exercised the present one. Ubuntu's unit is `cron.service`; nothing in the lab was a `crond.service` machine, so that half of the unit-name detection was covered only by fixtures. The seed installs `cronie` now — see below.

### Fedora, cronie, and the machine that has cron.hourly and no cron

The line above is what made the seed grow a `cronie` entry: `tui-cron`'s whole `crond` branch — the unit name, the tables cronie ships, its `crontab -l` — had never run on a machine, only against fixtures reconstructed from a developer's Fedora box. The Fedora VM was rebuilt from the seed with `cronie` installed and `crond` enabled, and the suite re-run on all three guests.

**Every fixture turned out to be right.** `/etc/crontab` and `/etc/cron.d/0hourly` on Fedora 44 are byte-for-byte what `internal/crontab/testdata` already held; `crontab -V` really answers `cronie 1.7.2`; the unit is `crond.service` and the tool named it. That is a genuine result — the reconstruction was faithful — and it is the first time anyone could say so.

What the run did change is the **suite**, and through it the tool.

- **The cron-present branch was three assertions that could not fail.** `"cron.d": [0-9]+` and `"crontab": [0-9]+` pass on a machine whose tables were never opened, because zero is a number. They are counts now, computed on the guest from the files themselves — job lines are the ones starting with a digit, a `*` or an `@`, everything else in those files being a comment or a `SHELL=`/`PATH=`/`MAILTO=` assignment. Ubuntu's tables carry 8 and Fedora's carry exactly 1, the `01 * * * * root run-parts /etc/cron.hourly` in `0hourly`, and the tool has to produce that number and not merely a number.

- **cronie answers `crontab -l` with "no crontab for lab" on stderr and exit 1** when there is no table. The backend reads that as an empty table rather than a failed read, which is right and was untested; the suite now demands the count match whatever `crontab -l` really holds, and that the rest of the report survive the non-zero exit.

- **A fresh cron machine's journal has no jobs in it, only cronie announcing itself** — `(CRON) STARTUP (1.7.2)` and three `(CRON) INFO` lines. Every one of them names CRON and none is a job, so a parser keyed on the daemon's name rather than on the `CMD (` marker would read four outcomes off a machine where nothing has run. It is captured as `journal-crond-fedora44-boot.txt` and asserted to produce no log lines at all.

Then the strengthened suite found a real bug, and not on Fedora:

- **Omarchy Server ships `/etc/cron.hourly/snapper` and no cron.** No `crontab` binary, no `/etc/crontab`, no unit. `tui-cron`'s `Load` bailed out before walking the run-parts directories whenever both of those were missing, so it reported that machine as having no cron jobs whatsoever — while a snapshot script sits in `cron.hourly` looking perfectly scheduled and never running. That is the one answer a scheduler viewer must not give: the whole value of listing that file is to say it will not fire. The directories need no daemon to read, so they are read unconditionally now, and on a machine with no cron each row comes back `Active: false` with *this script is installed but nothing runs it*. Omarchy went from 4 jobs to 5, and from 15 checks to 19.

The suite also grew one assertion that holds on all three: the `anacron-dir` count equals the executables in the four `cron.*` directories — 7 on Ubuntu, 1 on Fedora, 1 on Omarchy. It is the same shape of check as the timer count, and it is what caught the bug.

Nothing in these three suites writes: no crontab is installed, no timer enabled, no certificate issued, no journal vacuumed. `tui-cert` generates a throwaway key pair with `openssl` in a `mktemp -d` it removes on exit, which is the only file any of them creates.

## License

MIT. See [LICENSE](LICENSE).
