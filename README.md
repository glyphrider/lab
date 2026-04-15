# lab

Ansible automation for a home lab network.

## Hosts

| Host | IP | OS | Role |
|------|----|----|------|
| lab | 192.168.1.3 | Fedora 43 | Primary server — containers, VMs, NFS client |
| gateway | 192.168.1.1 | OpenBSD | Router — DHCP, DNS, firewall |
| unifi | 192.168.1.2 | Ubuntu 24.04 VM | UniFi OS Server |

## Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| management | 192.168.1.0/24 | Primary LAN |
| marisol | 10.47.2.0/24 | Guest/media VLAN |
| iot | 10.47.3.0/24 | IoT VLAN |

### Network Overview

```mermaid
graph TB
    inet([Internet])
    igc0[igc0 — WAN\nautoconf]

    inet --> igc0 --> gateway

    subgraph gateway [Gateway 192.168.1.1]
        aggr0[aggr0\nbge0+bge1+bge2+bge3]
        vlan2[vlan2 — 10.47.2.1]
        vlan3[vlan3 — 10.47.3.1]
        vlan4[vlan4 — 10.47.4.1]
        aggr0 --> vlan2
        aggr0 --> vlan3
        aggr0 --> vlan4
    end

    subgraph management [Management — 192.168.1.0/24]
        lab[lab\n192.168.1.3]
        nas[nas\n192.168.1.4]
        unifi[unifi VM\n192.168.1.2]
        pihole_mgmt[pihole-management\n192.168.1.5]
    end

    subgraph marisol [Marisol — 10.47.2.0/24]
        pihole_marisol[pihole-marisol\n10.47.2.5]
        jellyfin[jellyfin\n10.47.2.6]
    end

    subgraph iot [IoT — 10.47.3.0/24]
        pihole_iot[pihole-iot\n10.47.3.5]
    end

    aggr0 <--> management
    vlan2 <--> marisol
    vlan3 <--> iot
```

### Lab Server — Network Configuration

```mermaid
graph TB
    nic[Physical NIC]

    nic --> management0

    subgraph bridges [Linux Bridges]
        management0[management0\n192.168.1.3/24]
        marisol0[marisol0\n10.47.2.3/24]
        iot0[iot0\n10.47.3.3/24]
    end

    management0 -->|vlan2| marisol0
    management0 -->|vlan3| iot0

    management0 --> mv_mgmt
    marisol0    --> mv_marisol
    iot0        --> mv_iot

    subgraph macvlans [Podman Macvlan Networks]
        mv_mgmt[lab-management0-macvlan\n192.168.1.0/24]
        mv_marisol[lab-marisol0-macvlan\n10.47.2.0/24]
        mv_iot[lab-iot0-macvlan\n10.47.3.0/24]
    end

    mv_mgmt    --> pihole_mgmt[pihole-management\n192.168.1.5]
    mv_marisol --> pihole_marisol[pihole-marisol\n10.47.2.5]
    mv_marisol --> jellyfin[jellyfin\n10.47.2.6]
    mv_iot     --> pihole_iot[pihole-iot\n10.47.3.5]

    subgraph unifi_vm [KVM VM — unifi]
        unifi[UniFi OS Server\n192.168.1.2]
    end

    management0 --> unifi_vm
```

### Gateway — Network & Services

```mermaid
graph TB
    igc0[igc0 — WAN\nautoconf / autoconf6]

    subgraph trunk [LACP Trunk — aggr0]
        bge0 & bge1 & bge2 & bge3
    end

    aggr0[aggr0\ntrunk member]
    bge0 & bge1 & bge2 & bge3 --> aggr0

    aggr0 -->|untagged| mgmt[aggr0\n192.168.1.1/24\nManagement]
    aggr0 -->|vnetid 2| vlan2[vlan2\n10.47.2.1/24\nMarisol]
    aggr0 -->|vnetid 3| vlan3[vlan3\n10.47.3.1/24\nIoT]
    aggr0 -->|vnetid 4| vlan4[vlan4\n10.47.4.1/24\nVLAN4]

    mgmt   --> dhcpd[dhcpd]
    vlan2  --> dhcpd
    vlan3  --> dhcpd
    vlan4  --> dhcpd

    subgraph unbound [unbound — split-horizon DNS]
        view_mgmt[management view\n192.168.1.0/24 + 127.0.0.0/8\nfull internal records]
        view_marisol[marisol view\n10.47.2.0/24\ngateway + pihole + jellyfin]
        view_iot[iot view\n10.47.3.0/24\ngateway + pihole]
    end

    mgmt  --> view_mgmt
    vlan2 --> view_marisol
    vlan3 --> view_iot

    igc0 --> inet([Internet])
    view_mgmt & view_marisol & view_iot -->|recursive resolution| inet
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

# Run a single role
ansible-playbook lab.yml --tags <role> --ask-vault-pass

# Dry run
ansible-playbook lab.yml --check --ask-vault-pass
```

Available tags match role names: `system-setup`, `user-setup`, `bridge-networking`, `podman`, `podman-macvlan`, `pihole`, `nfs-media`, `va-api`, `jellyfin`, `virtualization`, `unifi`, `gateway-network`, `dhcpd`, `unbound`.

## Secrets

Secrets are managed with ansible-vault:

```bash
# Edit vault
ansible-vault edit group_vars/lab/vault.yml

# Encrypt a new file
ansible-vault encrypt roles/<role>/files/<file>.key
```

## Services

| Service | Host | IP |
|---------|------|----|
| PiHole (management) | lab | 192.168.1.5 |
| PiHole (marisol) | lab | 10.47.2.5 |
| PiHole (iot) | lab | 10.47.3.5 |
| Jellyfin | lab | 10.47.2.6 |
| UniFi OS Server | unifi | 192.168.1.2 |
