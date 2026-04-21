# lab

Ansible automation for a home lab network.

## Hosts

| Host | IP | OS | Role |
|------|----|----|------|
| lab | 192.168.1.3 | Fedora 43 | Primary server — containers, VMs, NFS client |
| gateway | 192.168.1.1 | OpenBSD | Router — DHCP, DNS, firewall |
| unifi | 192.168.1.2 | Ubuntu 24.04 VM | UniFi OS Server |
| nas | 192.168.1.4 | TrueNAS Scale | NFS file server _(not automated)_ |
| switch | 192.168.1.253 | Cisco Catalyst WS-C3650-48PS | 48-port PoE switch _(not automated)_ |
| pihole2 | 192.168.1.251 | Raspberry Pi OS (Bookworm) | Secondary DNS — pihole redundancy |

## Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| management | 192.168.1.0/24 | Primary LAN |
| marisol | 10.47.2.0/24 | Guest/media VLAN |
| iot | 10.47.3.0/24 | IoT VLAN |
| marisol-work | 10.47.4.0/24 | Work VLAN — isolated, gateway only |

### Network Overview

```
Internet
    |
Frontier ONT
    |
igc0 (2.5Gb)
    |
+---+------------------------------+
|   Gateway  192.168.1.1           |
|   dhcpd + unbound (split-horizon)|
+---+----------+--------+----------+
    |          |        |          |
    |        vlan2    vlan3      vlan4
    |          |        |          |
    |       Marisol    IoT       Work
    |                          (isolated)
    |
Management 192.168.1.0/24
    lab            192.168.1.3
    unifi VM       192.168.1.2
    nas            192.168.1.4
    pihole         192.168.1.5   (primary DNS)
    pihole2        192.168.1.251 (secondary DNS)
    unbound        192.168.1.254 (backup resolver)
    rhel8          192.168.1.35
    rhel9          192.168.1.36
    ol9            192.168.1.39

Marisol 10.47.2.0/24
    pihole-marisol  10.47.2.5   (primary DNS)
    pihole2         10.47.2.251 (secondary DNS)
    unbound         10.47.2.254 (backup resolver)
    jellyfin        10.47.2.6

IoT 10.47.3.0/24
    pihole-iot      10.47.3.5   (primary DNS)
    pihole2         10.47.3.251 (secondary DNS)
    unbound         10.47.3.254 (backup resolver)

Work 10.47.4.0/24
    (isolated — gateway only, no containers)
```

### Lab Server — Network Configuration

```
Physical NIC
    |
+---+-----------------------------+
|  management0   192.168.1.3/24  |
+---+----+-------------+---------+
    |    |             |
  vlan2 vlan3        KVM + macvlan
    |    |             |
    |    |             +-- unifi VM      192.168.1.2
    |    |             +-- lab-management0-macvlan
    |    |                   pihole-management  192.168.1.5
    |    |                   unbound            192.168.1.254
    |    |
    |  iot0  10.47.3.3/24
    |    |
    |    +-- lab-iot0-macvlan
    |          pihole-iot   10.47.3.5
    |          unbound      10.47.3.254
    |
  marisol0  10.47.2.3/24
    |
    +-- lab-marisol0-macvlan
          pihole-marisol  10.47.2.5
          jellyfin        10.47.2.6
          unbound         10.47.2.254
```

### pihole2 (Raspberry Pi) — Network Configuration

```
Physical NIC (eth0)
    |
    +-- untagged --> eth0     192.168.1.251/24
    |                  port 53 --> pihole-management
    |
    +-- vlan2   --> eth0.2   10.47.2.251/24
    |                  port 53 --> pihole-marisol
    |
    +-- vlan3   --> eth0.3   10.47.3.251/24
                       port 53 --> pihole-iot

Containers (podman bridge, port-published):
    pihole-management   192.168.1.251:53
    pihole-marisol      10.47.2.251:53
    pihole-iot          10.47.3.251:53
```

### Gateway — Network & Services

```
Frontier ONT
    |
igc0  WAN  2.5Gb  (autoconf / autoconf6)
    |
aggr0  LACP  4x1Gb  (bge0 + bge1 + bge2 + bge3)
    |
    +<--> trunk <--> Cisco Catalyst WS-C3650-48PS  192.168.1.253
    |
    +-- untagged --> aggr0   192.168.1.1/24  management
    +-- vnetid 2 --> vlan2   10.47.2.1/24    marisol
    +-- vnetid 3 --> vlan3   10.47.3.1/24    iot
    +-- vnetid 4 --> vlan4   10.47.4.1/24    work

dhcpd  (all VLANs):
    management  dns: 192.168.1.5   + 192.168.1.251
    marisol     dns: 10.47.2.5     + 10.47.2.251
    iot         dns: 10.47.3.5     + 10.47.3.251
    work        dns: 10.47.4.5     + 10.47.4.251

unbound  (split-horizon, recursive):
    management view  192.168.1.0/24 + 127.0.0.0/8   full internal records
    marisol view     10.47.2.0/24                    gateway + pihole + pihole2 + jellyfin
    iot view         10.47.3.0/24                    gateway + pihole + pihole2
    work view        10.47.4.0/24                    gateway only
```

## Prerequisites

- Ansible with `community.general` collection
- A vault password for encrypted secrets
- SSH access to all hosts

## Usage

```bash
# Run full configuration
ansible-playbook lab.yml --ask-vault-pass
ansible-playbook gateway.yml --ask-vault-pass
ansible-playbook pi.yml --ask-vault-pass

# Run a single role
ansible-playbook lab.yml --tags <role> --ask-vault-pass
ansible-playbook pi.yml --tags <role> --ask-vault-pass

# Dry run
ansible-playbook lab.yml --check --ask-vault-pass
```

Available tags match role names: `system-setup`, `user-setup`, `bridge-networking`, `podman`, `podman-macvlan`, `pihole`, `nfs-media`, `va-api`, `jellyfin`, `virtualization`, `unifi`, `gateway-network`, `dhcpd`, `unbound`, `unbound-container`, `rpi-network`, `rhel-vms`, `rhel-setup`, `ol-setup`.

## Secrets

Secrets are managed with ansible-vault:

```bash
# Edit vault
ansible-vault edit group_vars/lab/vault.yml
ansible-vault edit group_vars/pi/vault.yml

# Encrypt a new file
ansible-vault encrypt roles/<role>/files/<file>.key
```

## Services

| Service | Host | IP |
|---------|------|----|
| PiHole (management) | lab | 192.168.1.5 |
| PiHole (marisol) | lab | 10.47.2.5 |
| PiHole (iot) | lab | 10.47.3.5 |
| PiHole 2 (management) | pihole2 | 192.168.1.251 |
| PiHole 2 (marisol) | pihole2 | 10.47.2.251 |
| PiHole 2 (iot) | pihole2 | 10.47.3.251 |
| Unbound (management) | lab | 192.168.1.254 |
| Unbound (marisol) | lab | 10.47.2.254 |
| Unbound (iot) | lab | 10.47.3.254 |
| Jellyfin | lab | 10.47.2.6 |
| Grafana | lab | 192.168.1.7 |
| Prometheus | lab | 192.168.1.8 |
| UniFi OS Server | unifi | 192.168.1.2 |
