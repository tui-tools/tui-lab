<!-- markdownlint-disable MD013 -->
# The router topology

`lab.sh router` boots a three-machine network on top of the same image cache,
cloud-init seeding and ssh machinery the rest of the lab uses. It exists so a
firewall tool can be judged against a router that filters, translates and
forwards for real, instead of against a single VM talking to itself.

This document lives here rather than in the README on purpose: the topology is
not part of what the lab advertises until the work that needs it has landed.

## Layout

```
  wan-host                  router                  lan-client
 10.90.0.20  ── wan ──  wan0 10.90.0.1
                        lan0 10.91.0.1  ── lan ──  10.91.0.30
  :8080 HTTP                                        :8081 HTTP

  mgmt (user-mode NIC + ssh hostfwd) on each guest, carrying nothing else
```

| Network | Subnet | Members | Carried by |
|---------|--------|---------|------------|
| `wan` | `10.90.0.0/24` | `router` (`wan0`, `.1`), `wan-host` (`wan0`, `.20`) | QEMU socket netdev, `127.0.0.1:12090` |
| `lan` | `10.91.0.0/24` | `router` (`lan0`, `.1`), `lan-client` (`lan0`, `.30`) | QEMU socket netdev, `127.0.0.1:12091` |
| `mgmt` | `10.0.2.0/24` per guest | all three, separately | QEMU user-mode networking, ssh hostfwd |

A QEMU socket netdev is a plain TCP connection on the loopback, so a segment
needs no bridge, no tap device and no root on the host. It carries exactly two
endpoints, which is exactly how many each of these segments has. The router
**listens** on both links and the two hosts **connect** to it, so the router has
to be booted first: `lab.sh router up` does that, and restarting the router
alone breaks both links until the other two are restarted as well.

The management NIC is deliberately outside the topology. It is how the lab
reaches each guest over ssh, and how cloud-init reaches the archive to install
packages. `lan-client` gets its management default route at metric 200 for that
reason, and `router up` deletes it once the guest is provisioned, so the machine
the tests see has exactly one way out and it is the router.

`wan-host` has **no route to `10.91.0.0/24`**, also deliberately. A reply that
reaches it from behind the router can only get back because the router
translated the source address, which is what makes the NAT check mean something.

## The guests

All three run the Ubuntu 24.04 cloud image already in the lab's cache: between
them they need `nftables`, `curl` and `python3`, and noble's cloud-init renders
the multi-NIC `network-config` through netplan. Interfaces are matched by a MAC
derived from the VM name and renamed, so every rule in a test can say `wan0` and
`lan0` and mean it.

| Guest | Seeded with |
|-------|-------------|
| `router` | `nftables`, `conntrack`, `tcpdump`, `net.ipv4.ip_forward=1`, `nftables.service` disabled, **an empty ruleset** |
| `wan-host` | `python3 -m http.server 8080` on `/srv/wan`, access log at `/var/log/wan-http.log` |
| `lan-client` | `python3 -m http.server 8081` on `/srv/lan`, access log at `/var/log/lan-http.log` |

The router loads **no rules at boot**. Every rule that exists during a run was
put there by that run, which is the only way a "before" state means anything.

Two details that cost time to find:

- **`fwd` is an nftables keyword**, so a chain cannot be called that. `nft -f`
  answers with `syntax error, unexpected fwd`. The chains here are named
  `filter_in`, `filter_out`, `filter_fwd`, `nat_pre`, `nat_post`.
- **`python3 -m http.server` block-buffers its access log** when stderr is a
  file rather than a terminal. Without `-u` the log the NAT check reads stays
  empty until the process exits, and the check fails on a router that did
  everything right.

## The checks

`lab.sh router test` applies hand-written `nft` rulesets over ssh and records
every command, its output and its exit status under
`out/results/<stamp>-router/topology.log`. No tool binary is involved: these
checks are the yardstick, so they have to hold on their own.

| # | Check |
|---|-------|
| 1 | `router` has `wan0`, `lan0` and IP forwarding on |
| 2 | `router` reaches both networks |
| 3 | `lan-client` has one default route and it is the router |
| 4 | `wan-host` serves HTTP on the wan segment |
| 5 | Without masquerade, `lan-client` cannot reach `wan-host` |
| 6 | With masquerade, it can |
| 7 | `wan-host`'s access log names the router's wan address, not the client's |
| 8 | With the masquerade rule removed, the client is cut off again |
| 9 | A forward chain with `policy drop` stops LAN to WAN traffic |
| 10 | The forward rule lets it through |
| 11 | That rule's packet counter moved |
| 12 | An input rule blocks `wan-host` from reaching the router |
| 13 | Removing it restores the reach |
| 14 | An output rule blocks the router's own traffic to `wan-host` |
| 15 | A rule matching a named set blocks the address in the set |
| 16 | Deleting the element propagates, without touching the rule |
| 17 | Before the port forward, the router's wan address serves nothing |
| 18 | The port forward exposes `lan-client:8081` on `10.90.0.1:8080` |
| 19 | Removing the port forward closes it again |

Checks 15 and 16 are there because a named set is the object an alias has to
compile down to: one thing, referenced by rules, whose membership changes
without any rule being rewritten.

The router is left as `up` handed it over, forwarding on and ruleset empty.

## The same proofs, written by the real TUI

`lab.sh router test --via-tool [PATH]` runs a second suite in which not one
rule is written by this script. Every mutation is typed into the real
`tui-firewall` running on the router: the add-rule form, the actions menu, the
policy picker and the delete dialog, key by key, with the confirm dialog
answered the way a person answers it. The network probes are the same ones the
hand-written suite uses, so the two suites are comparable line by line.

There is no batch or apply flag to reach for, in this tool or in any other in
the family, and there should not be: a non-interactive mutation path would go
around the preview-and-confirm dialog that is the reason these tools exist. So
the lab drives the terminal instead.

### The driver

`tmux` is the pty. The tool runs in a detached session on the guest,
`send-keys` types into it, and `capture-pane` reads the screen back as plain
text — which is both what the driver makes its decisions on and what the run
files away as evidence.

| Helper | What it does |
|--------|--------------|
| `tui_start <vm> <cmd…>` | installs tmux if the guest has none, starts the session at 160x45 and waits for the first drawn frame |
| `tui_keys <keys…>` | sends named keys one at a time, with a beat between them, in one ssh round trip |
| `tui_type <text>` | types literal text, refusing anything that would not survive two shells and a tmux argument |
| `tui_wait_for` / `tui_wait_gone` | polls the pane until a string appears or leaves; a timeout captures the screen and fails the run |
| `tui_pick <label>` | chooses an entry in an open picker by its label: home, then down until the highlight sits on it |
| `tui_focus <label>` | moves the add-rule form to a field by its label |
| `tui_confirm <name>` | captures the confirm dialog, checks it is really showing a command, answers `y` and waits for the reload |
| `tui_shot <name>` | files the screen under `panes/` and quotes it into the run log |

Nothing counts key presses. A picker is driven until the marker sits on the
label that was asked for, and a form field is tabbed to until the cursor is on
it: counting would work until the day the backend adds an action, and then it
would work wrongly.

`tui_confirm` captures the dialog **before** answering it. The preview is the
evidence: what the run proves is that the keys a person would press produced
that exact `nft` command line, and that the command line then changed the
network.

Three things cost time to find here:

- **The OSC 11 quirk.** The tools ask the terminal for its background colour
  at startup and only draw once it has answered or the probe gives up — the
  same query `render-screenshots.py` in the kit answers by hand. tmux answers
  it, so the first frame arrives in about a second; but keys sent before it
  are eaten by the reader waiting for that answer. Every step waits for the
  screen it expects before typing into it, starting with the first frame.
- **A tmux server started from an ssh command dies with the login session.**
  It lives inside that session's scope, and logind takes the scope down when
  the connection closes, which shows up much later as `no server running`.
  `loginctl enable-linger` is what keeps it alive between the driver's calls.
- **A running binary cannot be overwritten in place.** `lab.sh test` ships a
  `tui-firewall` of its own into this guest, so the driven one has a path of
  its own and is unlinked before it is written.

### What it mirrors

The tool owns one table, `inet tui`, and writes nowhere else, so the run
begins by creating it and its five chains — from the actions menu, with the
same preview and confirm as everything after it.

| # | Check through the TUI | Mirrors |
|---|-----------------------|---------|
| 1 | The actions menu created `inet tui` with its five chains | — |
| 2 | Before the rule, `wan-host` reaches the router | 12 |
| 3 | The rule the form wrote is scoped to `wan0`, a drop on `wan-host`'s address | 12 |
| 4 | A rule added in the TUI blocks `wan-host` from reaching the router | 12 |
| 5 | Deleting it in the TUI restores the reach | 13 |
| 6 | Before the rule, the router reaches the service on `wan-host` | 14 |
| 7 | An output rule scoped to `wan0` blocks the router's own traffic | 14 |
| 8 | Deleting it lets the router out again | — |
| 9 | Before the ICMP rule, `wan-host` can ping the router | — |
| 10 | An ICMP rule drops `wan-host`'s echo-request on `wan0`; the ping fails | — |
| 11 | Deleting the ICMP rule lets the ping through again | — |
| 12 | Before the masquerade, `lan-client` cannot reach `wan-host` | 5 |
| 13 | The masquerade the TUI wrote is scoped to the LAN source leaving `wan0` | — |
| 14 | With that source-scoped masquerade, `lan-client` reaches `wan-host` | 6 |
| 15 | `wan-host` logged the router's wan address, not the client's | 7 |
| 16 | The forward policy the TUI set to deny stops LAN to WAN traffic | 9 |
| 17 | The forward rules the TUI wrote are the stateful pair, not two stateless rules | — |
| 18 | The stateful forward rules let LAN to WAN through | 10 |
| 19 | The new-connection forward rule's packet counter moved | 11 |
| 20 | Before the port forward, the router's wan address serves nothing | 17 |
| 21 | The port forward the TUI wrote exposes `lan-client` on it | 18 |
| 22 | Deleting it in the TUI closes it again | 19 |
| 23 | The rule the TUI wrote matches the alias by name | 15 |
| 24 | A rule matching the alias blocks the address in it | 15 |
| 25 | Emptying the alias in the TUI propagates, without touching the rule | 16 |
| 26 | The rule that used the alias is still there | 16 |

Evidence lands under `out/results/<stamp>-router-via-tool/`: the run log with
every key sequence, every pane and every probe, and `panes/` with the screens
themselves, numbered in the order they were taken.

### The staged, atomic, connectivity-safe apply

Two more proofs sit at the end of the suite, and they are the ones a router
needs most: applying a set of rules that would cut the operator off if it were
applied a rule at a time. Phase 2 stages the whole set instead, and the lab
drives both halves of it.

The first is the atomic apply. With staging on (`s`), the forward chain is
cleared to policy accept, then a batch is collected: a forward policy of
**drop** together with the two accept rules that keep the LAN alive. Applied
rule by rule, the drop would strand the LAN in the gap before the accepts;
staged, the review pane (`S`) shows the whole set and the confirm shows the
exact `nft -f` transaction — every line that goes to nft's standard input —
before the single `y`. The proof is that the ruleset lands whole (the drop
policy **and** both accept rules, never a half of it) and traffic still flows.
Both the review pane and the apply preview are filed under `panes/` before the
confirm.

The second is the timeout rollback. A batch is applied and then **not** kept:
the operator is simulated as cut off, `k` is never pressed, and the keep window
runs out. The proof is that the ruleset reverts on its own to the snapshot the
tool captured before the apply — the applied change is gone, and the ruleset
that comes back is the one that was there before — with no key press from the
driver. This is the connectivity-safe half of an OPNsense apply, run for real.

### What the UI expresses now

Phase 1 could not write an interface match, a connection state, an ICMP type or
a source-scoped masquerade, so several checks were blunter than the hand-written
suite: "stop this host" where the rule wanted "stop this host's pings on this
interface", and two stateless rules where one stateful pair belonged. Phase 2
closes those gaps, and the checks above are now written the way a router
operator writes them:

| Was missing in phase 1 | Written by the TUI now |
|------------------------|------------------------|
| An interface match on a filter rule (`iifname`, `oifname`) | The input and output rules are scoped to `wan0`; the new-connection forward rule is `iifname "lan0" oifname "wan0"` |
| A connection-state match (`ct state`) | The forward chain's return path is one stateful rule, `ct state established,related accept` |
| Protocols beyond `tcp` and `udp` | An ICMP rule drops exactly `echo-request`, so "stop this host pinging me" is the ping, not the host |
| A source-scoped masquerade | The masquerade is `ip saddr 10.91.0.0/24 oifname "wan0" masquerade`, one network behind the router rather than everything leaving the link |
| A staged, atomic apply with a connectivity-safe rollback | The two proofs above |

The actions menu can also take the table and its chains apart now, previewed
like any other mutation, though the run still flushes the ruleset over ssh at
the end so the machine is left exactly as `up` handed it over.

## The libvirt backend

The QEMU socket backend above is portable and needs no root, but a socket
segment carries exactly two endpoints and the whole thing runs on one laptop.
The libvirt backend trades that portability for a real hypervisor: the same
three guests as KVM domains on a second machine, over real virtual networks
with a NIC per segment, so a heavy run does not compete with the machine the
work is being done on. The socket backend stays the default; libvirt is opt-in.

Select it with `--backend libvirt` on the router command, or `LAB_BACKEND=libvirt`
in the environment:

```bash
./lab.sh router --backend libvirt up
./lab.sh router --backend libvirt test
./lab.sh router --backend libvirt test --via-tool /path/to/tui-firewall
./lab.sh router --backend libvirt down
```

Everything the flow does above is the same on this backend — the checks, the
TUI driver, the evidence under `out/`. What changes is underneath: where a
guest runs and how the lab reaches it.

### What it builds on the hypervisor

Every object is namespaced `tuilab-` so it can never be confused with anything
already on the host.

| Object | Name | What it is |
|--------|------|------------|
| Storage pool | `tuilab` | A `dir` pool at `$HOME/tuilab/images` (set `LAB_LIBVIRT_POOL_PATH` to move it). It **must** live under `/home`: `/` on the avell has ~31G, `/home` has ~125G, and a base image plus overlays does not fit in the former. |
| Base volume | `tuilab-base-noble.qcow2` | The Ubuntu cloud image, uploaded into the pool once. Every guest is a thin qcow2 overlay on it, so three guests cost a few gigabytes, not three full images. |
| Management network | `tuilab-mgmt` | A NAT network, `192.168.199.0/24`, with a fixed DHCP lease per guest (router `.2`, wan-host `.20`, lan-client `.30`). It carries ssh and the archive, nothing topological — the same role the user-mode NIC plays on the socket backend. Its subnet is chosen clear of the host's own `default` and any existing lab network. |
| WAN segment | `tuilab-wan` | An **isolated** network: a bridge with no forward, no host address and no DHCP. The router owns the only addresses on it. |
| LAN segment | `tuilab-lan` | The same, for the LAN. |
| Domains | `tuilab-router`, `tuilab-wan-host`, `tuilab-lan-client` | One per role, BIOS boot, an overlay disk, the cloud-init seed as a CD-ROM, the mgmt NIC and this role's topology NICs. |

The guest cloud-init `network-config` is the very same one the socket backend
renders: it matches interfaces by the MAC this script assigns and renames them,
and those MACs are put on the domains' NICs here, so `wan0` and `lan0` name the
same links on both backends.

The lab runs on the coordinating machine and the guests run on the avell, on a
NAT network this machine cannot route to directly. So every ssh to a guest is
proxied through the hypervisor — the lab's own ssh access to the avell is the
jump — and lands on the guest's fixed management address. `router up` then
deletes the client's management default route exactly as it does on the socket
backend, so the machine the tests see still has one way out and it is the router.

`router down` on this backend is a full teardown: it destroys and undefines the
three domains, removes their overlays and seeds, and removes the three networks.
It **leaves the pool and the base image in place**, so the next `up` is a few
seconds of overlay creation rather than another upload. Nothing outside the
`tuilab-` namespace is ever touched.

### Prerequisites on the avell

- libvirt with a running `libvirtd`, reachable at
  `qemu+ssh://<user>@<hypervisor>/system` (set `LAB_LIBVIRT_URI`; a jump host via `LAB_LIBVIRT_JUMP`) from the coordinating machine (this
  host needs a local `virsh` and ssh access to the avell; `virsh define` and
  friends read their XML here and transmit it).
- `/dev/kvm`, and the login user in the `libvirt` group.
- `qemu-img` on the avell (the overlays are created there) and enough room under
  `/home` for the pool.
- ssh from the coordinating machine to the avell, since the guests are reached
  through it. Guest ssh uses the same throwaway lab key as every other lab VM.

The connection URI, jump host, pool name and path are overridable with
`LAB_LIBVIRT_URI`, `LAB_LIBVIRT_JUMP`, `LAB_LIBVIRT_POOL` and
`LAB_LIBVIRT_POOL_PATH`.

## Usage

```bash
./lab.sh router up          # boots router, wan-host, lan-client in that order
./lab.sh router status      # pids, ssh ports, link sockets, addresses per guest
./lab.sh router test        # the checks above, PASS/FAIL, evidence under out/results/
./lab.sh router test --via-tool ../tui-firewall/tui-firewall
                            # the same proofs, typed into the real TUI
./lab.sh router down

./lab.sh router --backend libvirt up     # the same, as KVM domains on the avell
./lab.sh router --backend libvirt test
./lab.sh router --backend libvirt down   # full teardown, base image kept
```

`lab.sh ssh router …`, `lab.sh ssh lan-client …` and `lab.sh ssh wan-host …`
work the way they do for any other VM.

`--via-tool` takes an optional path. Without one the binary is built from the
sibling `tui-firewall` checkout, whatever branch it is on; with one, any
binary can be driven, which is how a branch that is not checked out next door
gets tested.

## What this does not cover

Two uplinks and gateway failover, VPN, the identity provider and the traffic
statistics all need machines this topology does not have. It is the network the
firewall work needs, and no more than that.
