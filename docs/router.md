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

## Usage

```bash
./lab.sh router up          # boots router, wan-host, lan-client in that order
./lab.sh router status      # pids, ssh ports, link sockets, addresses per guest
./lab.sh router test        # the checks above, PASS/FAIL, evidence under out/results/
./lab.sh router down
```

`lab.sh ssh router …`, `lab.sh ssh lan-client …` and `lab.sh ssh wan-host …`
work the way they do for any other VM.

## What this does not cover

Two uplinks and gateway failover, VPN, the identity provider and the traffic
statistics all need machines this topology does not have. It is the network the
firewall work needs, and no more than that.
