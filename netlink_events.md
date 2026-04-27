# Netlink Neighbor, Nexthop, /32, and OSPF /32 Events

A beginner-friendly guide to Linux kernel networking events.

---

## Table of Contents

1. [What is Netlink?](#1-what-is-netlink)
2. [Neighbor Events](#2-neighbor-events)
3. [Nexthop Events](#3-nexthop-events)
4. [/32 Route Events](#4-32-route-events)
5. [OSPF /32 Events](#5-ospf-32-events)
6. [How Everything Fits Together](#6-how-everything-fits-together)
7. [Quick Reference Table](#7-quick-reference-table)

---

## 1. What is Netlink?

Netlink is the communication channel between the **Linux kernel** and **userspace programs**.
Think of it as a socket-based mailbox: the kernel drops messages when network state changes,
and daemons (routing software, monitoring tools) subscribe and react.

```
  ┌──────────────────────────────────────────────────────┐
  │                  USERSPACE                           │
  │                                                      │
  │   ┌──────────┐  ┌──────────┐  ┌─────────────────┐   │
  │   │   FRR /  │  │   iproute│  │  Custom monitor │   │
  │   │   BIRD   │  │   (ip)   │  │  (your script)  │   │
  │   └────┬─────┘  └────┬─────┘  └───────┬─────────┘   │
  │        │             │                │              │
  │        └─────────────┴────────────────┘             │
  │                       │  Netlink socket              │
  └───────────────────────┼──────────────────────────────┘
                          │  AF_NETLINK / RTNETLINK
  ┌───────────────────────┼──────────────────────────────┐
  │                  KERNEL                              │
  │                       │                              │
  │   ┌───────────────────┴───────────────────────────┐  │
  │   │              RTNETLINK subsystem               │  │
  │   └───────┬──────────────┬──────────────┬─────────┘  │
  │           │              │              │             │
  │   ┌───────┴──────┐ ┌─────┴──────┐ ┌────┴──────────┐  │
  │   │  Neighbor /  │ │   Routing  │ │   Nexthop     │  │
  │   │  ARP / NDP   │ │   Table    │ │   Table       │  │
  │   └──────────────┘ └────────────┘ └───────────────┘  │
  └──────────────────────────────────────────────────────┘
```

### RTNETLINK message families

Every netlink event carries a **message type** that tells the receiver what changed:

| Message Type        | Meaning                              |
|---------------------|--------------------------------------|
| `RTM_NEWNEIGH`      | A neighbor (ARP/NDP entry) appeared  |
| `RTM_DELNEIGH`      | A neighbor entry was removed         |
| `RTM_NEWNEXTHOP`    | A nexthop object was created         |
| `RTM_DELNEXTHOP`    | A nexthop object was deleted         |
| `RTM_NEWROUTE`      | A route was added to the FIB         |
| `RTM_DELROUTE`      | A route was removed from the FIB     |

---

## 2. Neighbor Events

### What is a "neighbor"?

A **neighbor** is any other device reachable on the same Layer-2 segment.
Before your host can send an IP packet to `192.168.1.5`, it must discover
which MAC address owns that IP. This is done via **ARP** (IPv4) or **NDP** (IPv6).

```
  Host A (192.168.1.1)         Host B (192.168.1.5)
  MAC: aa:bb:cc:dd:ee:01       MAC: aa:bb:cc:dd:ee:02

       ┌─────────────────────────────────┐
       │          Ethernet LAN           │
       └─────────────────────────────────┘

  Step 1 — ARP Request (broadcast):
     "Who has 192.168.1.5? Tell 192.168.1.1"
     ─────────────────────────────────────►  (all hosts)

  Step 2 — ARP Reply (unicast):
     "192.168.1.5 is at aa:bb:cc:dd:ee:02"
     ◄─────────────────────────────────────

  Step 3 — Kernel stores the mapping:
     192.168.1.5  →  aa:bb:cc:dd:ee:02   (state: REACHABLE)
     ─── Netlink RTM_NEWNEIGH fires ────►  userspace daemons
```

### Neighbor states (the lifecycle)

```
                        traffic arrives or
                        'ip neigh add' used
                              │
                              ▼
                       ┌────────────┐
                       │ INCOMPLETE │  ARP sent, waiting for reply
                       └─────┬──────┘
                   reply     │         timeout
                 received    │──────────────────► FAILED
                             ▼
                       ┌────────────┐
                       │ REACHABLE  │  Fresh, confirmed reachable
                       └─────┬──────┘
                             │  timer expires (~30s default)
                             ▼
                       ┌────────────┐
                       │   STALE    │  Not confirmed recently,
                       └─────┬──────┘  but last known MAC kept
                             │  traffic sent to this neighbor
                             ▼
                       ┌────────────┐
                       │   DELAY    │  Waiting for upper-layer
                       └─────┬──────┘  confirmation (TCP ACK, etc.)
                             │
                    ┌────────┴──────────┐
                    │                   │
              confirmed             not confirmed
                    ▼                   ▼
             REACHABLE             ┌─────────┐
                                   │  PROBE  │  Sending unicast ARP
                                   └────┬────┘
                                        │
                               reply    │     timeout
                             received   │─────────────► FAILED
                                        ▼
                                  REACHABLE
```

Special states:
- **PERMANENT** — manually configured (`ip neigh add ... nud permanent`), never expires.
- **NOARP** — interface does not need ARP (e.g., point-to-point links).

### Who generates neighbor events and when?

| Generator | Trigger | Netlink Message |
|-----------|---------|-----------------|
| Kernel ARP/NDP subsystem | First packet to an unknown IP | `RTM_NEWNEIGH` (INCOMPLETE) |
| Kernel ARP/NDP subsystem | ARP reply received | `RTM_NEWNEIGH` (REACHABLE) |
| Kernel timer | Reachability timer expires | `RTM_NEWNEIGH` (STALE) |
| Kernel timer | Probe fails, entry deleted | `RTM_DELNEIGH` |
| `ip neigh add/del` | Admin action | `RTM_NEWNEIGH` / `RTM_DELNEIGH` |
| FRR / BIRD routing daemon | Manage static ARP entries | `RTM_NEWNEIGH` / `RTM_DELNEIGH` |
| EVPN / VXLAN subsystem | Overlay MAC learning | `RTM_NEWNEIGH` |

### Viewing neighbor events live

```bash
# Monitor all neighbor changes in real time
ip monitor neigh

# Show current neighbor table
ip neigh show

# Example output:
# 192.168.1.1 dev eth0 lladdr aa:bb:cc:00:11:22 REACHABLE
# 192.168.1.5 dev eth0 lladdr aa:bb:cc:00:33:44 STALE
# 10.0.0.1    dev eth0                           FAILED
```

---

## 3. Nexthop Events

### What is a nexthop?

A **nexthop** is the "next hop to reach a destination" — the gateway IP
and/or outgoing interface. In modern Linux (kernel 5.3+), nexthops can be
managed as **standalone objects**, decoupled from individual routes.
This allows many routes to share a single nexthop object.

```
  Route table:                  Nexthop table:
  ┌──────────────────────┐      ┌──────────────────────────────────┐
  │ 10.0.0.0/8  → NH#10 │      │ NH#10: via 192.168.1.1 dev eth0 │
  │ 172.16.0.0/12→ NH#10│─────►│                                  │
  │ 203.0.113.0/24→NH#10│      │ (single object, three routes)    │
  └──────────────────────┘      └──────────────────────────────────┘
```

### Nexthop Groups (ECMP)

A **nexthop group** is a set of nexthops used for Equal-Cost Multi-Path (ECMP)
load balancing — sending traffic across multiple uplinks simultaneously.

```
  Destination: 10.0.0.0/8  →  Nexthop Group #20

  Nexthop Group #20:
  ┌─────────────────────────────────────────────────────┐
  │  Member 1: NH#1  via 192.168.1.1 dev eth0  weight 1 │
  │  Member 2: NH#2  via 192.168.2.1 dev eth1  weight 1 │
  │  Member 3: NH#3  via 192.168.3.1 dev eth2  weight 1 │
  └─────────────────────────────────────────────────────┘
        │                │                │
        ▼                ▼                ▼
      eth0             eth1             eth2
   (ISP link 1)    (ISP link 2)    (ISP link 3)
      33% traffic      33% traffic     33% traffic
```

### Nexthop resilience (failover)

When a nexthop group member goes down, the kernel emits a `RTM_NEWNEXTHOP`
update marking the member as **dead**, and traffic is redistributed.

```
  Before failure:                  After eth1 goes down:
  NH Group #20                     NH Group #20
  ┌────────────────────┐           ┌────────────────────────┐
  │ NH#1 eth0  ✓ 33%  │           │ NH#1 eth0  ✓  50%     │
  │ NH#2 eth1  ✓ 33%  │  ──────►  │ NH#2 eth1  ✗  dead    │
  │ NH#3 eth2  ✓ 33%  │           │ NH#3 eth2  ✓  50%     │
  └────────────────────┘           └────────────────────────┘
                           RTM_NEWNEXTHOP fires (group updated)
```

### Who generates nexthop events and when?

| Generator | Trigger | Netlink Message |
|-----------|---------|-----------------|
| FRR / BIRD | New best path computed | `RTM_NEWNEXTHOP` |
| FRR / BIRD | Path withdrawn or failed | `RTM_DELNEXTHOP` |
| `ip nexthop add/del` | Admin action | `RTM_NEWNEXTHOP` / `RTM_DELNEXTHOP` |
| Kernel (BFD/carrier) | Link goes down → member dead | `RTM_NEWNEXTHOP` (group update) |
| Kernel | Route referencing NH deleted | `RTM_DELNEXTHOP` (if refcount→0) |

### Viewing nexthop events live

```bash
# Monitor nexthop changes
ip monitor nexthop

# Show current nexthop objects
ip nexthop show

# Example output:
# id 10 via 192.168.1.1 dev eth0 scope link
# id 20 group 1/2/3 dev eth0
```

---

## 4. /32 Route Events

### What is a /32?

An IP prefix like `192.0.2.5/32` is called a **host route** — it matches
exactly one IP address (the `/32` mask means all 32 bits of the address must match).
Unlike a network route (`10.0.0.0/8`, `/16`, `/24`, etc.), a /32 points to a single host.

```
  Prefix comparison:

  10.0.0.0/8    matches:  10.x.x.x        (16,777,216 addresses)
  10.0.0.0/24   matches:  10.0.0.x        (256 addresses)
  10.0.0.5/32   matches:  10.0.0.5 ONLY   (1 address)  ◄── host route
```

### Why do /32 routes exist?

```
  Use case 1: Loopback / Router-ID address
  ─────────────────────────────────────────
  Router advertises its own loopback (1.1.1.1/32) so other
  routers can always reach it, regardless of which physical
  link is used.

       Router A                      Router B
    loopback: 1.1.1.1/32          loopback: 2.2.2.2/32
       ┌─────┐                         ┌─────┐
       │     │──── eth0 (10.0.1.0/30)──│     │
       │     │──── eth1 (10.0.2.0/30)──│     │
       └─────┘                         └─────┘

  Route on B: 1.1.1.1/32 via 10.0.1.1 (or 10.0.2.1)
  If eth0 fails, OSPF re-routes via eth1 — loopback stays reachable.

  ─────────────────────────────────────────
  Use case 2: VPN tunnel endpoints
  Each VPN peer is a /32 pointing to the tunnel interface.

  Use case 3: Traffic engineering
  Policy routes for exactly one host.

  Use case 4: OSPF redistributed host routes (see Section 5)
```

### /32 route event lifecycle

```
  Admin or daemon adds route          Kernel FIB updated
  ──────────────────────────────────────────────────────

  $ ip route add 1.1.1.1/32 via 192.168.1.1 dev eth0
                 │
                 ▼
       RTM_NEWROUTE fires
       ┌─────────────────────────────────────────┐
       │  type:      RTM_NEWROUTE                 │
       │  family:    AF_INET                      │
       │  dst_len:   32          ◄── /32 here     │
       │  dst:       1.1.1.1                      │
       │  gateway:   192.168.1.1                  │
       │  oif:       eth0                         │
       │  protocol:  RTPROT_STATIC (or OSPF=188)  │
       └─────────────────────────────────────────┘
                 │
                 ▼
       All subscribed userspace processes notified
```

### Route protocols (who installed the route?)

The `protocol` field in the route tells you the origin:

| Protocol Value | Name             | Who set it                        |
|----------------|------------------|-----------------------------------|
| 2              | `kernel`         | Auto-created for connected ifaces |
| 3              | `boot`           | Set during system boot            |
| 4              | `static`         | `ip route add` (admin)            |
| 186            | `babel`          | Babel routing daemon              |
| 187            | `bgp`            | BGP daemon (e.g. FRR)             |
| 188            | `isis`           | IS-IS daemon                      |
| 189            | `ospf`           | OSPF daemon (e.g. FRR)            |
| 190            | `rip`            | RIP daemon                        |

---

## 5. OSPF /32 Events

### What is OSPF?

**OSPF (Open Shortest Path First)** is a link-state routing protocol.
Every OSPF router floods its local topology (LSAs — Link State Advertisements)
to all other routers in the same area. Each router then independently
computes the shortest path tree using Dijkstra's algorithm.

```
      Area 0 (Backbone)
  ┌────────────────────────────────────────────┐
  │                                            │
  │   R1 ─────── R2 ─────── R3                │
  │   │                      │                 │
  │   └────────── R4 ─────── ┘                │
  │                                            │
  └────────────────────────────────────────────┘

  Each Rx floods an LSA saying:
    "I am Rx, I have these links, these neighbors, these prefixes"

  Every router builds a complete map and computes:
    "Shortest path from me to every destination"

  Result → installed as routes in the kernel FIB via Netlink RTM_NEWROUTE
```

### How OSPF generates /32 routes

OSPF produces /32 host routes in several specific situations:

#### 5.1 Loopback / Router-ID advertisement

```
  FRR ospfd process                 Linux kernel
  ─────────────────                 ─────────────
  Reads loopback IP: 1.1.1.1/32
  Generates Type-1 Router LSA
  Floods to all OSPF neighbors
  ──────────────────────────────────────────────

  On remote routers, FRR computes the path to 1.1.1.1/32
  and calls: ip route add 1.1.1.1/32 via <nexthop> proto ospf
                                          │
                                          ▼
                                   RTM_NEWROUTE
                                   dst_len=32, proto=ospf
```

#### 5.2 OSPF stub network (point-to-point links)

When two routers connect via a point-to-point link, OSPF advertises
the **peer's IP address** as a /32 host route:

```
  R1 (10.0.1.1) ═══ point-to-point ═══ R2 (10.0.1.2)

  R1 OSPF LSA advertises:  "10.0.1.2/32 is my neighbor"
  R2 OSPF LSA advertises:  "10.0.1.1/32 is my neighbor"

  Result on R3 (learning via OSPF):
    10.0.1.1/32 via <path to R1>   ← RTM_NEWROUTE
    10.0.1.2/32 via <path to R2>   ← RTM_NEWROUTE
```

#### 5.3 OSPF Type-5 / Type-7 External LSAs (redistribution)

When a router redistributes external routes into OSPF (e.g., from BGP or static),
it generates **Type-5 LSAs** (or Type-7 in NSSA areas). These can be /32s:

```
  BGP                   OSPF Area 0
  ┌────────────────────────────────────────────────────┐
  │                                                    │
  │  BGP learns: 8.8.8.8/32 (Google DNS)              │
  │                    │                               │
  │              FRR redistribution                    │
  │                    │                               │
  │              OSPF Type-5 LSA:                      │
  │              "External: 8.8.8.8/32, metric 20"    │
  │                    │                               │
  │                    ▼  (flooded to all routers)     │
  │                                                    │
  │  All OSPF routers install:                         │
  │    8.8.8.8/32 via <ASBR> proto ospf    ◄─ RTM_NEWROUTE
  └────────────────────────────────────────────────────┘

  ASBR = Autonomous System Boundary Router (does the redistribution)
```

#### 5.4 OSPF Graceful Restart / SPF recompute

When an OSPF neighbor goes down or comes up, or when a link metric changes,
OSPF re-runs SPF. This can trigger a burst of /32 route changes:

```
  Timeline:
  ──────────────────────────────────────────────────────────────────
  t=0   R2-R3 link fails
  t=1   OSPF Dead interval expires (~40s), R1 detects R2 down
  t=2   R1 floods new Router-LSA (R2 removed from topology)
  t=3   SPF recomputed on all routers
  t=4   Old routes via R2 withdrawn:
          RTM_DELROUTE: 2.2.2.2/32 (R2's loopback)
          RTM_DELROUTE: 10.0.1.0/30 (R2-R3 link prefix)
  t=5   New routes (if alternate path exists) installed:
          RTM_NEWROUTE: 2.2.2.2/32 via alternate path
  ──────────────────────────────────────────────────────────────────
```

### OSPF /32 event types summary

```
  OSPF Event              →  Netlink Message
  ──────────────────────────────────────────────────────────────────
  Neighbor comes up       →  RTM_NEWROUTE (loopback /32 reachable)
  Neighbor goes down      →  RTM_DELROUTE (loopback /32 removed)
  Metric change (SPF)     →  RTM_NEWROUTE (route updated, new NH)
  External route learned  →  RTM_NEWROUTE (Type-5 LSA processed)
  External route withdrawn→  RTM_DELROUTE
  Graceful restart start  →  (routes may be temporarily frozen)
  Graceful restart done   →  RTM_NEWROUTE / RTM_DELROUTE (reconcile)
  OSPF daemon restart     →  RTM_DELROUTE (all OSPF routes purged)
                             RTM_NEWROUTE (routes re-learned)
```

---

## 6. How Everything Fits Together

Here is the full picture showing how a single OSPF topology change
cascades through all four event types:

```
  Scenario: R2's uplink to R1 goes down

  ┌──────────────────────────────────────────────────────────────┐
  │  Physical layer                                              │
  │  R1 ─────X───── R2          eth0 on R2 loses carrier        │
  └──────────────────────────────────────────────────────────────┘
                   │
                   ▼  Kernel detects link down
  ┌──────────────────────────────────────────────────────────────┐
  │  Netlink: RTM_NEWLINK  (IFF_UP cleared on eth0)             │
  └──────────────────────────────────────────────────────────────┘
                   │
                   ▼  Kernel removes connected routes via eth0
  ┌──────────────────────────────────────────────────────────────┐
  │  Netlink: RTM_DELROUTE  10.0.1.0/30  proto kernel           │
  └──────────────────────────────────────────────────────────────┘
                   │
                   ▼  Kernel marks neighbors via eth0 as FAILED
  ┌──────────────────────────────────────────────────────────────┐
  │  Netlink: RTM_NEWNEIGH  10.0.1.1  state=FAILED  (neighbor)  │
  └──────────────────────────────────────────────────────────────┘
                   │
                   ▼  FRR ospfd detects neighbor timeout / link down
  ┌──────────────────────────────────────────────────────────────┐
  │  OSPF SPF recompute                                          │
  │  Old nexthop via 10.0.1.1/eth0 → invalid                    │
  │                                                              │
  │  FRR updates kernel:                                         │
  │    RTM_DELNEXTHOP  NH#5 (was: via 10.0.1.1 dev eth0)        │
  │    RTM_NEWNEXTHOP  NH#6 (new: via 10.0.2.1 dev eth1)        │
  └──────────────────────────────────────────────────────────────┘
                   │
                   ▼  FRR updates kernel routes
  ┌──────────────────────────────────────────────────────────────┐
  │  RTM_DELROUTE: 1.1.1.1/32  proto ospf  (old path gone)      │
  │  RTM_NEWROUTE: 1.1.1.1/32  proto ospf  via 10.0.2.1/eth1    │
  └──────────────────────────────────────────────────────────────┘
                   │
                   ▼  All subscribed monitoring processes notified
  ┌──────────────────────────────────────────────────────────────┐
  │  Your netlink monitor / NMS / alerting system receives all   │
  │  the above events and can react accordingly.                 │
  └──────────────────────────────────────────────────────────────┘
```

---

## 7. Quick Reference Table

| Event Type | Kernel Message | Who generates | When |
|------------|---------------|---------------|------|
| New ARP entry | `RTM_NEWNEIGH` | Kernel ARP/NDP | First packet to unknown IP |
| ARP entry confirmed | `RTM_NEWNEIGH` (REACHABLE) | Kernel | ARP reply received |
| ARP entry expired | `RTM_NEWNEIGH` (STALE→FAILED) | Kernel timer | Inactivity timeout |
| ARP entry deleted | `RTM_DELNEIGH` | Kernel timer / admin | Probe failed / ip neigh del |
| Static neighbor | `RTM_NEWNEIGH` (PERMANENT) | Admin / daemon | ip neigh add nud permanent |
| Nexthop created | `RTM_NEWNEXTHOP` | FRR/BIRD/admin | New path computed |
| Nexthop removed | `RTM_DELNEXTHOP` | FRR/BIRD/admin | Path lost or withdrawn |
| Nexthop failed | `RTM_NEWNEXTHOP` (dead flag) | Kernel BFD/link | Member link down |
| /32 route added | `RTM_NEWROUTE` dst_len=32 | FRR/BIRD/admin | Path to host available |
| /32 route removed | `RTM_DELROUTE` dst_len=32 | FRR/BIRD/admin | Host unreachable |
| OSPF neighbor up | `RTM_NEWROUTE` (ospf) | FRR ospfd | Adjacency established |
| OSPF neighbor down | `RTM_DELROUTE` (ospf) | FRR ospfd | Dead interval expired |
| OSPF external /32 | `RTM_NEWROUTE` (ospf, type E1/E2) | FRR ospfd (ASBR) | Type-5 LSA received |
| OSPF metric change | `RTM_NEWROUTE` (ospf, new NH) | FRR ospfd | SPF recomputed |

---

## Useful Commands

```bash
# Watch ALL netlink routing events live
ip monitor all

# Watch only specific event types
ip monitor neigh          # neighbor events only
ip monitor route          # route events only  
ip monitor nexthop        # nexthop events only

# Show current state
ip neigh show             # neighbor (ARP) table
ip route show             # routing table
ip nexthop show           # nexthop objects
ip route show proto ospf  # only OSPF-installed routes

# Show only host routes (/32)
ip route show | grep '/32'

# Dump raw netlink messages (advanced)
ss -f netlink -nlp

# FRR: show OSPF routes specifically
vtysh -c "show ip ospf route"
vtysh -c "show ip ospf neighbor"
```

---

*Document covers Linux kernel 5.x+ and FRR (Free Range Routing) as the reference routing daemon.*
